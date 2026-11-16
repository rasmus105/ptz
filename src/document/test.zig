// std
const std = @import("std");

// local
const document = @import("main.zig");

// ====================================================================================================
// Private Functions
// ====================================================================================================

fn bitmap(width: u32, height: u32) !document.Bitmap {
    return .{ .width = width, .height = height, .pixels = try std.testing.allocator.alloc(u8, @as(usize, width) * height * 4) };
}

fn pixel(target: document.Bitmap, x: usize, y: usize) [4]u8 {
    return target.pixels[(y * target.width + x) * 4 ..][0..4].*;
}

// ====================================================================================================
// Tests
// ====================================================================================================

test "SVG maps an offset viewBox to its viewport and composites transparency" {
    var doc = try document.Document.open(std.testing.io, std.testing.allocator, "src/document/testdata/viewbox.svg");
    defer doc.close();
    try std.testing.expectEqual(document.Size{ .width = 200, .height = 100 }, try doc.pageSize(0));
    const target = try bitmap(200, 100);
    defer std.testing.allocator.free(target.pixels);
    try doc.render(0, .{ .page_width = 200, .page_height = 100, .x = 0, .y = 0 }, target);
    // The viewBox starts at (10, 20), so the red rect at (30, 40) starts at (20, 20).
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, pixel(target, 40, 40));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, pixel(target, 10, 10));
    const green = pixel(target, 100, 40);
    try std.testing.expect(green[0] >= 126 and green[0] <= 128);
    try std.testing.expectEqual(@as(u8, 255), green[1]);
    try std.testing.expectEqual(green[0], green[2]);
    try std.testing.expectEqual(@as(u8, 255), green[3]);
}

test "PDF cropping rotation and user units preserve page coordinates" {
    var doc = try document.Document.open(std.testing.io, std.testing.allocator, "src/document/testdata/crop-rotation.pdf");
    defer doc.close();
    try std.testing.expectEqual(@as(u32, 3), doc.pageCount());
    const cases = [_]struct { size: document.Size, x: u32, y: u32 }{
        .{ .size = .{ .width = 160, .height = 80 }, .x = 40, .y = 50 },
        .{ .size = .{ .width = 80, .height = 160 }, .x = 30, .y = 40 },
        .{ .size = .{ .width = 320, .height = 160 }, .x = 80, .y = 100 },
    };
    for (cases, 0..) |case, index| {
        const page: u32 = @intCast(index);
        try std.testing.expectEqual(case.size, try doc.pageSize(page));
        const target = try bitmap(@intFromFloat(case.size.width), @intFromFloat(case.size.height));
        defer std.testing.allocator.free(target.pixels);
        try doc.render(page, .{ .page_width = target.width, .page_height = target.height, .x = 0, .y = 0 }, target);
        try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, pixel(target, case.x, case.y));
        try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, pixel(target, 5, 5));
    }
}

test "CBZ reads pages in natural filename order rather than ZIP entry order" {
    var doc = try document.Document.open(std.testing.io, std.testing.allocator, "src/document/testdata/ordered.cbz");
    defer doc.close();
    try std.testing.expectEqual(@as(u32, 3), doc.pageCount());
    const target = try bitmap(80, 40);
    defer std.testing.allocator.free(target.pixels);
    for ([_][4]u8{ .{ 255, 0, 0, 255 }, .{ 0, 255, 0, 255 }, .{ 0, 0, 255, 255 } }, 0..) |color, index| {
        try doc.render(@intCast(index), .{ .page_width = 80, .page_height = 40, .x = 0, .y = 0 }, target);
        try std.testing.expectEqual(color, pixel(target, 40, 20));
    }
    try std.testing.expectError(error.PageNotFound, doc.pageSize(3));
}

test "XPS follows the document page list and applies canvas translations" {
    var doc = try document.Document.open(std.testing.io, std.testing.allocator, "src/document/testdata/two-pages.xps");
    defer doc.close();
    try std.testing.expectEqual(@as(u32, 2), doc.pageCount());
    // XPS units are 1/96 inch; the public geometry is in 1/72 inch points.
    try std.testing.expectEqual(document.Size{ .width = 192, .height = 96 }, try doc.pageSize(0));
    try std.testing.expectEqual(document.Size{ .width = 96, .height = 192 }, try doc.pageSize(1));
    const first = try bitmap(192, 96);
    defer std.testing.allocator.free(first.pixels);
    try doc.render(0, .{ .page_width = 192, .page_height = 96, .x = 0, .y = 0 }, first);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, pixel(first, 48, 24));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, pixel(first, 10, 10));
    const second = try bitmap(96, 192);
    defer std.testing.allocator.free(second.pixels);
    try doc.render(1, .{ .page_width = 96, .page_height = 192, .x = 0, .y = 0 }, second);
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, pixel(second, 48, 96));
}

