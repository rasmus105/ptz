//! The interactive viewer: connects the viewer's logic (`viewer/`) to the
//! terminal, the render thread and the file on disk.
//!
//! `App` handles each kind of input and draws frames to any stream, so tests
//! and the harness drive it against an emulator, with `settle` stepping the
//! renderer on the calling thread. `run` is the event loop around it for a
//! real terminal: it waits on keys, render results, resizes and a timer for
//! watching the file, and owns all blocking.

// std
const std = @import("std");

// project
const graphics = @import("../graphics/main.zig");
const document = @import("../document/main.zig");
const terminal = @import("../terminal/main.zig");
const viewer = @import("../viewer/main.zig");

// local
const Cache = @import("Cache.zig");
const Renderer = @import("Renderer.zig");

// aliases
const posix = std.posix;

// ====================================================================================================
// Constants
// ====================================================================================================

/// Bounds both transmitted bytes and decoded image work per frame, including
/// shared memory. Larger batches wait so keys are handled between uploads.
const upload_bytes_per_frame = 8 * 1024 * 1024;
/// How often to check the file for changes when watching.
const watch_interval_ms = 250;
/// Distinguishes Escape from an escape sequence split across reads.
const escape_timeout_ms = 50;
/// The longest key sequence kept while waiting for the rest of it.
const pending_input_max = 128;
/// The most bytes `App.input` takes at once.
pub const input_len_max = 256;

// ====================================================================================================
// Types
// ====================================================================================================

pub const Options = struct {
    path: []const u8,
    /// Page to show first, counting from 1.
    page: u32,
    dark: bool,
    watch: bool,
    medium: graphics.Medium,
};

