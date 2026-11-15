//! A raster is a single page. Decode once, then sample tiles using page
//! coordinates so zooming and panning never introduce seams between tiles.

// std
const std = @import("std");

// local
const document = @import("main.zig");

// ====================================================================================================
// Types
// ====================================================================================================

pub const Image = struct {
    gpa: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn open(gpa: std.mem.Allocator, bytes: []const u8) document.Error!Image {
        var width: c_int = undefined;
        var height: c_int = undefined;
        var decoded: [*]u8 = undefined;
        switch (ptz_image_load(bytes.ptr, @intCast(bytes.len), 512 * 1024 * 1024, &width, &height, &decoded)) {
            0 => {},
            2 => return error.FileTooBig,
            3 => return error.OutOfMemory,
            else => return error.InvalidFormat,
        }
        defer ptz_image_free(decoded);
        const pixels = try gpa.dupe(u8, decoded[0 .. @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4]);
        // Compositing before interpolation is equivalent to interpolating
        // premultiplied colour over white, and avoids transparent colour fringes.
        var index: usize = 0;
        while (index < pixels.len) : (index += 4) {
            const alpha: u32 = pixels[index + 3];
            for (pixels[index..][0..3]) |*channel| {
                channel.* = @intCast((@as(u32, channel.*) * alpha + 255 * (255 - alpha) + 127) / 255);
            }
            pixels[index + 3] = 255;
        }
        return .{ .gpa = gpa, .width = @intCast(width), .height = @intCast(height), .pixels = pixels };
    }

    pub fn close(image: *Image) void {
        image.gpa.free(image.pixels);
        image.* = undefined;
    }

    pub fn size(image: *const Image) document.Size {
        // One image pixel is one point; the viewer still fits it to the window.
        return .{ .width = @floatFromInt(image.width), .height = @floatFromInt(image.height) };
    }

    pub fn render(image: *const Image, view: document.View, target: document.Bitmap) void {
        @memset(target.pixels, 255);
        const width = @min(target.width, view.page_width -| view.x);
        const height = @min(target.height, view.page_height -| view.y);
        for (0..height) |y| {
            const source_y = std.math.clamp((@as(f64, @floatFromInt(@as(u64, view.y) + y)) + 0.5) *
                @as(f64, @floatFromInt(image.height)) / @as(f64, @floatFromInt(view.page_height)) - 0.5, 0, @as(f64, @floatFromInt(image.height - 1)));
            const y0: usize = @intFromFloat(source_y);
            const y1 = @min(y0 + 1, image.height - 1);
            const fy = source_y - @as(f64, @floatFromInt(y0));
            for (0..width) |x| {
                const source_x = std.math.clamp((@as(f64, @floatFromInt(@as(u64, view.x) + x)) + 0.5) *
                    @as(f64, @floatFromInt(image.width)) / @as(f64, @floatFromInt(view.page_width)) - 0.5, 0, @as(f64, @floatFromInt(image.width - 1)));
                const x0: usize = @intFromFloat(source_x);
                const x1 = @min(x0 + 1, image.width - 1);
                const fx = source_x - @as(f64, @floatFromInt(x0));
                const a = image.pixels[(y0 * image.width + x0) * 4 ..][0..3];
                const b = image.pixels[(y0 * image.width + x1) * 4 ..][0..3];
                const c = image.pixels[(y1 * image.width + x0) * 4 ..][0..3];
                const d = image.pixels[(y1 * image.width + x1) * 4 ..][0..3];
                for (target.pixels[(y * target.width + x) * 4 ..][0..3], 0..) |*channel, i| {
                    const top = @as(f64, @floatFromInt(a[i])) * (1 - fx) + @as(f64, @floatFromInt(b[i])) * fx;
                    const bottom = @as(f64, @floatFromInt(c[i])) * (1 - fx) + @as(f64, @floatFromInt(d[i])) * fx;
                    channel.* = @intFromFloat(@round(top * (1 - fy) + bottom * fy));
                }
            }
        }
    }
};

// ====================================================================================================
// Private Functions
// ====================================================================================================

extern fn ptz_image_load(bytes: [*]const u8, length: c_int, budget: usize, width: *c_int, height: *c_int, pixels: *[*]u8) c_int;
extern fn ptz_image_free(pixels: [*]u8) void;

// ====================================================================================================
// Tests
// ====================================================================================================

test "PNG inflation obeys the allocation budget even with tiny declared dimensions" {
    const bytes = @embedFile("testdata/inflated.png");
    var width: c_int = undefined;
    var height: c_int = undefined;
    var decoded: [*]u8 = undefined;
    const status = ptz_image_load(bytes.ptr, bytes.len, 64 * 1024, &width, &height, &decoded);
    if (status == 0) ptz_image_free(decoded);
    try std.testing.expectEqual(@as(c_int, 3), status);
    // A failed decode must leave the next call able to allocate and decode.
    var image = try Image.open(std.testing.allocator, @embedFile("testdata/rgba.png"));
    defer image.close();
    try std.testing.expectEqual(@as(u32, 2), image.width);
}
