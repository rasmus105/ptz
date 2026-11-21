//! Search rectangles share a small palette of translucent images. Moving a
//! highlight only changes placements; the document tiles stay reusable.

// std
const std = @import("std");

// project
const graphics = @import("../graphics/main.zig");
const terminal = @import("../terminal/main.zig");

// aliases
const Highlights = @This();

// ====================================================================================================
// Constants
// ====================================================================================================

// Immediately below the tile cache's image IDs.
const image_id_base: graphics.ImageId = 0x7073_0000;
const image_id_last: graphics.ImageId = 0x7073_ffff;
const swatch_width = 256;
const swatch_height = 64;
const placement_limit = 4096;
const light_colors = [3][4]u8{
    .{ 255, 225, 80, 48 }, .{ 255, 200, 0, 92 }, .{ 200, 100, 0, 210 },
};
const dark_colors = [3][4]u8{
    .{ 255, 225, 80, 58 }, .{ 255, 200, 0, 108 }, .{ 255, 180, 30, 220 },
};

/// The tile cache can reserve this much terminal memory while search is visible.
pub const budget_bytes = light_colors.len * swatch_width * swatch_height * 4;

// ====================================================================================================
// Types
// ====================================================================================================

/// Already clipped to the content area in viewport pixels.
pub const Region = struct { rect: graphics.Rect, active: bool };

// ====================================================================================================
// Fields
// ====================================================================================================

images: [light_colors.len]graphics.ImageId = @splat(0),
next_id: graphics.ImageId = image_id_base,
dark: bool = false,
recoveries: [light_colors.len]u8 = @splat(0),
failed: bool = false,

// ====================================================================================================
// Public API
// ====================================================================================================

/// Regions arrive with the selected occurrence first so dense pages retain it
/// when the placement limit is reached.
pub fn draw(highlights: *Highlights, gpa: std.mem.Allocator, output: *std.Io.Writer, regions: []const Region, size: terminal.Size, dark: bool, behind_text: bool) !void {
    if (regions.len == 0 or highlights.failed) return;
    if (highlights.dark != dark) {
        highlights.clear(output);
        highlights.dark = dark;
    }
    const colors = if (dark) dark_colors else light_colors;
    for (colors, &highlights.images) |color, *image| {
        if (image.* != 0) continue;
        const canvas = graphics.Canvas.init(gpa, .direct, swatch_width, swatch_height) catch |err| switch (err) {
            error.SharedMemoryUnavailable => unreachable,
            error.OutOfMemory => return error.OutOfMemory,
        };
        @memset(std.mem.bytesAsSlice(u32, canvas.pixels), @as(u32, @bitCast(color)));
        const encoded = try canvas.finish(gpa);
        const id = highlights.next_id;
        highlights.next_id = if (id == image_id_last) image_id_base else id + 1;
        _ = try graphics.transmit(gpa, output, id, encoded);
        image.* = id;
    }

    var count: u32 = 0;
    for (regions) |region| {
        const r = region.rect;
        if (r.width == 0 or r.height == 0) continue;
        const style: u2 = if (region.active) 1 else 0;
        try highlights.place(output, r, size, style, behind_text, &count);
        if (region.active) {
            try highlights.place(output, .{ .x = r.x, .y = r.y, .width = r.width, .height = 1 }, size, 2, behind_text, &count);
            if (r.height > 1) try highlights.place(output, .{ .x = r.x, .y = r.y + (r.height - 1), .width = r.width, .height = 1 }, size, 2, behind_text, &count);
            if (r.height > 2) {
                try highlights.place(output, .{ .x = r.x, .y = r.y + 1, .width = 1, .height = r.height - 2 }, size, 2, behind_text, &count);
                if (r.width > 1) try highlights.place(output, .{ .x = r.x + (r.width - 1), .y = r.y + 1, .width = 1, .height = r.height - 2 }, size, 2, behind_text, &count);
            }
        }
        if (count == placement_limit) return;
    }
}