pub const App = struct {
    gpa: std.mem.Allocator,
    state: viewer.State,
    renderer: Renderer,
    cache: Cache,
    /// The loaded document's page sizes and offsets, which `state` points to.
    page_sizes: []document.Size,
    page_offsets: []f64,
    frame: viewer.Frame,
    results: std.ArrayList(Renderer.Result),
    /// The start of a key sequence cut off at the end of the last input.
    pending_input: [pending_input_max]u8,
    pending_input_len: u32,
    /// Once a control string exceeds the buffer, discard through its terminator
    /// rather than interpreting the remaining protocol bytes as user commands.
    discarding_string: bool,
    discarded_escape: bool,
    escape_started: ?std.Io.Timestamp,
    /// Whether the screen is out of date.
    dirty: bool,
    /// Whether text drawn at an earlier window size must be erased.
    resized: bool,
    /// Set when the document can't be loaded and there is nothing to show.
    open_error: ?document.Error,

    /// Initialized in place: the renderer must not move once started.
    pub fn init(
        app: *App,
        io: std.Io,
        gpa: std.mem.Allocator,
        options: Options,
        size: terminal.Size,
        wake_fd: ?posix.fd_t,
    ) void {
        app.* = .{
            .gpa = gpa,
            .state = .init(std.fs.path.basename(options.path), size, options.dark, options.page),
            .renderer = undefined,
            .cache = .init(Cache.uploaded_bytes_max, Cache.pending_bytes_max),
            .page_sizes = &.{},
            .page_offsets = &.{},
            .frame = undefined,
            .results = .empty,
            .pending_input = undefined,
            .pending_input_len = 0,
            .discarding_string = false,
            .discarded_escape = false,
            .escape_started = null,
            .dirty = true,
            .resized = false,
            .open_error = null,
        };
        app.renderer.init(io, gpa, options.path, options.medium, wake_fd);
    }

    pub fn deinit(app: *App) void {
        app.renderer.deinit();
        for (app.results.items) |result| result.deinit(app.gpa);
        app.results.deinit(app.gpa);
        app.cache.deinit(app.gpa);
        app.gpa.free(app.page_sizes);
        app.gpa.free(app.page_offsets);
        app.* = undefined;
    }

    /// Handles at most `input_len_max` bytes typed in the terminal, and
    /// returns whether they asked to quit. A key sequence cut off at the end
    /// is kept until the rest arrives.
    pub fn input(app: *App, bytes: []const u8) bool {
        std.debug.assert(bytes.len <= input_len_max);
        if (bytes.len == 0) return false;
        var incoming = bytes;
        if (app.discarding_string) {
            while (incoming.len > 0) {
                const byte = incoming[0];
                incoming = incoming[1..];
                const finished = byte == 0x07 or (app.discarded_escape and byte == '\\');
                app.discarded_escape = byte == 0x1b;
                if (finished) {
                    app.discarding_string = false;
                    app.discarded_escape = false;
                    break;
                }
            }
            if (app.discarding_string or incoming.len == 0) return false;
        }
        var buffer: [pending_input_max + input_len_max]u8 = undefined;
        @memcpy(buffer[0..app.pending_input_len], app.pending_input[0..app.pending_input_len]);
        @memcpy(buffer[app.pending_input_len..][0..incoming.len], incoming);
        var unread = buffer[0 .. app.pending_input_len + incoming.len];
        app.pending_input_len = 0;
        app.escape_started = null;

        while (unread.len > 0) {
            const decoded = terminal.Key.decode(unread) orelse {
                // Longer than any key: drop it rather than wait forever.
                if (unread.len <= pending_input_max) {
                    @memcpy(app.pending_input[0..unread.len], unread);
                    app.pending_input_len = @intCast(unread.len);
                    if (std.mem.eql(u8, unread, "\x1b")) app.escape_started = .now(app.renderer.io, .awake);
                } else if (std.mem.startsWith(u8, unread, "\x1b_") or
                    std.mem.startsWith(u8, unread, "\x1b]") or
                    std.mem.startsWith(u8, unread, "\x1bP"))
                {
                    app.discarding_string = true;
                    app.discarded_escape = unread[unread.len - 1] == 0x1b;
                }
                return false;
            };
            if (graphics.Reply.parse(unread[0..decoded.len])) |reply| {
                switch (app.cache.reject(reply)) {
                    .ignored => {},
                    .retry => app.dirty = true,
                    .failed => {
                        _ = app.state.update(.{ .message = if (reply.status == .not_found and reply.placement == 1)
                            "terminal cannot retain visible images"
                        else
                            "terminal rejected image" });
                        app.dirty = true;
                    },
                }
                unread = unread[decoded.len..];
                continue;
            }
            unread = unread[decoded.len..];
            app.dirty = true;
            switch (app.state.update(.{ .key = decoded.key })) {
                .none => {},
                .quit => return true,
                .reload => app.renderer.reload(),
            }
        }
        return false;
    }

    /// Resolves a standalone Escape once its continuation deadline passes.
    pub fn expireInput(app: *App, now: std.Io.Timestamp) void {
        const started = app.escape_started orelse return;
        if (started.durationTo(now).toMilliseconds() < escape_timeout_ms) return;
        app.escape_started = null;
        app.pending_input_len = 0;
        app.dirty = true;
        _ = app.state.update(.{ .key = .escape });
    }

    pub fn resize(app: *App, size: terminal.Size) void {
        app.dirty = true;
        app.resized = true;
        _ = app.state.update(.{ .resize = size });
    }

    /// Takes in what the renderer finished since the last call.
    pub fn collect(app: *App) std.mem.Allocator.Error!void {
        try app.renderer.collect(&app.results);
        defer app.results.clearRetainingCapacity();
        for (app.results.items) |result| {
            app.take(result) catch {
                app.dirty = true;
                // Later results may describe a reload the viewer must observe.
                _ = app.state.update(.{ .message = "out of memory" });
            };
        }
    }

    /// Draws the current frame, asking the renderer for missing tiles and
    /// uploading finished ones. Stays dirty while uploads are pending.
    pub fn draw(app: *App, output: *std.Io.Writer) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
        const frame = &app.frame;
        app.state.layout(frame);

        var visible_tiles: [viewer.tiles_max]viewer.Tile = undefined;
        const visible = visible_tiles[0..frame.slices().len];
        for (visible, frame.slices()) |*tile, slice| tile.* = slice.tile;
        app.cache.beginFrame(visible);

        var missing: [viewer.tiles_max]viewer.Tile = undefined;
        app.renderer.want(app.cache.findMissing(frame.wanted(), &missing));
        app.dirty = try app.cache.upload(app.gpa, output, visible, upload_bytes_per_frame);

        try output.writeAll(terminal.sync_begin);
        if (app.resized) try output.writeAll(terminal.clear_text);
        app.resized = false;
        try graphics.clearPlacements(output);
        const size = app.state.size;
        for (frame.slices()) |slice| {
            const image = app.cache.shown(slice.tile) orelse continue;
            try graphics.place(output, .{
                .image = image,
                .source = .{ .x = slice.source_x, .y = slice.source_y, .width = slice.width, .height = slice.height },
                .col = @intCast(slice.x / size.cell_width),
                .row = @intCast(slice.y / size.cell_height),
                .x_offset = @intCast(slice.x % size.cell_width),
                .y_offset = @intCast(slice.y % size.cell_height),
            });
        }
        try drawStatus(output, frame.status(), size);
        try output.writeAll(terminal.sync_end);
        try app.cache.evict(app.gpa, output);
        try output.flush();
    }

    /// Renders on the calling thread, drawing to `output`, until there is
    /// nothing left to do. For tests and the harness; `run` renders on a
    /// thread instead.
    pub fn settle(app: *App, output: *std.Io.Writer) !void {
        std.debug.assert(app.renderer.thread == null);
        while (true) {
            try app.collect();
            if (app.open_error != null) return;
            if (app.dirty) try app.draw(output);
            if (!app.renderer.step() and !app.dirty) return;
        }
    }

    fn take(app: *App, result: Renderer.Result) std.mem.Allocator.Error!void {
        switch (result) {
            .opened => |opened| {
                _ = app.state.update(.{ .document = .{
                    .generation = opened.generation,
                    .page_sizes = opened.page_sizes,
                    .page_offsets = opened.page_offsets,
                } });
                app.gpa.free(app.page_sizes);
                app.gpa.free(app.page_offsets);
                app.page_sizes = opened.page_sizes;
                app.page_offsets = opened.page_offsets;
            },
            .open_failed => |err| {
                if (app.state.document.generation == 0) app.open_error = err;
                var buffer: [64]u8 = undefined;
                const text = std.fmt.bufPrint(&buffer, "reload failed: {t}", .{err}) catch unreachable;
                _ = app.state.update(.{ .message = text });
            },
            .tile => |tile| {
                try app.cache.put(app.gpa, tile.tile, tile.encoded);
                if (!app.cache.needsFrame(tile.tile)) return;
            },
            .render_failed => |tile| {
                try app.cache.putFailed(app.gpa, tile);
                var buffer: [64]u8 = undefined;
                const text = std.fmt.bufPrint(&buffer, "cannot render page {d}", .{tile.page + 1}) catch unreachable;
                _ = app.state.update(.{ .message = text });
            },
        }
        app.dirty = true;
    }
};

