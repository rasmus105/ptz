//! The interactive viewer: connects the viewer's logic (`viewer/`) to the
//! terminal, the render thread and the file on disk.
//!
//! `App` does the work for each kind of input and draws frames; it takes the
//! terminal's output as a stream, so tests drive it against an emulator with
//! the renderer stepped by hand. `run` is the event loop around it for a real
//! terminal: it waits on keys, render results, resizes and a timer for
//! watching the file, and owns all blocking.

// std
const std = @import("std");

// project
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

/// Base64 bytes uploaded per frame. Uploads beyond it wait for the next
/// loop iteration, so keys are handled between large uploads.
const upload_bytes_per_frame = 8 * 1024 * 1024;
/// How often to check the file for changes when watching.
const watch_interval_ms = 250;

// ====================================================================================================
// Types
// ====================================================================================================

pub const Options = struct {
    path: []const u8,
    /// Page to show first, counting from 1.
    page: u32,
    dark: bool,
    watch: bool,
};

pub const App = struct {
    gpa: std.mem.Allocator,
    state: viewer.State,
    renderer: Renderer,
    cache: Cache,
    /// The loaded document's page sizes, which `state` points to.
    page_sizes: []pdf.Size,
    first_page: u32,
    frame: viewer.Frame,
    results: std.ArrayList(Renderer.Result),
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
            .state = .init(std.fs.path.basename(options.path), size, options.dark),
            .renderer = undefined,
            .cache = .empty,
            .page_sizes = &.{},
            .first_page = options.page,
            .frame = undefined,
            .results = .empty,
            .dirty = true,
            .open_error = null,
        };
        app.renderer.init(io, gpa, options.path, wake_fd);
    }

    pub fn deinit(app: *App) void {
        app.renderer.deinit();
        for (app.results.items) |result| result.deinit(app.gpa);
        app.results.deinit(app.gpa);
        app.cache.deinit(app.gpa);
        app.gpa.free(app.page_sizes);
        app.* = undefined;
    }

    pub fn handle(app: *App, event: viewer.Event) viewer.Effect {
        app.dirty = true;
        const effect = app.state.update(event);
        if (effect == .reload) app.renderer.reload();
        return effect;
    }

    /// Takes in what the renderer finished since the last call.
    pub fn collect(app: *App) std.mem.Allocator.Error!void {
        defer app.results.clearRetainingCapacity();
        try app.renderer.collect(&app.results);
        for (app.results.items) |result| {
            app.dirty = true;
            switch (result) {
                .opened => |page_sizes| {
                    const old = app.page_sizes;
                    app.page_sizes = page_sizes;
                    _ = app.state.update(.{ .document = page_sizes });
                    app.gpa.free(old);
                    if (app.first_page > 0) {
                        _ = app.state.apply(.{ .goto_page = app.first_page });
                        app.first_page = 0;
                    }
                },
                .open_failed => |err| {
                    if (app.page_sizes.len == 0) app.open_error = err;
                    var buffer: [64]u8 = undefined;
                    _ = app.state.update(.{ .message = std.fmt.bufPrint(&buffer, "reload failed: {t}", .{err}) catch "reload failed" });
                },
                .tile => |tile| try app.cache.put(app.gpa, tile.key, tile.encoded),
                .render_failed => |key| {
                    try app.cache.putFailed(app.gpa, key);
                    var buffer: [64]u8 = undefined;
                    _ = app.state.update(.{ .message = std.fmt.bufPrint(&buffer, "cannot render page {d}", .{key.page + 1}) catch "cannot render" });
                },
            }
        }
    }

    /// Draws the current frame, asking the renderer for missing tiles and
    /// uploading finished ones. Stays dirty while uploads are pending.
    pub fn draw(app: *App, output: *std.Io.Writer) std.Io.Writer.Error!void {
        const frame = &app.frame;
        app.state.layout(frame);
        app.dirty = false;

        var missing: [viewer.wanted_max]viewer.Tile = undefined;
        var missing_len: u32 = 0;
        var upload_budget: usize = upload_bytes_per_frame;
        for (frame.wanted()) |tile| {
            const entry = app.cache.use(tile.key) orelse {
                missing[missing_len] = tile;
                missing_len += 1;
                continue;
            };
            const encoded = entry.encoded orelse continue;
            if (encoded.base64.len > upload_budget and upload_budget < upload_bytes_per_frame) {
                app.dirty = true;
                continue;
            }
            upload_budget -|= encoded.base64.len;
            try app.cache.upload(app.gpa, output, entry);
        }
        app.renderer.want(missing[0..missing_len]);

        try output.writeAll(terminal.sync_begin);
        try graphics.clearPlacements(output);
        const size = app.state.size;
        for (frame.slices()) |slice| {
            const ready = if (app.cache.use(slice.tile)) |entry| (if (entry.encoded == null and !entry.failed) entry else null) else null;
            const entry = ready orelse app.cache.useStale(slice.tile) orelse continue;
            try graphics.place(output, .{
                .image = entry.id,
                .source = .{ .x = slice.source_x, .y = slice.source_y, .width = slice.width, .height = slice.height },
                .col = @intCast(slice.x / size.cell_width),
                .row = @intCast(slice.y / size.cell_height),
                .x_offset = @intCast(slice.x % size.cell_width),
                .y_offset = @intCast(slice.y % size.cell_height),
            });
        }
        try drawStatus(output, frame.status(), size);
        try output.writeAll(terminal.sync_end);
        try app.cache.evict(output);
        try output.flush();
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

    const app = try gpa.create(App);
    defer gpa.destroy(app);
    app.init(io, gpa, options, size, wake_fds[1]);
    defer app.deinit();
    try app.renderer.start();

    try output.writeAll(terminal.fullscreen_enter);
    defer {
        app.cache.freeAll(output) catch {};
        output.writeAll(terminal.fullscreen_leave) catch {};
        output.flush() catch {};
    }

    var watch: Watch = .init(io, options.path);
    var input_buffer: [256]u8 = undefined;
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
            const len = try posix.read(posix.STDIN_FILENO, &input_buffer);
            var rest = input_buffer[0..len];
            while (rest.len > 0) {
                const decoded = terminal.Key.decode(rest);
                rest = rest[decoded.len..];
                if (app.handle(.{ .key = decoded.key }) == .quit) return;
            }
        }
        if (fds[1].revents != 0) {
            const len = try posix.read(wake_fds[0], &input_buffer);
            if (std.mem.indexOfScalar(u8, input_buffer[0..len], 'r') != null) {
                var stdin: terminal.Input = .init(&input_buffer, 100);
                const resized = terminal.size(&stdin.interface, output) catch size;
                try output.writeAll("\x1b[2J");
                _ = app.handle(.{ .resize = resized });
            }
        }
        try app.collect();
        if (options.watch and watch.changed(io)) app.renderer.reload();
    }
}