/// Reupload only a currently resident swatch. Delayed errors for its old ID
/// cannot invalidate the replacement.
pub fn reject(highlights: *Highlights, reply: graphics.Reply) enum { ignored, retry, failed } {
    if (reply.status == .ok or highlights.failed) return .ignored;
    for (&highlights.images, &highlights.recoveries) |*image, *recoveries| {
        if (image.* == 0 or image.* != reply.image) continue;
        if (reply.status == .not_found and reply.placement != null and recoveries.* < 2) {
            image.* = 0;
            recoveries.* += 1;
            return .retry;
        }
        highlights.failed = true;
        return .failed;
    }
    return .ignored;
}

pub fn clear(highlights: *Highlights, output: *std.Io.Writer) void {
    highlights.failed = false;
    highlights.recoveries = @splat(0);
    for (&highlights.images) |*image| {
        if (image.* != 0) graphics.free(output, image.*) catch {};
        image.* = 0;
    }
}

// ====================================================================================================
// Private Functions
// ====================================================================================================

fn place(highlights: *const Highlights, output: *std.Io.Writer, rect: graphics.Rect, size: terminal.Size, style: u2, behind_text: bool, count: *u32) !void {
    var y: u32 = 0;
    while (y < rect.height) {
        const height = @min(swatch_height, rect.height - y);
        var x: u32 = 0;
        while (x < rect.width) {
            if (count.* == placement_limit) return;
            const width = @min(swatch_width, rect.width - x);
            count.* += 1;
            try graphics.place(output, .{
                .image = highlights.images[style],
                .placement = count.*,
                .source = .{ .x = 0, .y = 0, .width = width, .height = height },
                .col = @intCast((rect.x + x) / size.cell_width),
                .row = @intCast((rect.y + y) / size.cell_height),
                .x_offset = @intCast((rect.x + x) % size.cell_width),
                .y_offset = @intCast((rect.y + y) % size.cell_height),
                .behind_text = behind_text,
                .layer = style + 1,
            });
            x += width;
        }
        y += height;
    }
}

// ====================================================================================================
// Tests
// ====================================================================================================

test "overlapping and repeated highlight swatches preserve document pixels beneath them" {
    const Emulator = @import("../emulator/main.zig").Emulator;
    const gpa = std.testing.allocator;
    const size: terminal.Size = .{ .cols = 8, .rows = 3, .cell_width = 5, .cell_height = 5 };
    const emulator = try Emulator.create(std.testing.io, gpa, size);
    defer emulator.destroy();
    const output = &emulator.output;
    const canvas = try graphics.Canvas.init(gpa, .direct, 40, 15);
    @memset(canvas.pixels, 255);
    _ = try graphics.transmit(gpa, output, 1, try canvas.finish(gpa));
    var highlights: Highlights = .{};
    defer highlights.clear(output);
    const regions = [_]Region{
        .{ .rect = .{ .x = 2, .y = 2, .width = 8, .height = 8 }, .active = false },
        .{ .rect = .{ .x = 20, .y = 2, .width = 8, .height = 8 }, .active = false },
        .{ .rect = .{ .x = 5, .y = 2, .width = 8, .height = 8 }, .active = true },
    };
    try highlights.draw(gpa, output, &regions, size, false, true);
    // Reverse paint order to exercise the protocol's layers.
    try graphics.place(output, .{
        .image = 1,
        .source = .{ .x = 0, .y = 0, .width = 40, .height = 15 },
        .col = 0,
        .row = 0,
        .x_offset = 0,
        .y_offset = 0,
        .behind_text = true,
    });
    try output.flush();
    const shot = try emulator.screenshot(gpa);
    defer gpa.free(shot.pixels);
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, shot.pixel(0, 0));
    const ordinary = shot.pixel(3, 4);
    try std.testing.expect(ordinary[2] < 255 and ordinary[2] > 180 and ordinary[3] == 255);
    try std.testing.expectEqual(ordinary, shot.pixel(21, 4));
    try std.testing.expect(shot.pixel(6, 4)[2] < ordinary[2]);
    try std.testing.expect(shot.pixel(6, 2)[2] < shot.pixel(6, 4)[2]);
}