/// Notices when the file has changed and stopped changing: a reload waits
/// until two checks in a row agree, so it doesn't read a half-written file.
const Watch = struct {
    path: []const u8,
    loaded: ?Stamp,
    pending: ?Stamp,
    checked: std.Io.Timestamp,

    const Stamp = struct { size: u64, mtime: i96, inode: u64 };

    fn init(io: std.Io, path: []const u8) Watch {
        return .{ .path = path, .loaded = stamp(io, path), .pending = null, .checked = .now(io, .awake) };
    }

    /// Checks the file at most every `watch_interval_ms`.
    fn changed(watch: *Watch, io: std.Io) bool {
        const now: std.Io.Timestamp = .now(io, .awake);
        if (watch.checked.durationTo(now).toMilliseconds() < watch_interval_ms) return false;
        watch.checked = now;
        return watch.observe(stamp(io, watch.path) orelse return false);
    }

    /// Whether to reload, given the file's state at this check.
    fn observe(watch: *Watch, current: Stamp) bool {
        if (watch.loaded != null and std.meta.eql(current, watch.loaded.?)) {
            watch.pending = null;
            return false;
        }
        if (watch.pending != null and std.meta.eql(current, watch.pending.?)) {
            watch.loaded = current;
            watch.pending = null;
            return true;
        }
        watch.pending = current;
        return false;
    }

    fn stamp(io: std.Io, path: []const u8) ?Stamp {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
        return .{ .size = stat.size, .mtime = stat.mtime.toNanoseconds(), .inode = @intCast(stat.inode) };
    }
};