test "TIFF exposes independent image directories as pages" {
    var doc = try document.Document.open(std.testing.io, std.testing.allocator, "src/document/testdata/two-pages.tiff");
    defer doc.close();
    try std.testing.expectEqual(@as(u32, 2), doc.pageCount());
    const target = try bitmap(2, 1);
    defer std.testing.allocator.free(target.pixels);
    for ([_][4]u8{ .{ 255, 0, 0, 255 }, .{ 0, 0, 255, 255 } }, 0..) |color, index| {
        const page: u32 = @intCast(index);
        try std.testing.expectEqual(document.Size{ .width = 2, .height = 1 }, try doc.pageSize(page));
        try doc.render(page, .{ .page_width = 2, .page_height = 1, .x = 0, .y = 0 }, target);
        try std.testing.expectEqual(color, pixel(target, 0, 0));
        try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, pixel(target, 1, 0));
    }
    try std.testing.expectError(error.PageNotFound, doc.pageSize(2));
}

test "JPEG orientation changes both page proportions and rendered content" {
    var doc = try document.Document.open(std.testing.io, std.testing.allocator, "src/document/testdata/rotated.jpg");
    defer doc.close();
    const size = try doc.pageSize(0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), size.width / size.height, 0.001);
    const target = try bitmap(100, 200);
    defer std.testing.allocator.free(target.pixels);
    try doc.render(0, .{ .page_width = 100, .page_height = 200, .x = 0, .y = 0 }, target);
    const red = pixel(target, 40, 40);
    try std.testing.expect(red[0] >= 250 and red[1] <= 5 and red[2] <= 5 and red[3] == 255);
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, pixel(target, 90, 180));
}

test "EPUB chapters stay in spine order with stable pagination at different render sizes" {
    var doc = try document.Document.open(std.testing.io, std.testing.allocator, "src/document/testdata/chapters.epub");
    defer doc.close();
    try std.testing.expectEqual(@as(u32, 3), doc.pageCount());
    const size = try doc.pageSize(0);
    const target = try bitmap(612, 792);
    defer std.testing.allocator.free(target.pixels);
    for ([_][4]u8{ .{ 255, 0, 0, 255 }, .{ 0, 255, 0, 255 }, .{ 0, 0, 255, 255 } }, 0..) |color, index| {
        const page: u32 = @intCast(index);
        try doc.render(page, .{ .page_width = 612, .page_height = 792, .x = 0, .y = 0 }, target);
        var colored_pixels: usize = 0;
        var offset: usize = 0;
        while (offset < target.pixels.len) : (offset += 4) {
            if (std.mem.eql(u8, &color, target.pixels[offset..][0..4])) colored_pixels += 1;
        }
        try std.testing.expect(colored_pixels > 1000);
        try doc.render(page, .{ .page_width = 311, .page_height = 237, .x = 0, .y = 0 }, target);
        try std.testing.expectEqual(@as(u32, 3), doc.pageCount());
        try std.testing.expectEqual(size, try doc.pageSize(page));
    }
    var flow = try document.Document.open(std.testing.io, std.testing.allocator, "src/document/testdata/flow.epub");
    defer flow.close();
    const pages = flow.pageCount();
    try std.testing.expect(pages > 3);
    try flow.render(pages - 1, .{ .page_width = 901, .page_height = 681, .x = 0, .y = 0 }, target);
    try std.testing.expectEqual(pages, flow.pageCount());
    try std.testing.expectError(error.PageNotFound, flow.pageSize(pages));
}

