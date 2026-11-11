//! Lets agents see what ptz shows without a real terminal: runs the viewer in
//! an emulated terminal, presses the given keys, then prints the screen's
//! text and writes a PNG of its images (text is not drawn into it).
//!
//!     zig build harness -- paper.pdf --keys '3G<C-d>++'

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

/// Ghostty logs every image placement at debug level.
pub const std_options: std.Options = .{ .log_level = .warn };

/// Key names usable in `--keys`, as `<Name>`.
const named_keys = [_]struct { []const u8, []const u8 }{
    .{ "CR", "\r" },       .{ "Esc", "\x1b" },    .{ "BS", "\x7f" },        .{ "Tab", "\t" },
    .{ "Up", "\x1b[A" },   .{ "Down", "\x1b[B" }, .{ "Right", "\x1b[C" },   .{ "Left", "\x1b[D" },
    .{ "Home", "\x1b[H" }, .{ "End", "\x1b[F" },  .{ "PageUp", "\x1b[5~" }, .{ "PageDown", "\x1b[6~" },
};

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
    const emulator: *Emulator = try .create(io, gpa, size);
    defer emulator.destroy();
    const viewer = try gpa.create(app.App);
    defer gpa.destroy(viewer);
    viewer.init(io, gpa, .{
        .path = options.file,
        .page = options.page,
        .dark = options.dark,
        .watch = false,
        .medium = .shared_memory,
    }, size, null);
    defer viewer.deinit();

    try viewer.settle(&emulator.output);
    var keys = options.keys;
    while (keys.len > 0 and viewer.open_error == null) {
        var bytes_buffer: [8]u8 = undefined;
        const bytes, const len = keyBytes(keys, &bytes_buffer) catch |err|
            std.process.fatal("bad key at '{s}': {t}", .{ keys, err });
        keys = keys[len..];
        if (viewer.input(bytes) == .quit) break;
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
    const file = try std.Io.Dir.cwd().createFile(io, options.out, .{});
    defer file.close(io);
    var file_buffer: [64 * 1024]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(file, io, &file_buffer);
    try writePng(gpa, &file_writer.interface, screenshot.width, screenshot.height, screenshot.pixels);
    try file_writer.interface.flush();

    try stdout.print("screenshot written to {s}\n", .{options.out});
    try stdout.flush();
}

// ====================================================================================================
// Private Functions
// ====================================================================================================

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