// ====================================================================================================
// Public API
// ====================================================================================================

/// Runs the viewer full screen until quit. Expects raw mode, and that the
/// terminal supports images.
pub fn run(io: std.Io, gpa: std.mem.Allocator, options: Options, size: terminal.Size, output: *std.Io.Writer) !void {
    var wake_fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&wake_fds) != 0) return error.Unexpected;
    defer for (wake_fds) |fd| {
        _ = std.c.close(fd);
    };
    // Wake bytes may coalesce; neither the worker nor a signal may block here.
    const flags: c_int = @bitCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
    if (std.c.fcntl(wake_fds[1], posix.F.SETFL, flags) != 0) return error.Unexpected;
    terminal.notifySignals(wake_fds[1]);
    defer terminal.notifySignals(null);

    const app = try gpa.create(App);
    defer gpa.destroy(app);
    app.init(io, gpa, options, size, wake_fds[1]);
    defer app.deinit();
    var watch: Watch = .init(io, options.path);
    try app.renderer.start();

    try output.writeAll(terminal.fullscreen_enter);
    defer {
        app.cache.clear(gpa, output);
        output.writeAll(terminal.fullscreen_leave) catch {};
        output.flush() catch {};
    }

    var read_buffer: [input_len_max]u8 = undefined;
    while (true) {
        if (app.dirty) try app.draw(output);
        if (app.open_error) |err| return err;

        var fds = [_]posix.pollfd{
            .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = wake_fds[0], .events = posix.POLL.IN, .revents = 0 },
        };
        var timeout_ms: i32 = if (app.dirty) 0 else if (options.watch) watch_interval_ms else -1;
        if (app.escape_started) |started| {
            const elapsed = started.durationTo(.now(io, .awake)).toMilliseconds();
            const remaining: i32 = @intCast(@max(0, escape_timeout_ms - elapsed));
            timeout_ms = if (timeout_ms < 0) remaining else @min(timeout_ms, remaining);
        }
        _ = try posix.poll(&fds, timeout_ms);

        if (fds[0].revents != 0) {
            const len = try posix.read(posix.STDIN_FILENO, &read_buffer);
            // The terminal went away.
            if (len == 0) return;
            if (app.input(read_buffer[0..len])) return;
        }
        if (fds[1].revents != 0) {
            _ = try posix.read(wake_fds[0], &read_buffer);
        }
        const signals = terminal.takeSignals();
        if (signals.quit) return;
        if (signals.resized) {
            var stdin: terminal.Input = .init(&read_buffer, 100);
            const resized = terminal.size(&stdin.interface, output) catch app.state.size;
            app.resize(resized);
        }
        app.expireInput(.now(io, .awake));
        try app.collect();
        if (options.watch and watch.changed(io)) app.renderer.reload();
    }
}

// ====================================================================================================
// Private Functions
// ====================================================================================================

/// The status line in reverse video across the last row.
fn drawStatus(output: *std.Io.Writer, status: viewer.Status, size: terminal.Size) std.Io.Writer.Error!void {
    const gap = "  ";
    const right = truncate(status.right, size.cols, false);
    const right_cols = terminal.textWidth(right);
    const left_room = (size.cols - right_cols) -| if (right_cols > 0) gap.len else 0;
    const left = truncate(status.left, left_room, status.keep_end);
    const padding = size.cols - right_cols - terminal.textWidth(left);

    try terminal.moveCursor(output, size.rows - 1, 0);
    try output.writeAll(terminal.style_reverse);
    try terminal.writeText(output, left);
    try output.splatByteAll(' ', padding);
    try terminal.writeText(output, right);
    try output.writeAll(terminal.style_reset);
}

