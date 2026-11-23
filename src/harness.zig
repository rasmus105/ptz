//! Lets agents see what ptz shows without a real terminal: runs the viewer in
//! an emulated terminal, presses the given keys, then prints the screen's
//! text and writes a PNG of its images (text is not drawn into it).
//!
//!     zig build harness -- paper.pdf --keys '3G<C-d>++'
//!
//! With `--fuzz N` it instead presses N random keys and resizes, rendering
//! only a little between them as a busy render thread would, and checks the
//! screen along the way: every visible part of a page must be covered by an
//! image, and the screen must match a fresh viewer's in the same state. The
//! run is reproducible from `--seed`.
//!
//! `--threaded` instead uses the real render thread and wake pipe, pacing
//! input with `--key-delay-ms` and reporting incomplete frames and their
//! duration. `--timeout-ms` bounds the initial and final wait for rendering.

// std
const std = @import("std");

// project
const app = @import("app/main.zig");
const Emulator = @import("emulator/main.zig").Emulator;
const terminal = @import("terminal/main.zig");

// local
const argparse = @import("argparse.zig");

// aliases
const posix = std.posix;

// ====================================================================================================
// Constants
// ====================================================================================================

/// Ghostty logs rejected commands as warnings. Missing images may recover
/// through replies; other rejections fail screen validation.
pub const std_options: std.Options = .{ .log_level = .warn, .logFn = log };

/// Key names usable in `--keys`, as `<Name>`.
const named_keys = [_]struct { []const u8, []const u8 }{
    .{ "CR", "\r" },       .{ "Esc", "\x1b" },    .{ "BS", "\x7f" },        .{ "Tab", "\t" },
    .{ "Up", "\x1b[A" },   .{ "Down", "\x1b[B" }, .{ "Right", "\x1b[C" },   .{ "Left", "\x1b[D" },
    .{ "Home", "\x1b[H" }, .{ "End", "\x1b[F" },  .{ "PageUp", "\x1b[5~" }, .{ "PageDown", "\x1b[6~" },
};

/// What `--fuzz` presses, in `--keys` notation. Repeats make an event likelier.
const fuzz_keys = [_][]const u8{
    "j",             "j",         "k",           "k",     "<C-d>",         "<C-u>",
    "<C-f>",         "<C-b>",     " ",           "h",     "l",             "3l",
    "G",             "gg",        "12G",         "+",     "+",             "-",
    "-",             "3+",        "2-",          "=",     "i",             "<Left>",
    "<Right>",       "<Right>",   "9<Right>",    "5j",    ":zoom 800<CR>", ":zoom 30<CR>",
    ":zoom 250<CR>", ":2<CR>",    ":reload<CR>", "<Esc>", ":<BS><BS>",     ":zoom<CR>",
    ":x<Esc>",       ":dark<CR>", "<Home>",      "<End>", "<PageDown>",    "<PageUp>",
};
/// Checks the screen after this many events, and at the end.
const fuzz_check_interval = 16;
/// How far a pixel may be from a fresh viewer's, per channel, and how many
/// may be further. Raster resampling can vary slightly with tile boundaries
/// and the resolution of decoded images already in the engine cache.
const fuzz_tolerance = 32;
const fuzz_outliers_max = 16;

/// Unexpected image command warnings; missing uploads may recover through replies.
var terminal_warnings: u32 = 0;
var terminal_missing_images: u32 = 0;

// ====================================================================================================
// Types
// ====================================================================================================

