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
const Emulator = @import("../emulator/main.zig").Emulator;
const graphics = @import("../graphics/main.zig");
const pdf = @import("../pdf/main.zig");
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

/// Bytes uploaded per frame. Uploads beyond it wait for the next loop
/// iteration, so keys are handled between large uploads.
const upload_bytes_per_frame = 8 * 1024 * 1024;
/// How often to check the file for changes when watching.
const watch_interval_ms = 250;
/// The longest key sequence kept while waiting for the rest of it.
const pending_input_max = 32;

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
    /// The loaded document's page sizes and layout scratch, which `state`
    /// points to.
    page_sizes: []pdf.Size,
    tops: []i64,
    frame: viewer.Frame,
    results: std.ArrayList(Renderer.Result),
    /// The start of a key sequence cut off at the end of the last input.
    pending_input: [pending_input_max]u8,
    pending_input_len: u32,
    /// Whether the screen is out of date.
    dirty: bool,
    /// Set when the document can't be loaded and there is nothing to show.
    open_error: ?pdf.Error,

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
            .cache = .empty,
            .page_sizes = &.{},
            .tops = &.{},
            .frame = undefined,
            .results = .empty,
            .pending_input = undefined,
            .pending_input_len = 0,
            .dirty = true,
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
        app.gpa.free(app.tops);
        app.* = undefined;
    }

    /// Handles bytes typed in the terminal. A key sequence cut off at the
    /// end is kept until the rest arrives.
    pub fn input(app: *App, bytes: []const u8) viewer.Effect {
        var buffer: [pending_input_max + 256]u8 = undefined;
        var rest = bytes;
        while (rest.len > 0 or app.pending_input_len > 0) {
            // Prefix what was left over from last time.
            const room = buffer.len - app.pending_input_len;
            const taken = rest[0..@min(rest.len, room)];
            rest = rest[taken.len..];
            @memcpy(buffer[0..app.pending_input_len], app.pending_input[0..app.pending_input_len]);
            @memcpy(buffer[app.pending_input_len..][0..taken.len], taken);
            var unread = buffer[0 .. app.pending_input_len + taken.len];
            app.pending_input_len = 0;

            while (unread.len > 0) {
                const decoded = terminal.Key.decode(unread) orelse {
                    // Too long to be a key sequence: drop it.
                    if (unread.len > pending_input_max) break;
                    @memcpy(app.pending_input[0..unread.len], unread);
                    app.pending_input_len = @intCast(unread.len);
                    break;
                };
                unread = unread[decoded.len..];
                app.dirty = true;
                const effect = app.state.update(.{ .key = decoded.key });
                switch (effect) {
                    .none => {},
                    .quit => return .quit,
                    .reload => app.renderer.reload(),
                }
            }
            if (rest.len == 0) break;
        }
        return .none;
    }

    pub fn resize(app: *App, size: terminal.Size) void {
        app.dirty = true;
        _ = app.state.update(.{ .resize = size });
    }

    /// Takes in what the renderer finished since the last call.
    pub fn collect(app: *App) void {
        app.renderer.collect(&app.results);
        defer app.results.clearRetainingCapacity();
        for (app.results.items, 0..) |result, index| {
            app.dirty = true;
            app.take(result) catch {
                // Out of memory: drop this and the rest, which only costs
                // rendering them again.
                for (app.results.items[index..]) |unused| unused.deinit(app.gpa);
                _ = app.state.update(.{ .message = "out of memory" });
                return;
            };
        }
    }

    /// Draws the current frame, asking the renderer for missing tiles and
    /// uploading finished ones. Stays dirty while uploads are pending.
    pub fn draw(app: *App, output: *std.Io.Writer) std.Io.Writer.Error!void {
        const frame = &app.frame;
        app.state.layout(frame);

        var missing: [viewer.wanted_max]viewer.Tile = undefined;
        app.renderer.want(app.cache.findMissing(frame.wanted(), &missing));
        app.dirty = try app.cache.upload(app.gpa, output, frame.wanted(), upload_bytes_per_frame);

        try output.writeAll(terminal.sync_begin);
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
            app.collect();
            if (app.open_error != null) return;
            try app.draw(output);
            if (!app.renderer.step() and !app.dirty) return;
        }
    }

    fn take(app: *App, result: Renderer.Result) std.mem.Allocator.Error!void {
        switch (result) {
            .opened => |opened| {
                errdefer result.deinit(app.gpa);
                const tops = try app.gpa.alloc(i64, opened.page_sizes.len);
                _ = app.state.update(.{ .document = .{
                    .generation = opened.generation,
                    .page_sizes = opened.page_sizes,
                    .tops = tops,
                } });
                app.gpa.free(app.page_sizes);
                app.gpa.free(app.tops);
                app.page_sizes = opened.page_sizes;
                app.tops = tops;
            },
            .open_failed => |err| {
                if (app.state.document.generation == 0) app.open_error = err;
                var buffer: [64]u8 = undefined;
                const text = std.fmt.bufPrint(&buffer, "reload failed: {t}", .{err}) catch unreachable;
                _ = app.state.update(.{ .message = text });
            },
            .tile => |tile| try app.cache.put(app.gpa, tile.tile, tile.encoded),
            .render_failed => |tile| {
                try app.cache.putFailed(app.gpa, tile);
                var buffer: [64]u8 = undefined;
                const text = std.fmt.bufPrint(&buffer, "cannot render page {d}", .{tile.page + 1}) catch unreachable;
                _ = app.state.update(.{ .message = text });
            },
        }
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
    terminal.notifyOnResize(wake_fds[1]);
    defer terminal.notifyOnResize(null);

    const app = try gpa.create(App);
    defer gpa.destroy(app);
    app.init(io, gpa, options, size, wake_fds[1]);
    defer app.deinit();
    try app.renderer.start();

    try output.writeAll(terminal.fullscreen_enter);
    defer {
        app.cache.clear(gpa, output) catch {};
        output.writeAll(terminal.fullscreen_leave) catch {};
        output.flush() catch {};
    }

    var watch: Watch = .init(io, options.path);
    var read_buffer: [256]u8 = undefined;
    while (true) {
        if (app.dirty) try app.draw(output);
        if (app.open_error) |err| return err;

        var fds = [_]posix.pollfd{
            .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = wake_fds[0], .events = posix.POLL.IN, .revents = 0 },
        };
        const timeout_ms: i32 = if (app.dirty) 0 else if (options.watch) watch_interval_ms else -1;
        _ = try posix.poll(&fds, timeout_ms);

        if (fds[0].revents != 0) {
            const len = try posix.read(posix.STDIN_FILENO, &read_buffer);
            // The terminal went away.
            if (len == 0) return;
            if (app.input(read_buffer[0..len]) == .quit) return;
        }
        if (fds[1].revents != 0) {
            const len = try posix.read(wake_fds[0], &read_buffer);
            if (std.mem.indexOfScalar(u8, read_buffer[0..len], 'r') != null) {
                var stdin: terminal.Input = .init(&read_buffer, 100);
                const resized = terminal.size(&stdin.interface, output) catch app.state.size;
                try output.writeAll(terminal.clear_screen);
                app.resize(resized);
            }
        }
        app.collect();
        if (options.watch and watch.changed(io)) app.renderer.reload();
    }
}