test "document recognition uses content for mislabeled archives and vector files" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "misnamed.pdf", .data = "" });
    const filename = try tmp.dir.realPathFileAlloc(io, "misnamed.pdf", gpa);
    defer gpa.free(filename);
    const cases = [_]struct { bytes: []const u8, pages: u32 }{
        .{ .bytes = @embedFile("testdata/ordered.cbz"), .pages = 3 },
        .{ .bytes = @embedFile("testdata/chapters.epub"), .pages = 3 },
        .{ .bytes = @embedFile("testdata/two-pages.xps"), .pages = 2 },
        .{ .bytes = @embedFile("testdata/viewbox.svg"), .pages = 1 },
        .{ .bytes = @embedFile("testdata/two-pages.tiff"), .pages = 2 },
    };
    for (cases) |case| {
        try tmp.dir.writeFile(io, .{ .sub_path = "misnamed.pdf", .data = case.bytes });
        var doc = try document.Document.open(io, gpa, filename);
        defer doc.close();
        try std.testing.expectEqual(case.pages, doc.pageCount());
        const size = try doc.pageSize(0);
        try std.testing.expect(size.width > 0 and size.height > 0);
    }
}

test "fractional tiles match complete renders across document formats and page edges" {
    const gpa = std.testing.allocator;
    const whole = try bitmap(127, 113);
    defer gpa.free(whole.pixels);
    const tile = try bitmap(43, 41);
    defer gpa.free(tile.pixels);
    const names = [_][]const u8{
        "crop-rotation.pdf", "ordered.cbz",    "two-pages.xps", "viewbox.svg",
        "chapters.epub",     "two-pages.tiff", "rotated.jpg",   "rgba.png",
    };
    for (names) |name| {
        const path = try std.fmt.allocPrint(gpa, "src/document/testdata/{s}", .{name});
        defer gpa.free(path);
        var doc = try document.Document.open(std.testing.io, gpa, path);
        defer doc.close();
        for (0..doc.pageCount()) |index| {
            const page: u32 = @intCast(index);
            try doc.render(page, .{ .page_width = 101, .page_height = 79, .x = 0, .y = 0 }, whole);
            for ([_][2]u32{ .{ 11, 9 }, .{ 79, 61 } }) |origin| {
                errdefer std.debug.print("tile mismatch: {s}, page {d}, origin ({d}, {d})\n", .{ name, page, origin[0], origin[1] });
                try doc.render(page, .{ .page_width = 101, .page_height = 79, .x = origin[0], .y = origin[1] }, tile);
                for (0..tile.height) |y| {
                    try std.testing.expectEqualSlices(u8, whole.pixels[((y + origin[1]) * whole.width + origin[0]) * 4 ..][0 .. tile.width * 4], tile.pixels[y * tile.width * 4 ..][0 .. tile.width * 4]);
                }
            }
            try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, pixel(tile, 42, 40));
            try doc.render(page, .{ .page_width = 101, .page_height = 79, .x = std.math.maxInt(u32), .y = std.math.maxInt(u32) }, tile);
            try std.testing.expect(std.mem.allEqual(u8, tile.pixels, 255));
        }
    }
}

test "password protected documents report authentication separately from format errors" {
    try std.testing.expectError(error.PasswordRequired, document.Document.open(std.testing.io, std.testing.allocator, "src/document/testdata/password.pdf"));
}

test "additional image decoders handle PSD planar channels PAM alpha and ASCII PNM samples" {
    const target = try bitmap(2, 1);
    defer std.testing.allocator.free(target.pixels);
    for ([_][]const u8{ "src/document/testdata/colors.psd", "src/document/testdata/rgba.pam" }) |path| {
        var doc = try document.Document.open(std.testing.io, std.testing.allocator, path);
        defer doc.close();
        try doc.render(0, .{ .page_width = 2, .page_height = 1, .x = 0, .y = 0 }, target);
        try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, pixel(target, 0, 0));
        try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, pixel(target, 1, 0));
    }
    var gray = try document.Document.open(std.testing.io, std.testing.allocator, "src/document/testdata/gray.pgm");
    defer gray.close();
    try gray.render(0, .{ .page_width = 2, .page_height = 1, .x = 0, .y = 0 }, target);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, pixel(target, 0, 0));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, pixel(target, 1, 0));
}

test "concatenated PNM images have independent page contents" {
    var doc = try document.Document.open(std.testing.io, std.testing.allocator, "src/document/testdata/two-pages.pnm");
    defer doc.close();
    try std.testing.expectEqual(@as(u32, 2), doc.pageCount());
    const target = try bitmap(2, 1);
    defer std.testing.allocator.free(target.pixels);
    for ([_][4]u8{ .{ 255, 0, 0, 255 }, .{ 0, 0, 255, 255 } }, 0..) |color, index| {
        try doc.render(@intCast(index), .{ .page_width = 2, .page_height = 1, .x = 0, .y = 0 }, target);
        try std.testing.expectEqual(color, pixel(target, 0, 0));
        try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, pixel(target, 1, 0));
    }
}