const Options = struct {
    file: []const u8,
    page: u32 = 1,
    keys: []const u8 = "",
    dark: bool = false,
    cols: u16 = 100,
    rows: u16 = 30,
    cell_width: u16 = 10,
    cell_height: u16 = 20,
    out: []const u8 = "zig-out/screen.png",
    fuzz: u32 = 0,
    seed: u64 = 0,
    direct: bool = false,
    image_limit_mb: u32 = 320,
    threaded: bool = false,
    key_delay_ms: u32 = 16,
    timeout_ms: u32 = 5000,

    pub const positional = .{ .file = "Document or image file to open" };
    pub const shorts = .{ .page = 'p', .keys = 'k', .out = 'o' };
    pub const help = .{
        .page = "Page to open at",
        .keys = "Keys to press, with <C-x> for Ctrl and names like <CR>, <Esc>, <Down>",
        .dark = "Start in dark mode",
        .cols = "Terminal width in cells",
        .rows = "Terminal height in cells",
        .cell_width = "Cell width in pixels",
        .cell_height = "Cell height in pixels",
        .out = "Where to write the screenshot",
        .fuzz = "Press this many random keys and resizes, checking the screen",
        .seed = "Seed for --fuzz",
        .direct = "Send images inline instead of in shared memory",
        .image_limit_mb = "Emulated terminal's image storage limit in decimal MB",
        .threaded = "Use the real render thread and measure incomplete frames",
        .key_delay_ms = "Delay between events with --threaded",
        .timeout_ms = "Maximum wait for initial and final rendering with --threaded",
    };
};

const Cli = argparse.Cli(Options, .{
    .name = "harness",
    .summary = "Run ptz in an emulated terminal and capture the screen",
    .version = "dev",
});

// ====================================================================================================
// Public API
// ====================================================================================================

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const options = try Cli.parse(init);
    defer if (terminal_missing_images > 0) {
        std.debug.print("terminal reported {d} missing image commands\n", .{terminal_missing_images});
    };

    const size: terminal.Size = .{
        .cols = options.cols,
        .rows = options.rows,
        .cell_width = options.cell_width,
        .cell_height = options.cell_height,
    };
    const app_options: app.Options = .{
        .path = options.file,
        .page = options.page,
        .dark = options.dark,
        .watch = false,
        .medium = if (options.direct) .direct else .shared_memory,
    };
    if (options.fuzz > 0 and !options.threaded) return fuzz(io, gpa, app_options, size, options);

    var wake_fds: [2]posix.fd_t = .{ -1, -1 };
    defer for (wake_fds) |fd| {
        if (fd >= 0) _ = std.c.close(fd);
    };
    if (options.threaded) {
        if (std.c.pipe(&wake_fds) != 0) return error.Unexpected;
        const flags: c_int = @bitCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
        if (std.c.fcntl(wake_fds[1], posix.F.SETFL, flags) != 0) return error.Unexpected;
    }

    const emulator: *Emulator = try .create(io, gpa, size);
    defer emulator.destroy();
    emulator.terminal.setKittyGraphicsSizeLimit(gpa, @as(usize, options.image_limit_mb) * 1000 * 1000);
    const viewer = try gpa.create(app.App);
    defer gpa.destroy(viewer);
    viewer.init(io, gpa, app_options, size, if (options.threaded) wake_fds[1] else null);
    defer viewer.deinit();

    if (options.threaded) {
        try threaded(io, gpa, emulator, viewer, wake_fds[0], options);
    } else {
        try settle(io, viewer, emulator, options.timeout_ms);
        var keys = options.keys;
        while (keys.len > 0 and viewer.open_error == null) {
            var bytes_buffer: [8]u8 = undefined;
            const bytes, const len = keyBytes(keys, &bytes_buffer) catch |err|
                std.process.fatal("bad key at {q}: {t}", .{ keys, err });
            keys = keys[len..];
            if (viewer.input(bytes)) break;
            // Each harness key is complete, including a standalone Escape.
            if (viewer.escape_started) |started| viewer.expireInput(started.addDuration(.fromSeconds(1)));
            try settle(io, viewer, emulator, options.timeout_ms);
        }
    }
    if (viewer.open_error) |err| std.process.fatal("cannot open {q}: {t}", .{ options.file, err });

    try fuzzCheck(io, gpa, emulator, viewer, app_options);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    const text = try emulator.text(gpa);
    defer gpa.free(text);
    try stdout.print("{s}\n", .{text});

    const screenshot = try emulator.screenshot(gpa);
    defer gpa.free(screenshot.pixels);
    try saveScreenshot(io, gpa, screenshot, options.out);

    try stdout.print("screenshot written to {s}\n", .{options.out});
    try stdout.flush();
}

