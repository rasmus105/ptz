//! Opens documents and images as pages rendered into RGBA tiles.
//! The viewer uses the same geometry and navigation for every format. A
//! document owns a file snapshot, unaffected by rewrites. Engine calls are
//! serialized, so documents may be used from any thread.

// std
const std = @import("std");

// local
const mupdf = @import("mupdf.zig");

// ====================================================================================================
// Constants
// ====================================================================================================

/// Larger files are refused rather than read into memory.
const file_size_max = 1024 * 1024 * 1024;

/// Page sizes stay within this range of points. Oversized rasters are
/// refused. Callers never compute with zero, negative,
/// huge or NaN sizes. 100000 pt is about 35 m.
pub const page_size_min = 1;
pub const page_size_max = 100_000;

// ====================================================================================================
// Types
// ====================================================================================================

pub const Error = error{
    FileNotFound,
    IsDir,
    AccessDenied,
    FileTooBig,
    InvalidFormat,
    PasswordRequired,
    UnsupportedSecurity,
    PageNotFound,
    OutOfMemory,
    Unexpected,
};

/// Page size in points (1/72 inch), within [`page_size_min`, `page_size_max`].
pub const Size = struct {
    width: f32,
    height: f32,
};

/// RGBA pixels, row-major with no padding between rows.
pub const Bitmap = struct {
    width: u32,
    height: u32,
    pixels: []u8,
};

/// Which part of a page to render: the page is scaled to `page_width` by
/// `page_height` pixels, and the bitmap receives the pixels starting at
/// (`x`, `y`). Rendering a page in tiles keeps each bitmap small at high zoom.
pub const View = struct {
    page_width: u32,
    page_height: u32,
    x: u32,
    y: u32,
};

pub const Document = struct {
    gpa: std.mem.Allocator,
    bytes: []const u8,
    backend: mupdf.Document,

    pub const OpenMode = enum { initial, replacement };

    pub fn open(io: std.Io, gpa: std.mem.Allocator, path: []const u8) Error!Document {
        return openSnapshot(io, gpa, path, .initial);
    }

    pub fn openSnapshot(io: std.Io, gpa: std.mem.Allocator, path: []const u8, mode: OpenMode) Error!Document {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(file_size_max)) catch |err| return switch (err) {
            error.FileNotFound => error.FileNotFound,
            error.IsDir => error.IsDir,
            error.AccessDenied, error.PermissionDenied => error.AccessDenied,
            error.StreamTooLong => error.FileTooBig,
            error.OutOfMemory => error.OutOfMemory,
            else => error.Unexpected,
        };
        errdefer gpa.free(bytes);

        const backend = try mupdf.Document.open(io, bytes, mode);
        return .{ .gpa = gpa, .bytes = bytes, .backend = backend };
    }

    pub fn close(doc: *Document) void {
        doc.backend.close();
        doc.gpa.free(doc.bytes);
        doc.* = undefined;
    }

    pub fn pageCount(doc: *const Document) u32 {
        return doc.backend.pageCount();
    }

    pub fn pageSize(doc: *const Document, page: u32) Error!Size {
        return doc.backend.pageSize(page);
    }

    /// Renders the selected region on white; pixels outside the page stay white.
    pub fn render(doc: *Document, page: u32, view: View, target: Bitmap) Error!void {
        std.debug.assert(view.page_width > 0);
        std.debug.assert(view.page_height > 0);
        std.debug.assert(target.pixels.len == @as(usize, target.width) * target.height * 4);
        try doc.backend.render(page, view, target);
    }
};

// ====================================================================================================
// Tests
// ====================================================================================================

fn testBitmap(gpa: std.mem.Allocator, width: u32, height: u32) !Bitmap {
    return .{ .width = width, .height = height, .pixels = try gpa.alloc(u8, @as(usize, width) * height * 4) };
}

fn pixel(bitmap: Bitmap, x: usize, y: usize) [4]u8 {
    return bitmap.pixels[(y * bitmap.width + x) * 4 ..][0..4].*;
}

test "renders a page in RGBA at the requested size" {
    const gpa = std.testing.allocator;
    var doc = try Document.open(std.testing.io, gpa, "src/document/testdata/red-square.pdf");
    defer doc.close();
    try std.testing.expectEqual(1, doc.pageCount());

    // 200x100 pt page with a red 40x40 pt square at (20, 20) from the bottom left.
    try std.testing.expectEqual(Size{ .width = 200, .height = 100 }, try doc.pageSize(0));

    const bitmap = try testBitmap(gpa, 400, 200);
    defer gpa.free(bitmap.pixels);
    const view: View = .{ .page_width = 400, .page_height = 200, .x = 0, .y = 0 };
    try doc.render(0, view, bitmap);
    // Square spans x 40..120 and y 80..160 (from the top) at 2x.
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, pixel(bitmap, 80, 120));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, pixel(bitmap, 300, 40));

    try std.testing.expectError(error.PageNotFound, doc.render(1, view, bitmap));
}