/// The longest prefix (or suffix, with `keep_end`) of `text` at most `cols`
/// cells wide.
fn truncate(text: []const u8, cols: usize, keep_end: bool) []const u8 {
    if (terminal.textWidth(text) <= cols) return text;
    if (keep_end) {
        var start: usize = 0;
        while (terminal.textWidth(text[start..]) > cols) start += terminal.charLen(text[start..]);
        return text[start..];
    }
    var end: usize = 0;
    while (end < text.len) {
        const next = end + terminal.charLen(text[end..]);
        if (terminal.textWidth(text[0..next]) > cols) break;
        end = next;
    }
    return text[0..end];
}

// ====================================================================================================
// Tests
// ====================================================================================================

const Emulator = @import("../emulator/main.zig").Emulator;

test {
    _ = Cache;
    _ = Renderer;
    _ = @import("recovery_test.zig");
}

test "a change reloads once it has held for a check, and only once" {
    const a: Watch.Stamp = .{ .size = 1, .mtime = 1, .inode = 1 };
    const b: Watch.Stamp = .{ .size = 2, .mtime = 2, .inode = 1 };
    const c: Watch.Stamp = .{ .size = 3, .mtime = 3, .inode = 2 };
    var watch: Watch = .{ .path = "", .loaded = a, .pending = null, .checked = undefined };
    // Still being written: b, then c.
    try std.testing.expect(!watch.observe(b));
    try std.testing.expect(!watch.observe(c));
    // c held for a whole interval.
    try std.testing.expect(watch.observe(c));
    try std.testing.expect(!watch.observe(c));
    // A change that reverts before the next check doesn't reload.
    try std.testing.expect(!watch.observe(a));
    try std.testing.expect(!watch.observe(c));
}

test "the status line keeps the position visible and fits the width" {
    const gpa = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    const size: terminal.Size = .{ .cols = 16, .rows = 2, .cell_width = 1, .cell_height = 1 };
    try drawStatus(&output.writer, .{ .left = "a-long-file-name.pdf", .right = "3/9", .keep_end = false }, size);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "a-long-file  3/9") != null);

    output.clearRetainingCapacity();
    try drawStatus(&output.writer, .{ .left = ":typed\xc3\xa9 a long command", .right = "", .keep_end = true }, size);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\xc3\xa9 a long command") != null);

    // Wide characters take two cells, and invalid bytes one: nothing may
    // spill past the last column.
    output.clearRetainingCapacity();
    try drawStatus(&output.writer, .{ .left = "\xe6\x97\xa5\xe6\x9c\xac\xff-name-that-is-long", .right = "1/2", .keep_end = false }, size);
    const line = output.written()[std.mem.indexOf(u8, output.written(), terminal.style_reverse).? + terminal.style_reverse.len ..];
    const text = line[0..std.mem.indexOf(u8, line, terminal.style_reset).?];
    try std.testing.expectEqual(16, terminal.textWidth(text));
}

test "shows the document, and keys move through it" {
    const gpa = std.testing.allocator;
    const size: terminal.Size = .{ .cols = 40, .rows = 11, .cell_width = 10, .cell_height = 20 };
    const emulator: *Emulator = try .create(std.testing.io, gpa, size);
    defer emulator.destroy();
    const app = try gpa.create(App);
    defer gpa.destroy(app);
    app.init(std.testing.io, gpa, .{
        .path = "src/document/testdata/red-square.pdf",
        .page = 1,
        .dark = false,
        .watch = false,
        .medium = .shared_memory,
    }, size, null);
    defer app.deinit();
    try app.settle(&emulator.output);

    // 400 px wide view: the 200x100 pt page at 2x, so the red square spans
    // x 40..120 and y 80..160.
    const screen = try emulator.screenshot(gpa);
    defer gpa.free(screen.pixels);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, screen.pixel(80, 120));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, screen.pixel(300, 40));
    const text = try emulator.text(gpa);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "red-square.pdf") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "1/1  100%") != null);

    // Dark mode inverts the page; the `i` arrives split from nothing, and
    // an arrow key split across two inputs is still one key.
    try std.testing.expect(!app.input("\x1b["));
    try std.testing.expect(!app.input("Bi"));
    try app.settle(&emulator.output);
    const dark = try emulator.screenshot(gpa);
    defer gpa.free(dark.pixels);
    try std.testing.expectEqual([4]u8{ 0, 255, 255, 255 }, dark.pixel(80, 120));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, dark.pixel(300, 40));
    try std.testing.expect(app.input("q"));
}