// ====================================================================================================
// Private Functions
// ====================================================================================================

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

    fn changed(watch: *Watch, io: std.Io) bool {
        const now: std.Io.Timestamp = .now(io, .awake);
        if (watch.checked.durationTo(now).toMilliseconds() < watch_interval_ms) return false;
        watch.checked = now;

        const current = stamp(io, watch.path) orelse return false;
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

/// The status line, in reverse video across the last row.
fn drawStatus(output: *std.Io.Writer, status: []const u8, size: terminal.Size) std.Io.Writer.Error!void {
    const text = status[0..@min(status.len, size.cols)];
    try output.print("\x1b[{d};1H\x1b[7m{s}", .{ size.rows, text });
    try output.splatByteAll(' ', size.cols - text.len);
    try output.writeAll("\x1b[0m");
}

// ====================================================================================================
// Tests
// ====================================================================================================

const Emulator = @import("../emulator/main.zig").Emulator;

test {
    _ = Cache;
    _ = Renderer;
}

/// Runs the app against an emulator until nothing is left to render.
fn settle(app: *App, emulator: *Emulator) !void {
    for (0..100) |_| {
        try app.draw(&emulator.output);
        const worked = app.renderer.step();
        try app.collect();
        if (!worked and !app.dirty) return;
    }
    return error.TestDidNotSettle;
}

test "shows the document, and keys move through it" {
    const gpa = std.testing.allocator;
    const size: terminal.Size = .{ .cols = 40, .rows = 11, .cell_width = 10, .cell_height = 20 };
    const emulator: *Emulator = try .create(std.testing.io, gpa, size);
    defer emulator.destroy();
    const app = try gpa.create(App);
    defer gpa.destroy(app);
    app.init(std.testing.io, gpa, .{ .path = "src/pdf/testdata/red-square.pdf", .page = 1, .dark = false, .watch = false }, size, null);
    defer app.deinit();
    try settle(app, emulator);

    // 400 px wide view: the 200x100 pt page at 2x, so the red square spans
    // x 40..120 and y 80..160.
    const screen = try emulator.screenshot(gpa);
    defer gpa.free(screen.pixels);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, screen.pixel(80, 120));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, screen.pixel(300, 40));
    const text = try emulator.text(gpa);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "red-square.pdf  1/1  100%") != null);

    // Dark mode inverts the page.
    _ = app.handle(.{ .key = .{ .char = 'i' } });
    try settle(app, emulator);
    const dark = try emulator.screenshot(gpa);
    defer gpa.free(dark.pixels);
    try std.testing.expectEqual([4]u8{ 0, 255, 255, 255 }, dark.pixel(80, 120));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, dark.pixel(300, 40));
}