// ====================================================================================================
// Private Functions
// ====================================================================================================

/// The status line in reverse video across the last row. Columns are
/// counted as code points, which is right for most file names.
fn drawStatus(output: *std.Io.Writer, status: viewer.Status, size: terminal.Size) std.Io.Writer.Error!void {
    const gap = "  ";
    const right = truncate(status.right, size.cols, false);
    const right_cols = codepoints(right);
    const left_room = (size.cols - right_cols) -| if (right_cols > 0) gap.len else 0;
    const left = truncate(status.left, left_room, status.keep_end);
    const padding = size.cols - right_cols - codepoints(left);

    try terminal.moveCursor(output, size.rows - 1, 0);
    try output.writeAll(terminal.style_reverse);
    try output.writeAll(left);
    try output.splatByteAll(' ', padding);
    try output.writeAll(right);
    try output.writeAll(terminal.style_reset);
}

/// The longest prefix (or suffix, with `keep_end`) of `text` with at most
/// `cols` code points.
fn truncate(text: []const u8, cols: usize, keep_end: bool) []const u8 {
    const total = codepoints(text);
    if (total <= cols) return text;
    var skip = if (keep_end) total - cols else cols;
    var index: usize = 0;
    while (skip > 0 and index < text.len) : (skip -= 1) {
        index += std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
    }
    index = @min(index, text.len);
    return if (keep_end) text[index..] else text[0..index];
}

fn codepoints(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

// ====================================================================================================
// Tests
// ====================================================================================================

test {
    _ = Cache;
    _ = Renderer;
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
}

test "shows the document, and keys move through it" {
    const gpa = std.testing.allocator;
    const size: terminal.Size = .{ .cols = 40, .rows = 11, .cell_width = 10, .cell_height = 20 };
    const emulator: *Emulator = try .create(std.testing.io, gpa, size);
    defer emulator.destroy();
    const app = try gpa.create(App);
    defer gpa.destroy(app);
    app.init(std.testing.io, gpa, .{
        .path = "src/pdf/testdata/red-square.pdf",
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
    try std.testing.expectEqual(.none, app.input("\x1b["));
    try std.testing.expectEqual(.none, app.input("Bi"));
    try app.settle(&emulator.output);
    const dark = try emulator.screenshot(gpa);
    defer gpa.free(dark.pixels);
    try std.testing.expectEqual([4]u8{ 0, 255, 255, 255 }, dark.pixel(80, 120));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, dark.pixel(300, 40));
    try std.testing.expectEqual(.quit, app.input("q"));
}