// ====================================================================================================
// Private Functions
// ====================================================================================================

fn log(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (scope == .kitty_gfx and level == .warn) {
        const missing_image = comptime std.mem.eql(u8, format, "erroneous kitty graphics response: {s}");
        if (missing_image and std.mem.startsWith(u8, args[0], "ENOENT:")) {
            terminal_missing_images += 1;
            return;
        }
        terminal_warnings += 1;
    }
    std.log.defaultLog(level, scope, format, args);
}

/// A flush only queues image commands. Deliver terminal replies before
/// deciding that rendering is complete, so missing uploads can be retried.
fn settle(io: std.Io, viewer: *app.App, emulator: *Emulator, timeout_ms: u32) !void {
    const started: std.Io.Timestamp = .now(io, .awake);
    while (true) {
        try viewer.settle(&emulator.output);
        if (viewer.open_error != null) return;
        var buffer: [app.input_len_max]u8 = undefined;
        while (true) {
            const len = try emulator.input.readSliceShort(&buffer);
            if (len == 0) break;
            std.debug.assert(!viewer.input(buffer[0..len]));
        }
        if (!viewer.dirty) return;
        if (started.durationTo(.now(io, .awake)).toMilliseconds() >= timeout_ms) return error.RenderTimeout;
    }
}