test "an unreadable CBZ page returns an error without poisoning valid cached pages" {
    var doc = try document.Document.open(std.testing.io, std.testing.allocator, "src/document/testdata/broken-page.cbz");
    defer doc.close();
    try std.testing.expectEqual(@as(u32, 2), doc.pageCount());
    const target = try bitmap(8, 4);
    defer std.testing.allocator.free(target.pixels);
    const view: document.View = .{ .page_width = 8, .page_height = 4, .x = 0, .y = 0 };
    try doc.render(0, view, target);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, pixel(target, 4, 2));
    try std.testing.expectError(error.InvalidFormat, doc.render(1, view, target));
    try doc.render(0, view, target);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, pixel(target, 4, 2));
}

test "an open document retains lazy archive pages after its source is rewritten and removed" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "snapshot.cbz", .data = @embedFile("testdata/ordered.cbz") });
    const path = try tmp.dir.realPathFileAlloc(io, "snapshot.cbz", gpa);
    defer gpa.free(path);
    var original = try document.Document.open(io, gpa, path);
    defer original.close();
    try tmp.dir.writeFile(io, .{ .sub_path = "snapshot.cbz", .data = @embedFile("testdata/viewbox.svg") });
    var replacement = try document.Document.open(io, gpa, path);
    defer replacement.close();
    try std.testing.expectEqual(@as(u32, 1), replacement.pageCount());
    try tmp.dir.deleteFile(io, "snapshot.cbz");
    try std.testing.expectError(error.FileNotFound, document.Document.open(io, gpa, path));

    try std.testing.expectEqual(@as(u32, 3), original.pageCount());
    const target = try bitmap(8, 4);
    defer gpa.free(target.pixels);
    // Page two was never loaded while the archive existed on disk.
    try original.render(2, .{ .page_width = 8, .page_height = 4, .x = 0, .y = 0 }, target);
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, pixel(target, 4, 2));
    try std.testing.expectEqual(document.Size{ .width = 200, .height = 100 }, try replacement.pageSize(0));
}

test "revisiting an EPUB page after many other pages produces identical content" {
    const gpa = std.testing.allocator;
    var doc = try document.Document.open(std.testing.io, gpa, "src/document/testdata/flow.epub");
    defer doc.close();
    try std.testing.expect(doc.pageCount() > 6);
    const original = try bitmap(450, 600);
    defer gpa.free(original.pixels);
    const current = try bitmap(450, 600);
    defer gpa.free(current.pixels);
    const view: document.View = .{ .page_width = 450, .page_height = 600, .x = 0, .y = 0 };
    try doc.render(0, view, original);
    for (1..doc.pageCount()) |page| try doc.render(@intCast(page), view, current);
    try doc.render(0, view, current);
    try std.testing.expectEqualSlices(u8, original.pixels, current.pixels);
}

test "SVG BOM and prefixed PDF content survive misleading filenames" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "content.bin", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(io, "content.bin", gpa);
    defer gpa.free(path);
    const cases = [_]struct { bytes: []const u8, size: document.Size, x: u32, y: u32 }{
        .{ .bytes = "\xef\xbb\xbf" ++ @embedFile("testdata/viewbox.svg"), .size = .{ .width = 200, .height = 100 }, .x = 40, .y = 40 },
        .{ .bytes = "arbitrary leading data\n" ++ @embedFile("testdata/red-square.pdf"), .size = .{ .width = 200, .height = 100 }, .x = 40, .y = 60 },
    };
    const target = try bitmap(200, 100);
    defer gpa.free(target.pixels);
    for (cases) |case| {
        try tmp.dir.writeFile(io, .{ .sub_path = "content.bin", .data = case.bytes });
        var doc = try document.Document.open(io, gpa, path);
        defer doc.close();
        try std.testing.expectEqual(case.size, try doc.pageSize(0));
        try doc.render(0, .{ .page_width = 200, .page_height = 100, .x = 0, .y = 0 }, target);
        try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, pixel(target, case.x, case.y));
    }
}