test "a tile matches the same region of the whole page" {
    const gpa = std.testing.allocator;
    var doc = try Document.open(std.testing.io, gpa, "src/document/testdata/red-square.pdf");
    defer doc.close();

    const whole = try testBitmap(gpa, 400, 200);
    defer gpa.free(whole.pixels);
    try doc.render(0, .{ .page_width = 400, .page_height = 200, .x = 0, .y = 0 }, whole);
    // A tile straddling the square's top left corner at (40, 80).
    const tile = try testBitmap(gpa, 64, 48);
    defer gpa.free(tile.pixels);
    try doc.render(0, .{ .page_width = 400, .page_height = 200, .x = 20, .y = 60 }, tile);

    for (0..tile.height) |y| {
        try std.testing.expectEqualSlices(
            u8,
            whole.pixels[((y + 60) * whole.width + 20) * 4 ..][0 .. tile.width * 4],
            tile.pixels[y * tile.width * 4 ..][0 .. tile.width * 4],
        );
    }
}

test "page sizes are clamped to a sane range" {
    const gpa = std.testing.allocator;
    var doc = try Document.open(std.testing.io, gpa, "src/document/testdata/odd-sizes.pdf");
    defer doc.close();
    for (0..doc.pageCount()) |page| {
        const size = try doc.pageSize(@intCast(page));
        for ([_]f32{ size.width, size.height }) |points| {
            try std.testing.expect(points >= page_size_min and points <= page_size_max);
        }
    }
}

test "open reports why a file cannot be loaded" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.FileNotFound, Document.open(std.testing.io, gpa, "src/document/testdata/missing.pdf"));
    try std.testing.expectError(error.InvalidFormat, Document.open(std.testing.io, gpa, "build.zig"));
}

test "images decode by content, composite alpha on white, and validate page indices" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "misnamed.pdf", .data = @embedFile("testdata/rgba.png") });
    const path = try tmp.dir.realPathFileAlloc(io, "misnamed.pdf", gpa);
    defer gpa.free(path);
    var doc = try Document.open(io, gpa, path);
    defer doc.close();
    try std.testing.expectEqual(1, doc.pageCount());
    try std.testing.expectEqual(Size{ .width = 1.5, .height = 1.5 }, try doc.pageSize(0));
    try std.testing.expectError(error.PageNotFound, doc.pageSize(1));
    const bitmap = try testBitmap(gpa, 2, 2);
    defer gpa.free(bitmap.pixels);
    const view: View = .{ .page_width = 2, .page_height = 2, .x = 0, .y = 0 };
    try doc.render(0, view, bitmap);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 255, 255, 255, 255, 127, 255, 127, 255, 0, 0, 0, 255 }, bitmap.pixels);
    try std.testing.expectError(error.PageNotFound, doc.render(1, view, bitmap));

    // Hidden blue in the transparent pixel must not bleed into its red neighbour.
    const scaled = try testBitmap(gpa, 4, 4);
    defer gpa.free(scaled.pixels);
    try doc.render(0, .{ .page_width = 4, .page_height = 4, .x = 0, .y = 0 }, scaled);
    const blended = pixel(scaled, 1, 0);
    try std.testing.expectEqual(@as(u8, 255), blended[0]);
    try std.testing.expect(blended[1] > 0 and blended[1] < 255);
    try std.testing.expectEqual(blended[1], blended[2]);
    try std.testing.expectEqual(@as(u8, 255), blended[3]);
}

test "image tiles match a whole render at fractional scales and outside the page" {
    const gpa = std.testing.allocator;
    var doc = try Document.open(std.testing.io, gpa, "src/document/testdata/rgba.png");
    defer doc.close();
    const whole = try testBitmap(gpa, 11, 9);
    defer gpa.free(whole.pixels);
    try doc.render(0, .{ .page_width = 7, .page_height = 5, .x = 0, .y = 0 }, whole);
    const tile = try testBitmap(gpa, 6, 5);
    defer gpa.free(tile.pixels);
    try doc.render(0, .{ .page_width = 7, .page_height = 5, .x = 4, .y = 3 }, tile);
    for (0..tile.height) |y| {
        try std.testing.expectEqualSlices(u8, whole.pixels[((y + 3) * whole.width + 4) * 4 ..][0 .. tile.width * 4], tile.pixels[y * tile.width * 4 ..][0 .. tile.width * 4]);
    }
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, pixel(tile, 5, 4));
    try doc.render(0, .{ .page_width = 7, .page_height = 5, .x = std.math.maxInt(u32), .y = std.math.maxInt(u32) }, tile);
    try std.testing.expect(std.mem.allEqual(u8, tile.pixels, 255));
}

