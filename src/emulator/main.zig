//! A terminal emulator for tests and the agent harness, built on Ghostty's
//! `ghostty-vt`. It is an independent implementation of what ptz targets,
//! so checking ptz's output against it doesn't just repeat ptz's own reading
//! of the protocols.
//!
//! ptz code writes to `output` as it would to a real terminal and reads the
//! emulator's replies to queries from `input`. Afterwards, the screen can be
//! inspected: its text, and the images placed on it.
//!
//! Only tests and the harness may import this, since it pulls in Ghostty.

// std
const std = @import("std");

// packages
const vt = @import("ghostty-vt");

// project
const terminal = @import("../terminal/main.zig");

// ====================================================================================================
// Types
// ====================================================================================================

pub const Emulator = struct {
    gpa: std.mem.Allocator,
    size: terminal.Size,
    terminal: vt.Terminal,
    stream: vt.TerminalStream,
    /// Replies to queries not yet read from `input`.
    replies: std.ArrayList(u8),
    output: std.Io.Writer,
    input: std.Io.Reader,
    output_buffer: [4096]u8,
    input_buffer: [1024]u8,

    /// The screen's pixels: placed images over a dark background. Text is
    /// not drawn; read it with `text`.
    pub const Screenshot = struct {
        width: u32,
        height: u32,
        /// RGBA, owned by the caller.
        pixels: []u8,

        pub fn pixel(shot: Screenshot, x: u32, y: u32) [4]u8 {
            return shot.pixels[(@as(usize, y) * shot.width + x) * 4 ..][0..4].*;
        }
    };

    /// Heap-allocated because Ghostty's stream keeps a pointer to the
    /// terminal, and the replies callback finds the emulator from the stream.
    pub fn create(io: std.Io, gpa: std.mem.Allocator, size: terminal.Size) !*Emulator {
        const emulator = try gpa.create(Emulator);
        errdefer gpa.destroy(emulator);

        emulator.* = .{
            .gpa = gpa,
            .size = size,
            .terminal = try .init(io, gpa, .{
                .cols = size.cols,
                .rows = size.rows,
                // The library default (10 MB) is smaller than one full-screen page.
                .kitty_image_storage_limit = 1024 * 1024 * 1024,
            }),
            .stream = undefined,
            .replies = .empty,
            .output = .{ .vtable = &.{ .drain = drain }, .buffer = &emulator.output_buffer },
            .input = .{ .vtable = &.{ .stream = streamReplies }, .buffer = &emulator.input_buffer, .seek = 0, .end = 0 },
            .output_buffer = undefined,
            .input_buffer = undefined,
        };
        errdefer emulator.terminal.deinit(gpa);
        // Kitty images need the cell size to work out how many rows they cover.
        try emulator.terminal.resize(gpa, .{
            .cols = size.cols,
            .rows = size.rows,
            .cell_size_px = .{ .width = size.cell_width, .height = size.cell_height },
        });

        var handler: vt.TerminalStream.Handler = .init(&emulator.terminal);
        handler.effects.write_pty = &writePty;
        handler.effects.device_attributes = &deviceAttributes;
        emulator.stream = .init(.{ .allocator = gpa, .handler = handler });
        return emulator;
    }

    pub fn destroy(emulator: *Emulator) void {
        const gpa = emulator.gpa;
        emulator.stream.deinit();
        emulator.terminal.deinit(gpa);
        emulator.replies.deinit(gpa);
        gpa.destroy(emulator);
    }

    /// The screen's text, one line per row. Caller owns the result.
    pub fn text(emulator: *Emulator, gpa: std.mem.Allocator) ![]const u8 {
        return emulator.terminal.plainString(gpa);
    }

    pub fn screenshot(emulator: *Emulator, gpa: std.mem.Allocator) !Screenshot {
        const size = emulator.size;
        const width = @as(u32, size.cols) * size.cell_width;
        const height = @as(u32, size.rows) * size.cell_height;
        const pixels = try gpa.alloc(u8, @as(usize, width) * height * 4);
        for (0..pixels.len / 4) |i| pixels[i * 4 ..][0..4].* = .{ 32, 32, 32, 255 };

        const screen = emulator.terminal.screens.active;
        var placements = screen.kitty_images.placements.iterator();
        while (placements.next()) |entry| {
            const placement = entry.value_ptr;
            const pin = switch (placement.location) {
                .pin => |pin| pin,
                else => continue,
            };
            const point = screen.pages.pointFromPin(.active, pin.*) orelse continue;
            const image = screen.kitty_images.imageById(entry.key_ptr.image_id) orelse continue;
            const data = switch (image.data) {
                .complete => |data| data,
                .pending => continue,
            };
            // ptz only sends RGBA, which the terminal stores as is.
            std.debug.assert(image.format == .rgba);

            // A zero source size means the rest of the image.
            const source_width = if (placement.source_width == 0) image.width - placement.source_x else placement.source_width;
            const source_height = if (placement.source_height == 0) image.height - placement.source_y else placement.source_height;
            const left = point.active.x * size.cell_width + placement.x_offset;
            const top = point.active.y * size.cell_height + placement.y_offset;
            const columns = @min(source_width, width -| left);
            for (0..@min(source_height, height -| top)) |row| {
                const source = data[((placement.source_y + row) * image.width + placement.source_x) * 4 ..][0 .. columns * 4];
                @memcpy(pixels[((top + row) * width + left) * 4 ..][0 .. columns * 4], source);
            }
        }
        return .{ .width = width, .height = height, .pixels = pixels };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const emulator: *Emulator = @alignCast(@fieldParentPtr("output", w));
        emulator.stream.nextSlice(w.buffered());
        w.end = 0;
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            emulator.stream.nextSlice(bytes);
            written += bytes.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| emulator.stream.nextSlice(pattern);
        return written + pattern.len * splat;
    }

    /// Reports end of stream when there are no replies, like a real
    /// terminal's input timing out.
    fn streamReplies(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const emulator: *Emulator = @alignCast(@fieldParentPtr("input", r));
        if (emulator.replies.items.len == 0) return error.EndOfStream;
        const n = try w.write(limit.sliceConst(emulator.replies.items));
        emulator.replies.replaceRangeAssumeCapacity(0, n, &.{});
        return n;
    }

    fn writePty(handler: *vt.TerminalStream.Handler, data: []const u8) void {
        const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
        const emulator: *Emulator = @fieldParentPtr("stream", stream);
        emulator.replies.appendSlice(emulator.gpa, data) catch @panic("OOM");
    }

    fn deviceAttributes(_: *vt.TerminalStream.Handler) vt.device_attributes.Attributes {
        return .{};
    }
};