test "prefetched tiles wait for a visible placement without redrawing" {
    const gpa = std.testing.allocator;
    const size: terminal.Size = .{ .cols = 60, .rows = 4, .cell_width = 10, .cell_height = 20 };
    const emulator: *Emulator = try .create(std.testing.io, gpa, size);
    defer emulator.destroy();
    const app = try gpa.create(App);
    defer gpa.destroy(app);
    app.init(std.testing.io, gpa, .{
        .path = "src/document/testdata/odd-sizes.pdf",
        .page = 1,
        .dark = false,
        .watch = false,
        .medium = .direct,
    }, size, null);
    defer app.deinit();
    try app.settle(&emulator.output);

    // The first scroll requests page two, but its top still lies below the view.
    try std.testing.expect(!app.input("j"));
    try app.draw(&emulator.output);
    try std.testing.expect(app.renderer.step());
    try app.collect();
    try std.testing.expect(!app.dirty);

    // Advance onto page two and draw without letting the renderer run again.
    try std.testing.expect(!app.input("j"));
    try app.draw(&emulator.output);
    const screen = try emulator.screenshot(gpa);
    defer gpa.free(screen.pixels);
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, screen.pixel(300, 48));
}

test "a tile cache allocation failure preserves a reload in the same batch" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    const app = try gpa.create(App);
    defer gpa.destroy(app);
    app.init(std.testing.io, gpa, .{
        .path = "src/document/testdata/red-square.pdf",
        .page = 1,
        .dark = false,
        .watch = false,
        .medium = .direct,
    }, .{ .cols = 40, .rows = 11, .cell_width = 10, .cell_height = 20 }, null);
    defer app.deinit();
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();

    try std.testing.expect(app.renderer.step());
    try app.collect();
    try app.draw(&output.writer);
    try std.testing.expect(app.renderer.step());
    app.renderer.reload();
    try std.testing.expect(app.renderer.step());

    // Collection can move both results, but caching the first tile will fail.
    try app.results.ensureTotalCapacity(gpa, 2);
    failing.fail_index = failing.alloc_index;
    try app.collect();
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(2, app.state.document.generation);
}

test "an empty file stays open and reloads when PDF content arrives" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "empty.pdf", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(io, "empty.pdf", gpa);
    defer gpa.free(path);

    const size: terminal.Size = .{ .cols = 40, .rows = 11, .cell_width = 10, .cell_height = 20 };
    const emulator: *Emulator = try .create(io, gpa, size);
    defer emulator.destroy();
    const app = try gpa.create(App);
    defer gpa.destroy(app);
    app.init(io, gpa, .{
        .path = path,
        .page = 1,
        .dark = false,
        .watch = true,
        .medium = .shared_memory,
    }, size, null);
    defer app.deinit();
    var watch: Watch = .init(io, path);
    try app.settle(&emulator.output);
    try std.testing.expectEqual(null, app.open_error);
    try std.testing.expectEqualStrings("no pages", app.frame.status().right);
    try std.testing.expectEqual(0, app.frame.slices().len);
    try std.testing.expect(!app.input("jG+-"));
    try app.settle(&emulator.output);

    try tmp.dir.writeFile(io, .{ .sub_path = "empty.pdf", .data = @embedFile("../document/testdata/red-square.pdf") });
    const current = Watch.stamp(io, path).?;
    try std.testing.expect(!watch.observe(current));
    try std.testing.expect(watch.observe(current));
    app.renderer.reload();
    try app.settle(&emulator.output);
    try std.testing.expectEqual(null, app.open_error);
    try std.testing.expectEqual(1, app.page_sizes.len);
    const screen = try emulator.screenshot(gpa);
    defer gpa.free(screen.pixels);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, screen.pixel(80, 120));
}