/// Keeps the production render thread and wake pipe, and observes frames
/// before rendering catches up instead of making each input wait for it.
fn threaded(io: std.Io, gpa: std.mem.Allocator, emulator: *Emulator, viewer: *app.App, wake_fd: posix.fd_t, options: Options) !void {
    try viewer.renderer.start();
    var prng: std.Random.DefaultPrng = .init(options.seed);
    const random = prng.random();
    var events: std.Io.Writer.Allocating = .init(gpa);
    defer events.deinit();
    errdefer std.debug.print("events: {s}\n", .{events.written()});
    var keys = options.keys;
    var event_index: u32 = 0;
    var ready = false;
    var last_event: std.Io.Timestamp = .now(io, .awake);
    const started = last_event;
    var uncovered_started: ?std.Io.Timestamp = null;
    var uncovered_max_ms: i64 = 0;
    var draw_max_ms: i64 = 0;
    var uncovered_frames: u32 = 0;
    var frames: u32 = 0;
    var uncovered: u64 = 0;
    var first_covered = false;
    var final_covered = false;
    defer {
        if (uncovered_started) |since| uncovered_max_ms = @max(uncovered_max_ms, since.durationTo(.now(io, .awake)).toMilliseconds());
        std.debug.print("threaded seed {d}: {d} events, {d}/{d} incomplete frames, longest uncovered {d} ms, slowest draw {d} ms\n", .{
            options.seed, event_index, uncovered_frames, frames, uncovered_max_ms, draw_max_ms,
        });
    }

    while (true) {
        try viewer.collect();
        if (viewer.open_error != null) return;
        if (viewer.dirty) {
            const draw_started: std.Io.Timestamp = .now(io, .awake);
            try viewer.draw(&emulator.output);
            const drawn: std.Io.Timestamp = .now(io, .awake);
            draw_max_ms = @max(draw_max_ms, draw_started.durationTo(drawn).toMilliseconds());
            const screen = try emulator.screenshotExcluding(gpa, &viewer.highlights.images);
            defer gpa.free(screen.pixels);
            uncovered = uncoveredPixels(viewer, screen);
            frames += 1;
            if (uncovered > 0) {
                uncovered_frames += 1;
                if (uncovered_started == null) uncovered_started = draw_started;
            } else if (uncovered_started) |since| {
                uncovered_max_ms = @max(uncovered_max_ms, since.durationTo(drawn).toMilliseconds());
                uncovered_started = null;
            }
            if (!first_covered and viewer.state.document.generation != 0 and uncovered == 0) {
                first_covered = true;
                std.debug.print("first covered viewport: {d} ms\n", .{started.durationTo(drawn).toMilliseconds()});
            }
        }
        var replies_buffer: [app.input_len_max]u8 = undefined;
        while (true) {
            const len = try emulator.input.readSliceShort(&replies_buffer);
            if (len == 0) break;
            std.debug.assert(!viewer.input(replies_buffer[0..len]));
        }

        const now: std.Io.Timestamp = .now(io, .awake);
        const idle = viewer.renderer.idle();
        if (!ready and idle and !viewer.dirty and viewer.state.document.generation != 0) {
            ready = true;
            last_event = now;
            std.debug.print("initial rendering including prefetch: {d} ms\n", .{started.durationTo(now).toMilliseconds()});
        }
        const more_events = if (options.fuzz > 0) event_index < options.fuzz else keys.len > 0;
        if (ready and !more_events and event_index > 0 and !final_covered and uncovered == 0) {
            final_covered = true;
            std.debug.print("final covered viewport: {d} ms after last event\n", .{last_event.durationTo(now).toMilliseconds()});
        }
        if (ready and !more_events and idle and !viewer.dirty and uncovered == 0) return;
        const elapsed = last_event.durationTo(now).toMilliseconds();
        if ((!ready or !more_events) and elapsed >= options.timeout_ms) {
            const screen = try emulator.screenshot(gpa);
            defer gpa.free(screen.pixels);
            try saveScreenshot(io, gpa, screen, options.out);
            viewer.renderer.mutex.lockUncancelable(io);
            std.debug.print("rendering timed out with {d} uncovered pixels, idle {any}, {d} queued tiles, rendering {any}, {d} results, {d} uploaded bytes, {d} pending bytes; screenshot: {s}\n", .{
                uncovered,                   idle,                       viewer.renderer.wanted_len, viewer.renderer.rendering != null, viewer.renderer.results.items.len,
                viewer.cache.uploaded_bytes, viewer.cache.pending_bytes, options.out,
            });
            viewer.renderer.mutex.unlock(io);
            return error.RenderTimeout;
        }

        if (ready and more_events and elapsed >= options.key_delay_ms) {
            if (options.fuzz > 0 and random.uintLessThan(u32, 40) == 0) {
                const size: terminal.Size = .{
                    .cols = random.intRangeAtMost(u16, 20, 250),
                    .rows = random.intRangeAtMost(u16, 5, 70),
                    .cell_width = random.intRangeAtMost(u16, 6, 20),
                    .cell_height = random.intRangeAtMost(u16, 12, 40),
                };
                try events.writer.print("<resize {d}x{d} {d}x{d}>", .{ size.cols, size.rows, size.cell_width, size.cell_height });
                try emulator.resize(size);
                viewer.resize(size);
            } else {
                const event = if (options.fuzz > 0) fuzz_keys[random.uintLessThan(usize, fuzz_keys.len)] else keys;
                var rest = event;
                while (rest.len > 0) {
                    var bytes_buffer: [8]u8 = undefined;
                    const bytes, const len = try keyBytes(rest, &bytes_buffer);
                    try events.writer.writeAll(rest[0..len]);
                    rest = rest[len..];
                    if (viewer.input(bytes)) return;
                    if (viewer.escape_started) |since| viewer.expireInput(since.addDuration(.fromSeconds(1)));
                    if (options.fuzz == 0) break;
                }
                if (options.fuzz == 0) keys = rest;
            }
            event_index += 1;
            last_event = .now(io, .awake);
            continue;
        }

        var fds = [_]posix.pollfd{.{ .fd = wake_fd, .events = posix.POLL.IN, .revents = 0 }};
        const until_next: i64 = if (ready and more_events) @as(i64, options.key_delay_ms) - elapsed else @as(i64, options.timeout_ms) - elapsed;
        _ = try posix.poll(&fds, if (viewer.dirty) 0 else @intCast(std.math.clamp(until_next, 0, std.math.maxInt(i32))));
        if (fds[0].revents != 0) {
            var buffer: [256]u8 = undefined;
            _ = try posix.read(wake_fd, &buffer);
        }
    }
}