test "image tiles keep the same interpolation phase at high zoom" {
    const gpa = std.testing.allocator;
    var doc = try document.Document.open(std.testing.io, gpa, "src/document/testdata/two-pages.tiff");
    defer doc.close();
    // A narrow strip keeps the reference small while exercising a distant
    // tile origin across the red-to-white transition of a two-pixel image.
    const strip = try bitmap(10_000, 80);
    defer gpa.free(strip.pixels);
    const tile = try bitmap(64, 40);
    defer gpa.free(tile.pixels);
    try doc.render(0, .{ .page_width = 10_000, .page_height = 5_000, .x = 0, .y = 0 }, strip);
    try doc.render(0, .{ .page_width = 10_000, .page_height = 5_000, .x = 5_000, .y = 20 }, tile);
    for (0..tile.height) |y| {
        try std.testing.expectEqualSlices(u8, strip.pixels[((y + 20) * strip.width + 5_000) * 4 ..][0 .. tile.width * 4], tile.pixels[y * tile.width * 4 ..][0 .. tile.width * 4]);
    }
}

test "single-column images retain vertical colour order when enlarged" {
    var doc = try document.Document.open(std.testing.io, std.testing.allocator, "src/document/testdata/column.ppm");
    defer doc.close();
    const target = try bitmap(100, 300);
    defer std.testing.allocator.free(target.pixels);
    try doc.render(0, .{ .page_width = 100, .page_height = 300, .x = 0, .y = 0 }, target);
    const red = pixel(target, 50, 25);
    const green = pixel(target, 50, 150);
    const blue = pixel(target, 50, 275);
    try std.testing.expect(red[0] >= 250 and red[1] <= 5 and red[2] <= 5);
    try std.testing.expect(green[0] <= 5 and green[1] >= 250 and green[2] <= 5);
    try std.testing.expect(blue[0] <= 5 and blue[1] <= 5 and blue[2] >= 250);
}

test "optional invalid ICC metadata does not prevent complete image pixels from rendering" {
    const gpa = std.testing.allocator;
    const target = try bitmap(2, 2);
    defer gpa.free(target.pixels);
    var reference = try document.Document.open(std.testing.io, gpa, "src/document/testdata/rgba.png");
    defer reference.close();
    const original = try bitmap(2, 2);
    defer gpa.free(original.pixels);
    const view: document.View = .{ .page_width = 2, .page_height = 2, .x = 0, .y = 0 };
    try reference.render(0, view, original);
    for ([_][]const u8{ "invalid-icc.png", "long-icc.png" }) |name| {
        const path = try std.fmt.allocPrint(gpa, "src/document/testdata/{s}", .{name});
        defer gpa.free(path);
        var doc = try document.Document.open(std.testing.io, gpa, path);
        defer doc.close();
        try doc.render(0, view, target);
        try std.testing.expectEqualSlices(u8, original.pixels, target.pixels);
    }
}

test "embedded SVG crops preserve their scale and offset at high zoom" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const path = "src/document/testdata/embedded-svg.epub";
    var reference = try document.Document.open(io, gpa, path);
    defer reference.close();
    const size = try reference.pageSize(0);
    const width = 3073;
    const height: u32 = @intFromFloat(@round(width * size.height / size.width));
    const whole = try bitmap(width, height);
    defer gpa.free(whole.pixels);
    try reference.render(0, .{ .page_width = width, .page_height = height, .x = 0, .y = 0 }, whole);

    const crop = try bitmap(257, 113);
    defer gpa.free(crop.pixels);
    for ([_][2]u32{ .{ 337, 511 }, .{ 1907, 337 }, .{ 2041, 1021 } }) |origin| {
        var fresh = try document.Document.open(io, gpa, path);
        defer fresh.close();
        try fresh.render(0, .{ .page_width = width, .page_height = height, .x = origin[0], .y = origin[1] }, crop);
        for (0..crop.height) |y| {
            const offset = ((y + origin[1]) * whole.width + origin[0]) * 4;
            try std.testing.expectEqualSlices(u8, whole.pixels[offset..][0 .. crop.width * 4], crop.pixels[y * crop.width * 4 ..][0 .. crop.width * 4]);
        }
    }
}

extern fn ptz_test_rotated_scalable_crop() c_int;

test "rotated scalable crops stay within a small allocation limit" {
    try std.testing.expectEqual(@as(c_int, 0), ptz_test_rotated_scalable_crop());
}