test "navigation sequences survive every input split without closing commands" {
    const gpa = std.testing.allocator;
    const size: terminal.Size = .{ .cols = 40, .rows = 3, .cell_width = 10, .cell_height = 20 };
    const reference = try gpa.create(App);
    defer gpa.destroy(reference);
    const fragmented = try gpa.create(App);
    defer gpa.destroy(fragmented);
    const pages = [_]document.Size{.{ .width = 200, .height = 1000 }};
    const offsets = [_]f64{0};
    for ([_][]const u8{ "\x1b[A", "\x1b[B", "\x1bOC", "\x1b[1;5D", "\x1b[5~", "\x1b[6~", "\x1b[H", "\x1b[F" }) |sequence| {
        for ([_]bool{ false, true }) |command| {
            for (1..sequence.len) |split| {
                for ([_]*App{ reference, fragmented }) |app| {
                    app.init(std.testing.io, gpa, .{ .path = "unused.pdf", .page = 1, .dark = false, .watch = false, .medium = .direct }, size, null);
                    _ = app.state.update(.{ .document = .{ .generation = 1, .page_sizes = &pages, .page_offsets = &offsets } });
                    try std.testing.expect(!app.input("j"));
                    if (command) try std.testing.expect(!app.input(":zoom 200"));
                }
                defer reference.deinit();
                defer fragmented.deinit();
                try std.testing.expect(!reference.input(sequence));
                try std.testing.expect(!fragmented.input(sequence[0..split]));
                try std.testing.expect(!fragmented.input(sequence[split..]));
                try std.testing.expectEqual(reference.state.anchor, fragmented.state.anchor);
                try std.testing.expectEqual(reference.state.pan_x, fragmented.state.pan_x);
                try std.testing.expectEqual(reference.state.command_open, fragmented.state.command_open);
                try std.testing.expectEqual(0, fragmented.pending_input_len);
                if (command) {
                    try std.testing.expect(!fragmented.input("\r"));
                    try std.testing.expectEqual(2, fragmented.state.zoom);
                }
            }
        }
    }
}

test "standalone Escape closes the command only after its deadline" {
    const gpa = std.testing.allocator;
    const app = try gpa.create(App);
    defer gpa.destroy(app);
    app.init(std.testing.io, gpa, .{ .path = "unused.pdf", .page = 1, .dark = false, .watch = false, .medium = .direct }, .{ .cols = 40, .rows = 3, .cell_width = 10, .cell_height = 20 }, null);
    defer app.deinit();
    try std.testing.expect(!app.input(":zoom 200\x1b"));
    const started = app.escape_started.?;
    app.expireInput(started.addDuration(.fromMilliseconds(escape_timeout_ms - 1)));
    try std.testing.expect(app.state.command_open);
    app.expireInput(started.addDuration(.fromMilliseconds(escape_timeout_ms)));
    try std.testing.expect(!app.state.command_open);
    try std.testing.expectEqual(0, app.pending_input_len);
    try std.testing.expect(app.input("q"));
}

test "control-bearing filenames cannot change the terminal through the status line" {
    const gpa = std.testing.allocator;
    const size: terminal.Size = .{ .cols = 80, .rows = 3, .cell_width = 1, .cell_height = 1 };
    const emulator: *Emulator = try .create(std.testing.io, gpa, size);
    defer emulator.destroy();
    try emulator.output.writeAll("sentinel");
    var state: viewer.State = .init("report\x1b[2J\r\n\x07\x7f\xc2\x9b\xff.pdf", size, false, 1);
    var frame: viewer.Frame = undefined;
    state.layout(&frame);
    try drawStatus(&emulator.output, frame.status(), size);
    try emulator.output.flush();
    const text = try emulator.text(gpa);
    defer gpa.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "sentinel"));
    try std.testing.expect(std.mem.indexOf(u8, text, "report?[2J??????.pdf") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "loading...") != null);
}