fn fuzz(io: std.Io, gpa: std.mem.Allocator, app_options: app.Options, start_size: terminal.Size, options: Options) !void {
    var prng: std.Random.DefaultPrng = .init(options.seed);
    const random = prng.random();
    // The events so far, to report with a failure.
    var events: std.Io.Writer.Allocating = .init(gpa);
    defer events.deinit();

    const emulator: *Emulator = try .create(io, gpa, start_size);
    defer emulator.destroy();
    emulator.terminal.setKittyGraphicsSizeLimit(gpa, @as(usize, options.image_limit_mb) * 1000 * 1000);
    const viewer = try gpa.create(app.App);
    defer gpa.destroy(viewer);
    viewer.init(io, gpa, app_options, start_size, null);
    defer viewer.deinit();
    try settle(io, viewer, emulator, options.timeout_ms);
    if (viewer.open_error) |err| std.process.fatal("cannot open {q}: {t}", .{ options.file, err });

    for (0..options.fuzz) |event_index| {
        if (random.uintLessThan(u32, 40) == 0) {
            const size: terminal.Size = .{
                .cols = random.intRangeAtMost(u16, 20, 250),
                .rows = random.intRangeAtMost(u16, 5, 70),
                .cell_width = random.intRangeAtMost(u16, 6, 20),
                .cell_height = random.intRangeAtMost(u16, 12, 40),
            };
            try events.writer.print("<resize {d}x{d} {d}x{d}>", .{ size.cols, size.rows, size.cell_width, size.cell_height });
            try emulator.resize(size);
            viewer.resize(size);
        } else {
            const keys = fuzz_keys[random.uintLessThan(usize, fuzz_keys.len)];
            try events.writer.writeAll(keys);
            var rest = keys;
            while (rest.len > 0) {
                var bytes_buffer: [8]u8 = undefined;
                const bytes, const len = try keyBytes(rest, &bytes_buffer);
                rest = rest[len..];
                std.debug.assert(!viewer.input(bytes));
                if (viewer.escape_started) |since| viewer.expireInput(since.addDuration(.fromSeconds(1)));
            }
        }
        // A busy render thread finishes a few results at most between keys.
        for (0..random.uintAtMost(u32, 3)) |_| {
            _ = viewer.renderer.step();
            try viewer.collect();
            if (random.boolean()) try viewer.draw(&emulator.output);
        }
        if (viewer.dirty) try viewer.draw(&emulator.output);
        var replies_buffer: [app.input_len_max]u8 = undefined;
        while (true) {
            const len = try emulator.input.readSliceShort(&replies_buffer);
            if (len == 0) break;
            std.debug.assert(!viewer.input(replies_buffer[0..len]));
        }

        const check = (event_index + 1) % fuzz_check_interval == 0 or event_index + 1 == options.fuzz;
        if (terminal_warnings > 0 or check) {
            try settle(io, viewer, emulator, options.timeout_ms);
            fuzzCheck(io, gpa, emulator, viewer, app_options) catch |err| {
                const state = viewer.state;
                std.debug.print("seed {d}, event {d}: {t}\n{d}x{d} cells of {d}x{d} px, page {d} + {d} pt, zoom {d}, pan {d}, {d} slices, {d} wanted\nevents: {s}\n", .{
                    options.seed,              event_index,           err,
                    state.size.cols,           state.size.rows,       state.size.cell_width,
                    state.size.cell_height,    state.anchor.page + 1, state.anchor.y,
                    state.zoom,                state.pan_x,           viewer.frame.slices().len,
                    viewer.frame.wanted().len, events.written(),
                });
                return err;
            };
        }
    }
    std.debug.print("seed {d}: {d} events, no problems found\n", .{ options.seed, options.fuzz });
}

