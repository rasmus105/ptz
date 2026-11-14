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

// std
const std = @import("std");

// project
const app = @import("app/main.zig");
const Emulator = @import("emulator/main.zig").Emulator;
const terminal = @import("terminal/main.zig");

// local
const argparse = @import("argparse.zig");

// ====================================================================================================
// Constants
// ====================================================================================================

/// Ghostty logs every image placement at debug level, and commands it
/// rejects as warnings, which `--fuzz` counts as failures.
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
/// may be further: PDFium's resampling of embedded images varies slightly
/// with what it rendered before.
const fuzz_tolerance = 32;
const fuzz_outliers_max = 16;

/// Warnings Ghostty logged about image commands since the last fuzz check.
var terminal_warnings: u32 = 0;

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

    pub const positional = .{ .file = "PDF file to open" };
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
    if (options.fuzz > 0) return fuzz(io, gpa, app_options, size, options);

    const emulator: *Emulator = try .create(io, gpa, size);
    defer emulator.destroy();
    const viewer = try gpa.create(app.App);
    defer gpa.destroy(viewer);
    viewer.init(io, gpa, app_options, size, null);
    defer viewer.deinit();

    try viewer.settle(&emulator.output);
    var keys = options.keys;
    while (keys.len > 0 and viewer.open_error == null) {
        var bytes_buffer: [8]u8 = undefined;
        const bytes, const len = keyBytes(keys, &bytes_buffer) catch |err|
            std.process.fatal("bad key at '{s}': {t}", .{ keys, err });
        keys = keys[len..];
        if (viewer.input(bytes)) break;
        // Each harness key is complete, including a standalone Escape.
        if (viewer.escape_started) |started| viewer.expireInput(started.addDuration(.fromSeconds(1)));
        try viewer.settle(&emulator.output);
    }
    if (viewer.open_error) |err| std.process.fatal("cannot open '{s}': {t}", .{ options.file, err });

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
    if (scope == .kitty_gfx and level == .warn) terminal_warnings += 1;
    std.log.defaultLog(level, scope, format, args);
}

fn fuzz(io: std.Io, gpa: std.mem.Allocator, app_options: app.Options, start_size: terminal.Size, options: Options) !void {
    var prng: std.Random.DefaultPrng = .init(options.seed);
    const random = prng.random();
    // The events so far, to report with a failure.
    var events: std.Io.Writer.Allocating = .init(gpa);
    defer events.deinit();

    const emulator: *Emulator = try .create(io, gpa, start_size);
    defer emulator.destroy();
    const viewer = try gpa.create(app.App);
    defer gpa.destroy(viewer);
    viewer.init(io, gpa, app_options, start_size, null);
    defer viewer.deinit();
    try viewer.settle(&emulator.output);
    if (viewer.open_error) |err| std.process.fatal("cannot open '{s}': {t}", .{ options.file, err });

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
            }
        }
        // A busy render thread finishes a few results at most between keys.
        for (0..random.uintAtMost(u32, 3)) |_| {
            _ = viewer.renderer.step();
            viewer.collect();
            if (random.boolean()) try viewer.draw(&emulator.output);
        }
        if (viewer.dirty) try viewer.draw(&emulator.output);

        const check = (event_index + 1) % fuzz_check_interval == 0 or event_index + 1 == options.fuzz;
        if (terminal_warnings > 0 or check) {
            try viewer.settle(&emulator.output);
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
    if (terminal_warnings > 0) return error.TerminalRejectedCommands;
    const screen = try emulator.screenshot(gpa);
    defer gpa.free(screen.pixels);
    errdefer saveScreenshot(io, gpa, screen, "zig-out/fuzz-actual.png") catch {};

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
    if (uncovered > 0) {
        std.debug.print("{d} page pixels not covered by any image\n", .{uncovered});
        return error.Uncovered;
    }

    const fresh_emulator: *Emulator = try .create(io, gpa, state.size);
    defer fresh_emulator.destroy();
    const fresh = try gpa.create(app.App);
    defer gpa.destroy(fresh);
    fresh.init(io, gpa, app_options, state.size, null);
    defer fresh.deinit();
    try fresh.settle(&fresh_emulator.output);
    const document = fresh.state.document;
    fresh.state = state.*;
    fresh.state.document = document;
    // Recomputes the geometry for the fresh document.
    fresh.resize(state.size);
    try fresh.settle(&fresh_emulator.output);
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