test "common raster decoders render known colours and GIFs as a static image" {
    const gpa = std.testing.allocator;
    const bitmap = try testBitmap(gpa, 2, 2);
    defer gpa.free(bitmap.pixels);
    var bmp = try Document.open(std.testing.io, gpa, "src/document/testdata/colors.bmp");
    defer bmp.close();
    try bmp.render(0, .{ .page_width = 2, .page_height = 2, .x = 0, .y = 0 }, bitmap);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, pixel(bitmap, 0, 0));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, pixel(bitmap, 1, 0));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, pixel(bitmap, 1, 1));
    var gif = try Document.open(std.testing.io, gpa, "src/document/testdata/animated.gif");
    defer gif.close();
    try std.testing.expectEqual(@as(u32, 1), gif.pageCount());
    try gif.render(0, .{ .page_width = 2, .page_height = 2, .x = 0, .y = 0 }, bitmap);
    // The second GIF frame paints the canvas green; MuPDF composites it into
    // the static document rather than exposing animation frames as pages.
    try std.testing.expectEqualSlices(u8, &.{ 0, 128, 0, 255, 0, 128, 0, 255, 0, 128, 0, 255, 0, 128, 0, 255 }, bitmap.pixels);
    var jpeg = try Document.open(std.testing.io, gpa, "src/document/testdata/red-square.jpg");
    defer jpeg.close();
    try jpeg.render(0, .{ .page_width = 200, .page_height = 100, .x = 30, .y = 50 }, bitmap);
    const red = pixel(bitmap, 0, 0);
    try std.testing.expect(red[0] >= 250 and red[1] <= 5 and red[2] <= 5 and red[3] == 255);

    var gray = try Document.open(std.testing.io, gpa, "src/document/testdata/gray16.png");
    defer gray.close();
    try gray.render(0, .{ .page_width = 2, .page_height = 1, .x = 0, .y = 0 }, bitmap);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, pixel(bitmap, 0, 0));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, pixel(bitmap, 1, 0));
}

test "narrow images preserve their proportions and oversized images fail before decoding" {
    const gpa = std.testing.allocator;
    var doc = try Document.open(std.testing.io, gpa, "src/document/testdata/column.ppm");
    defer doc.close();
    try std.testing.expectEqual(Size{ .width = 1, .height = 3 }, try doc.pageSize(0));
    const bitmap = try testBitmap(gpa, 1, 3);
    defer gpa.free(bitmap.pixels);
    try doc.render(0, .{ .page_width = 1, .page_height = 3, .x = 0, .y = 0 }, bitmap);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255 }, bitmap.pixels);
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const header = "P6\n100001 1\n255\n";
    const bytes = try gpa.alloc(u8, header.len + 100001 * 3);
    defer gpa.free(bytes);
    @memcpy(bytes[0..header.len], header);
    @memset(bytes[header.len..], 0);
    try tmp.dir.writeFile(io, .{ .sub_path = "wide.ppm", .data = bytes });
    const path = try tmp.dir.realPathFileAlloc(io, "wide.ppm", gpa);
    defer gpa.free(path);
    try std.testing.expectError(error.FileTooBig, Document.open(io, gpa, path));

    // These declare oversized dimensions but contain no pixel data.
    try std.testing.expectError(error.InvalidFormat, Document.open(io, gpa, "src/document/testdata/too-wide.ppm"));
    try std.testing.expectError(error.InvalidFormat, Document.open(io, gpa, "src/document/testdata/too-many-pixels.ppm"));
}

test {
    _ = @import("test.zig");
}

test "unrepresentable render sizes fail without invalidating the document" {
    var doc = try Document.open(std.testing.io, std.testing.allocator, "src/document/testdata/ordered.cbz");
    defer doc.close();
    var pixels: [4]u8 = undefined;
    const target: Bitmap = .{ .width = 1, .height = 1, .pixels = &pixels };
    try std.testing.expectError(error.FileTooBig, doc.render(0, .{
        .page_width = std.math.maxInt(u32),
        .page_height = std.math.maxInt(u32),
        .x = 0,
        .y = 0,
    }, target));
    try doc.render(0, .{ .page_width = 1, .page_height = 1, .x = 0, .y = 0 }, target);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, pixels);
}