/// Checks a settled viewer's screen: every visible part of a page is covered
/// by an image, and the screen matches that of a fresh viewer in the same
/// state, which has no history to get wrong. Writes both screenshots to
/// zig-out on failure.
fn fuzzCheck(io: std.Io, gpa: std.mem.Allocator, emulator: *Emulator, viewer: *app.App, app_options: app.Options) !void {
    const screen = try emulator.screenshot(gpa);
    defer gpa.free(screen.pixels);
    errdefer saveScreenshot(io, gpa, screen, "zig-out/fuzz-actual.png") catch {};
    if (terminal_warnings > 0) return error.TerminalRejectedCommands;

    const state = &viewer.state;
    const uncovered = if (std.mem.allEqual(u32, &viewer.highlights.images, 0))
        uncoveredPixels(viewer, screen)
    else blk: {
        const document_screen = try emulator.screenshotExcluding(gpa, &viewer.highlights.images);
        defer gpa.free(document_screen.pixels);
        break :blk uncoveredPixels(viewer, document_screen);
    };
    if (uncovered > 0) {
        std.debug.print("{d} page pixels not covered by any image\n", .{uncovered});
        return error.Uncovered;
    }

    const fresh_emulator: *Emulator = try .create(io, gpa, state.size);
    defer fresh_emulator.destroy();
    const fresh = try gpa.create(app.App);
    defer gpa.destroy(fresh);
    var fresh_options = app_options;
    fresh_options.path = viewer.path;
    fresh.init(io, gpa, fresh_options, state.size, null);
    defer fresh.deinit();
    try settle(io, fresh, fresh_emulator, 5000);
    const document = fresh.state.document;
    fresh.state = state.*;
    fresh.state.document = document;
    if (fresh.state.search_query) |*query| query.generation = document.generation;
    // Recomputes the geometry for the fresh document.
    fresh.resize(state.size);
    try settle(io, fresh, fresh_emulator, 5000);
    const expected = try fresh_emulator.screenshot(gpa);
    defer gpa.free(expected.pixels);

    const text = try emulator.text(gpa);
    defer gpa.free(text);
    const expected_text = try fresh_emulator.text(gpa);
    defer gpa.free(expected_text);
    if (!std.mem.eql(u8, text, expected_text)) {
        std.debug.print("text differs from a fresh viewer's:\n{s}\n---- expected:\n{s}\n", .{ text, expected_text });
        return error.TextDiffers;
    }

    var differing: u64 = 0;
    // Bounding box of the differences, and the largest difference in a channel.
    var box: [4]u32 = .{ screen.width, screen.height, 0, 0 };
    var delta_max: u8 = 0;
    for (0..screen.height) |row| for (0..screen.width) |column| {
        const x: u32 = @intCast(column);
        const y: u32 = @intCast(row);
        const actual = screen.pixel(x, y);
        const wanted = expected.pixel(x, y);
        var delta: u8 = 0;
        for (actual, wanted) |a, b| delta = @max(delta, @max(a, b) - @min(a, b));
        if (delta <= fuzz_tolerance) continue;
        differing += 1;
        box = .{ @min(box[0], x), @min(box[1], y), @max(box[2], x + 1), @max(box[3], y + 1) };
        delta_max = @max(delta_max, delta);
    };
    if (differing > fuzz_outliers_max) {
        saveScreenshot(io, gpa, expected, "zig-out/fuzz-expected.png") catch {};
        std.debug.print("{d} pixels differ from a fresh viewer's, within x {d}..{d}, y {d}..{d}, by up to {d}\n", .{
            differing, box[0], box[2], box[1], box[3], delta_max,
        });
        return error.Differs;
    }
}