test "tiles stay on screen through a resize that keeps them" {
    const gpa = std.testing.allocator;
    const size: terminal.Size = .{ .cols = 40, .rows = 11, .cell_width = 10, .cell_height = 20 };
    const emulator: *Emulator = try .create(std.testing.io, gpa, size);
    defer emulator.destroy();
    const app = try gpa.create(App);
    defer gpa.destroy(app);
    app.init(std.testing.io, gpa, .{
        .path = "src/document/testdata/red-square.pdf",
        .page = 1,
        .dark = false,
        .watch = false,
        .medium = .shared_memory,
    }, size, null);
    defer app.deinit();
    try app.settle(&emulator.output);

    // Only the height changes, so the same tiles are wanted and are placed
    // again without being uploaded again.
    const taller: terminal.Size = .{ .cols = 40, .rows = 12, .cell_width = 10, .cell_height = 20 };
    try emulator.resize(taller);
    app.resize(taller);
    try app.settle(&emulator.output);
    const screen = try emulator.screenshot(gpa);
    defer gpa.free(screen.pixels);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, screen.pixel(80, 120));
}

test "images render in the terminal, survive failed reloads, and reload across formats" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "image", .data = @embedFile("../document/testdata/red-square.png") });
    const path = try tmp.dir.realPathFileAlloc(io, "image", gpa);
    defer gpa.free(path);
    const size: terminal.Size = .{ .cols = 40, .rows = 11, .cell_width = 10, .cell_height = 20 };
    const emulator: *Emulator = try .create(io, gpa, size);
    defer emulator.destroy();
    const app = try gpa.create(App);
    defer gpa.destroy(app);
    app.init(io, gpa, .{ .path = path, .page = 1, .dark = false, .watch = true, .medium = .direct }, size, null);
    defer app.deinit();
    try app.settle(&emulator.output);
    try std.testing.expectEqual(null, app.open_error);
    const screen = try emulator.screenshot(gpa);
    defer gpa.free(screen.pixels);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, screen.pixel(80, 120));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, screen.pixel(300, 40));
    try std.testing.expect(!app.input("i++j"));
    try app.settle(&emulator.output);
    const generation = app.state.document.generation;
    const zoomed = try emulator.screenshot(gpa);
    defer gpa.free(zoomed.pixels);

    try tmp.dir.writeFile(io, .{ .sub_path = "image", .data = @embedFile("../document/testdata/red-square.png")[0..40] });
    app.renderer.reload();
    try app.settle(&emulator.output);
    try std.testing.expectEqual(generation, app.state.document.generation);
    try std.testing.expectEqual(null, app.open_error);
    const unchanged = try emulator.screenshot(gpa);
    defer gpa.free(unchanged.pixels);
    try std.testing.expectEqualSlices(u8, zoomed.pixels, unchanged.pixels);

    // Failed loads leave the previous image available even for uncached tiles.
    try std.testing.expect(!app.input("=igg"));
    try app.settle(&emulator.output);
    const retained = try emulator.screenshot(gpa);
    defer gpa.free(retained.pixels);
    try std.testing.expectEqualSlices(u8, screen.pixels, retained.pixels);

    for ([_][]const u8{
        @embedFile("../document/testdata/red-square.pdf"),
        @embedFile("../document/testdata/red-square.png"),
    }, 1..) |bytes, index| {
        try tmp.dir.writeFile(io, .{ .sub_path = "image", .data = bytes });
        app.renderer.reload();
        try app.settle(&emulator.output);
        try std.testing.expectEqual(generation + @as(u32, @intCast(index)), app.state.document.generation);
        const reloaded = try emulator.screenshot(gpa);
        defer gpa.free(reloaded.pixels);
        try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, reloaded.pixel(80, 120));
    }
}
