//! Lets agents see what ptz draws without a real terminal: shows a page the
//! way ptz would, but in an emulated terminal, then prints the screen's text
//! and writes a PNG of the screen (images only; text is not drawn).
//!
//!     zig build harness -- paper.pdf --page 2

// std
const std = @import("std");

// project
const Emulator = @import("emulator/main.zig").Emulator;
const pdf = @import("pdf/main.zig");
const terminal = @import("terminal/main.zig");
const viewer = @import("viewer/main.zig");

// local
const argparse = @import("argparse.zig");

// ====================================================================================================
// Constants
// ====================================================================================================

/// Ghostty logs every image placement at debug level.
pub const std_options: std.Options = .{ .log_level = .warn };

// ====================================================================================================
// Types
// ====================================================================================================

const Options = struct {
    file: []const u8,
    page: u32 = 1,
    cols: u16 = 100,
    rows: u16 = 30,
    cell_width: u16 = 10,
    cell_height: u16 = 20,
    out: []const u8 = "zig-out/screen.png",

    pub const positional = .{ .file = "PDF file to open" };
    pub const shorts = .{ .page = 'p', .out = 'o' };
    pub const help = .{
        .page = "Page to show",
        .cols = "Terminal width in cells",
        .rows = "Terminal height in cells",
        .cell_width = "Cell width in pixels",
        .cell_height = "Cell height in pixels",
        .out = "Where to write the screenshot",
    };
};

const Cli = argparse.Cli(Options, .{
    .name = "harness",
    .summary = "Show a page in an emulated terminal and capture the screen",
    .version = "dev",
});

// ====================================================================================================
// Public API
// ====================================================================================================

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const options = try Cli.parse(init);

    const path = try init.arena.allocator().dupeSentinel(u8, options.file, 0);
    const doc = pdf.Document.open(io, path, null) catch |err|
        std.process.fatal("cannot open '{s}': {t}", .{ options.file, err });
    defer doc.close();
    if (options.page == 0 or options.page > doc.pageCount())
        std.process.fatal("page {d} is out of range", .{options.page});

    const size: terminal.Size = .{
        .cols = options.cols,
        .rows = options.rows,
        .cell_width = options.cell_width,
        .cell_height = options.cell_height,
    };
    const emulator: *Emulator = try .create(io, gpa, size);
    defer emulator.destroy();
    try viewer.showPage(gpa, &emulator.output, doc, options.page - 1, size);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    const text = try emulator.text(gpa);
    defer gpa.free(text);
    try stdout.print("{s}\n", .{text});

    // Composite the images onto a dark background at their cells.
    const width = @as(u32, size.cols) * size.cell_width;
    const height = @as(u32, size.rows) * size.cell_height;
    const screen = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(screen);
    for (0..screen.len / 4) |i| screen[i * 4 ..][0..4].* = .{ 32, 32, 32, 255 };
    const images = try emulator.images(gpa);
    defer gpa.free(images);
    for (images) |image| {
        const left = image.col * size.cell_width;
        const top = image.row * size.cell_height;
        for (0..@min(image.height, height -| top)) |y| {
            const columns = @min(image.width, width -| left);
            const src = image.pixels[y * image.width * 4 ..][0 .. columns * 4];
            @memcpy(screen[((top + y) * width + left) * 4 ..][0 .. columns * 4], src);
        }
    }

    const file = try std.Io.Dir.cwd().createFile(io, options.out, .{});
    defer file.close(io);
    var file_buffer: [64 * 1024]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(file, io, &file_buffer);
    try writePng(gpa, &file_writer.interface, width, height, screen);
    try file_writer.interface.flush();

    try stdout.print("{d} image(s); screenshot written to {s}\n", .{ images.len, options.out });
    try stdout.flush();
}

// ====================================================================================================
// Private Functions
// ====================================================================================================

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