/// Counts missing page pixels independently of the tiles selected for rendering.
fn uncoveredPixels(viewer: *const app.App, screen: Emulator.Screenshot) u64 {
    // Where pages are, worked out from the geometry rather than the tiles.
    const state = &viewer.state;
    const geometry = state.geometry;
    var uncovered: u64 = 0;
    if (geometry.page_sizes.len > 0) {
        const view_top = geometry.offsetOf(state.anchor);
        const content_left: i64 = if (geometry.content_width <= geometry.view_width)
            @divFloor(@as(i64, geometry.view_width) - geometry.content_width, 2)
        else
            -@as(i64, state.pan_x);
        for (0..geometry.page_sizes.len) |index| {
            const page: u32 = @intCast(index);
            const top = geometry.pageTop(page) - view_top;
            const left = content_left + @divFloor(@as(i64, geometry.content_width) - geometry.pageWidth(page), 2);
            const y_end: u64 = @intCast(std.math.clamp(top + geometry.pageHeight(page), 0, geometry.view_height));
            const x_end: u64 = @intCast(std.math.clamp(left + geometry.pageWidth(page), 0, geometry.view_width));
            for (@intCast(std.math.clamp(top, 0, geometry.view_height))..y_end) |y| {
                for (@intCast(std.math.clamp(left, 0, geometry.view_width))..x_end) |x| {
                    if (screen.pixel(@intCast(x), @intCast(y))[3] == 0) uncovered += 1;
                }
            }
        }
    }
    return uncovered;
}

/// Writes `screenshot` as a PNG, with uncovered pixels in a dark grey like
/// a terminal's background.
fn saveScreenshot(io: std.Io, gpa: std.mem.Allocator, screenshot: Emulator.Screenshot, path: []const u8) !void {
    const pixels = try gpa.dupe(u8, screenshot.pixels);
    defer gpa.free(pixels);
    for (0..pixels.len / 4) |i| {
        if (pixels[i * 4 + 3] == 0) pixels[i * 4 ..][0..4].* = .{ 32, 32, 32, 255 };
    }
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var file_buffer: [64 * 1024]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(file, io, &file_buffer);
    try writePng(gpa, &file_writer.interface, screenshot.width, screenshot.height, pixels);
    try file_writer.interface.flush();
}

/// The bytes of the first key in `keys`, written to `buffer`, and how many
/// bytes of `keys` it took.
fn keyBytes(keys: []const u8, buffer: *[8]u8) !struct { []const u8, usize } {
    if (keys[0] != '<') {
        const len = @min(keys.len, std.unicode.utf8ByteSequenceLength(keys[0]) catch 1);
        return .{ keys[0..len], len };
    }
    const end = std.mem.indexOfScalar(u8, keys, '>') orelse return error.Unterminated;
    const name = keys[1..end];
    if (name.len == 3 and std.mem.startsWith(u8, name, "C-") and std.ascii.isLower(name[2])) {
        buffer[0] = name[2] - 'a' + 1;
        return .{ buffer[0..1], end + 1 };
    }
    for (named_keys) |named| {
        if (std.mem.eql(u8, named[0], name)) return .{ named[1], end + 1 };
    }
    return error.UnknownKey;
}

/// Minimal PNG encoder: one IDAT chunk of unfiltered 8-bit RGBA rows.
fn writePng(gpa: std.mem.Allocator, writer: *std.Io.Writer, width: u32, height: u32, rgba: []const u8) !void {
    var idat: std.Io.Writer.Allocating = try .initCapacity(gpa, rgba.len / 8 + 64);
    defer idat.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var zlib: std.compress.flate.Compress = try .init(&idat.writer, &window, .zlib, .fastest);
    for (0..height) |y| {
        try zlib.writer.writeByte(0); // filter type: none
        try zlib.writer.writeAll(rgba[y * width * 4 ..][0 .. width * 4]);
    }
    try zlib.finish();

    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], width, .big);
    std.mem.writeInt(u32, header[4..8], height, .big);
    header[8..13].* = .{ 8, 6, 0, 0, 0 }; // 8-bit, RGBA, deflate, no filter, no interlace

    try writer.writeAll("\x89PNG\r\n\x1a\n");
    for ([_]struct { []const u8, []const u8 }{
        .{ "IHDR", &header },
        .{ "IDAT", idat.written() },
        .{ "IEND", "" },
    }) |chunk| {
        const kind, const data = chunk;
        try writer.writeInt(u32, @intCast(data.len), .big);
        try writer.writeAll(kind);
        try writer.writeAll(data);
        var crc: std.hash.Crc32 = .init();
        crc.update(kind);
        crc.update(data);
        try writer.writeInt(u32, crc.final(), .big);
    }
}
