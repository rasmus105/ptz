//! Shows PDF pages in the terminal.

// std
const std = @import("std");

// project
const graphics = @import("../graphics/main.zig");
const pdf = @import("../pdf/main.zig");
const terminal = @import("../terminal/main.zig");

// ====================================================================================================
// Public API
// ====================================================================================================

/// Draws `page` at the cursor, scaled to fit a terminal of `size` while
/// keeping its aspect ratio, and leaves the cursor on the row below it. The
/// last row is kept free, so the page fits above the prompt.
pub fn showPage(
    gpa: std.mem.Allocator,
    output: *std.Io.Writer,
    doc: pdf.Document,
    page: u32,
    size: terminal.Size,
) !void {
    const page_size = try doc.pageSize(page);
    const max_width: f32 = @floatFromInt(@as(u32, size.cols) * size.cell_width);
    const max_height: f32 = @floatFromInt(@as(u32, size.rows -| 1) * size.cell_height);
    const scale = @min(max_width / page_size.width, max_height / page_size.height);
    const bitmap = try pdf.Bitmap.alloc(
        gpa,
        @max(1, @as(u32, @intFromFloat(page_size.width * scale))),
        @max(1, @as(u32, @intFromFloat(page_size.height * scale))),
    );
    defer bitmap.free(gpa);
    try doc.render(page, bitmap);

    try graphics.draw(gpa, output, .{ .width = bitmap.width, .height = bitmap.height, .pixels = bitmap.pixels });
    // Move to the first row below the image. CR LF explicitly, since a
    // terminal only gets a bare LF if the tty doesn't translate it.
    const image_rows = std.math.divCeil(u32, bitmap.height, size.cell_height) catch unreachable;
    try output.splatBytesAll("\r\n", image_rows);
    try output.flush();
}

// ====================================================================================================
// Tests
// ====================================================================================================

const Emulator = @import("../emulator/main.zig").Emulator;

test "page is fitted to the terminal and drawn at the cursor" {
    const gpa = std.testing.allocator;
    const doc = try pdf.Document.open(std.testing.io, "src/pdf/testdata/red-square.pdf", null);
    defer doc.close();

    // 40x11 cells of 10x20 px: 400x200 px above the prompt row, so the
    // 200x100 pt page renders at 2x.
    const size: terminal.Size = .{ .cols = 40, .rows = 11, .cell_width = 10, .cell_height = 20 };
    const emulator: *Emulator = try .create(std.testing.io, gpa, size);
    defer emulator.destroy();
    try showPage(gpa, &emulator.output, doc, 0, size);

    const images = try emulator.images(gpa);
    defer gpa.free(images);
    try std.testing.expectEqual(1, images.len);
    const image = images[0];
    // Still at the top: the page spans the full width, which must not make
    // the cursor movement after it scroll the screen.
    try std.testing.expectEqual(.{ 0, 0 }, .{ image.col, image.row });
    try std.testing.expectEqual(.{ 400, 200 }, .{ image.width, image.height });
    // Inside the red square, and in the white margin.
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, image.pixel(80, 120));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, image.pixel(300, 40));
}
