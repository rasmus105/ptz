//! Where pages go on screen, and which tiles of them are needed.
//!
//! Pages are rendered and uploaded in horizontal bands (tiles) of at most
//! `tile_height` pixels, so neither a tall page nor a high zoom needs one
//! huge image: the terminal only holds the tiles near the view.

// std
const std = @import("std");

// project
const pdf = @import("../pdf/main.zig");
const terminal = @import("../terminal/main.zig");

// ====================================================================================================
// Constants
// ====================================================================================================

pub const tile_height = 1024;
/// Pages are never rendered wider, which bounds a tile at 32 MiB of RGBA.
pub const page_width_max = 8192;
/// Space between pages, in pixels.
pub const gap = 12;
pub const slices_max = 64;
pub const wanted_max = 64;
pub const status_len_max = 256;

// ====================================================================================================
// Types
// ====================================================================================================

/// A point in the document: a page and a distance from its top, in points.
/// The distance may reach into the gap below the page.
pub const Anchor = struct {
    page: u32,
    y: f32,
};

/// One band of a page as rendered at some scale. Equal keys mean equal
/// pixels, so a key can name an uploaded image.
pub const Tile = struct {
    key: Key,
    /// Pixels per point.
    scale: f32,
    height: u32,

    pub const Key = struct {
        generation: u32,
        page: u32,
        /// Width of the whole page in pixels, which identifies the scale.
        width: u32,
        /// Band index from the top of the page.
        index: u32,
        dark: bool,
    };

    /// Where the tile's pixels start in the whole rendered page.
    pub fn top(tile: Tile) u32 {
        return tile.key.index * tile_height;
    }
};

/// The visible part of a tile and where it goes in the view.
pub const Slice = struct {
    tile: Tile.Key,
    source_x: u32,
    source_y: u32,
    width: u32,
    height: u32,
    /// Top left corner in the view, in pixels.
    x: u32,
    y: u32,
};

pub const Frame = struct {
    slices_buffer: [slices_max]Slice,
    slices_len: u32,
    /// Tiles that should be ready, most urgent first: the visible ones, then
    /// those of the next screen down, then of the screen above.
    wanted_buffer: [wanted_max]Tile,
    wanted_len: u32,
    status_buffer: [status_len_max]u8,
    status_len: u32,

    pub fn slices(frame: *const Frame) []const Slice {
        return frame.slices_buffer[0..frame.slices_len];
    }

    pub fn wanted(frame: *const Frame) []const Tile {
        return frame.wanted_buffer[0..frame.wanted_len];
    }

    pub fn status(frame: *const Frame) []const u8 {
        return frame.status_buffer[0..frame.status_len];
    }
};

/// The document's layout at one zoom and window size.
pub const Geometry = struct {
    page_sizes: []const pdf.Size,
    /// The view excludes the status line.
    view_width: u32,
    view_height: u32,
    /// Pixels per point.
    scale: f32,
    /// Width of the widest page, in pixels.
    content_width: u32,

    pub fn init(page_sizes: []const pdf.Size, size: terminal.Size, zoom: f32) Geometry {
        std.debug.assert(zoom > 0);
        const view_width = @as(u32, size.cols) * size.cell_width;
        var widest: f32 = 0;
        for (page_sizes) |page| widest = @max(widest, page.width);
        const scale = if (widest == 0) 1 else @min(
            @as(f32, @floatFromInt(view_width)) / widest * zoom,
            page_width_max / widest,
        );
        return .{
            .page_sizes = page_sizes,
            .view_width = view_width,
            .view_height = @as(u32, size.rows -| 1) * size.cell_height,
            .scale = scale,
            .content_width = @intFromFloat(@round(widest * scale)),
        };
    }

    pub fn pageWidth(geometry: Geometry, page: u32) u32 {
        return @max(1, @as(u32, @intFromFloat(@round(geometry.page_sizes[page].width * geometry.scale))));
    }

    pub fn pageHeight(geometry: Geometry, page: u32) u32 {
        return @max(1, @as(u32, @intFromFloat(@round(geometry.page_sizes[page].height * geometry.scale))));
    }

    /// Height of all pages and the gaps between them.
    pub fn contentHeight(geometry: Geometry) i64 {
        var height: i64 = 0;
        for (0..geometry.page_sizes.len) |page| height += geometry.pageHeight(@intCast(page)) + gap;
        return @max(0, height - gap);
    }

    pub fn panMax(geometry: Geometry) u32 {
        return geometry.content_width -| geometry.view_width;
    }

    /// Distance of the anchor from the document's top, in pixels.
    pub fn offsetOf(geometry: Geometry, anchor: Anchor) i64 {
        var offset: i64 = 0;
        for (0..anchor.page) |page| offset += geometry.pageHeight(@intCast(page)) + gap;
        return offset + @as(i64, @intFromFloat(@round(anchor.y * geometry.scale)));
    }

    /// The anchor at `offset` pixels from the document's top, clamped so the
    /// view stays within the document.
    pub fn anchorAt(geometry: Geometry, offset: i64) Anchor {
        if (geometry.page_sizes.len == 0) return .{ .page = 0, .y = 0 };
        const offset_max = @max(0, geometry.contentHeight() - geometry.view_height);
        const clamped = std.math.clamp(offset, 0, offset_max);
        var top: i64 = 0;
        for (0..geometry.page_sizes.len) |page| {
            const bottom = top + geometry.pageHeight(@intCast(page)) + gap;
            if (clamped < bottom or page + 1 == geometry.page_sizes.len) {
                return .{ .page = @intCast(page), .y = @as(f32, @floatFromInt(clamped - top)) / geometry.scale };
            }
            top = bottom;
        }
        unreachable;
    }
};

/// What distinguishes tiles beyond geometry.
pub const Version = struct {
    generation: u32,
    dark: bool,
};

// ====================================================================================================
// Public API
// ====================================================================================================

pub fn layout(geometry: Geometry, anchor: Anchor, pan_x: u32, version: Version, frame: *Frame) void {
    frame.slices_len = 0;
    frame.wanted_len = 0;
    frame.status_len = 0;
    if (geometry.page_sizes.len == 0) return;

    const top = geometry.offsetOf(anchor);
    const height: i64 = geometry.view_height;
    // Visible tiles first, so they also lead the wanted list.
    visitTiles(geometry, top, top + height, version, frame, .{ .pan_x = pan_x, .top = top });
    visitTiles(geometry, top + height, top + 2 * height, version, frame, null);
    visitTiles(geometry, top - height, top, version, frame, null);
}

// ====================================================================================================
// Private Functions
// ====================================================================================================

const View = struct {
    pan_x: u32,
    /// Offset of the view's top in the document.
    top: i64,
};

/// Adds the tiles overlapping document rows [`start`, `end`) to the wanted
/// list, and, given the `view`, their visible parts to the slices. Tiles
/// beyond the frame's capacity are dropped.
fn visitTiles(geometry: Geometry, start: i64, end: i64, version: Version, frame: *Frame, view: ?View) void {
    var page_top: i64 = 0;
    for (0..geometry.page_sizes.len) |index| {
        const page: u32 = @intCast(index);
        const page_height = geometry.pageHeight(page);
        defer page_top += page_height + gap;
        if (page_top >= end) break;
        if (page_top + page_height <= start) continue;

        const width = geometry.pageWidth(page);
        const tiles = std.math.divCeil(u32, page_height, tile_height) catch unreachable;
        for (0..tiles) |band| {
            const tile_top = page_top + @as(i64, @intCast(band)) * tile_height;
            const tile: Tile = .{
                .key = .{ .generation = version.generation, .page = page, .width = width, .index = @intCast(band), .dark = version.dark },
                .scale = geometry.scale,
                .height = @min(tile_height, page_height - @as(u32, @intCast(band)) * tile_height),
            };
            if (tile_top >= end or tile_top + tile.height <= start) continue;
            if (frame.wanted_len < wanted_max and !contains(frame.wanted(), tile.key)) {
                frame.wanted_buffer[frame.wanted_len] = tile;
                frame.wanted_len += 1;
            }
            if (view) |v| addSlice(geometry, tile, tile_top, v, frame);
        }
    }
}

fn addSlice(geometry: Geometry, tile: Tile, tile_top: i64, view: View, frame: *Frame) void {
    if (frame.slices_len == slices_max) return;
    // Rows: the part of the tile inside the view.
    const visible_top = @max(tile_top, view.top);
    const visible_bottom = @min(tile_top + tile.height, view.top + geometry.view_height);
    std.debug.assert(visible_top < visible_bottom);

    // Columns: pages are centred in the content, which is centred in the
    // view when narrower, and panned when wider.
    const width = tile.key.width;
    const page_left: i64 = @divFloor(@as(i64, geometry.content_width) - width, 2);
    const content_left: i64 = if (geometry.content_width <= geometry.view_width)
        @divFloor(@as(i64, geometry.view_width) - geometry.content_width, 2)
    else
        -@as(i64, view.pan_x);
    const left = content_left + page_left;
    const visible_left = @max(left, 0);
    const visible_right = @min(left + width, geometry.view_width);
    if (visible_left >= visible_right) return;

    frame.slices_buffer[frame.slices_len] = .{
        .tile = tile.key,
        .source_x = @intCast(visible_left - left),
        .source_y = @intCast(visible_top - tile_top),
        .width = @intCast(visible_right - visible_left),
        .height = @intCast(visible_bottom - visible_top),
        .x = @intCast(visible_left),
        .y = @intCast(visible_top - view.top),
    };
    frame.slices_len += 1;
}

fn contains(tiles: []const Tile, key: Tile.Key) bool {
    for (tiles) |tile| if (std.meta.eql(tile.key, key)) return true;
    return false;
}

// ====================================================================================================
// Tests
// ====================================================================================================

const test_size: terminal.Size = .{ .cols = 80, .rows = 26, .cell_width = 10, .cell_height = 20 };

test "pages fill the width and are cut into tiles at the view's edges" {
    // Two 400x700 pt pages at 2 px/pt: 800x1400 px, so two tiles each.
    const pages: [2]pdf.Size = @splat(.{ .width = 400, .height = 700 });
    const geometry: Geometry = .init(&pages, test_size, 1);
    try std.testing.expectEqual(2, geometry.scale);
    try std.testing.expectEqual(500, geometry.view_height);

    var frame: Frame = undefined;
    // 1300 px down: the last 100 px of page 0's second tile, the gap, then
    // the first 388 px of page 1.
    layout(geometry, geometry.anchorAt(1300), 0, .{ .generation = 1, .dark = false }, &frame);
    const slices = frame.slices();
    try std.testing.expectEqual(2, slices.len);
    try std.testing.expectEqual(Slice{
        .tile = .{ .generation = 1, .page = 0, .width = 800, .index = 1, .dark = false },
        .source_x = 0,
        .source_y = 1300 - tile_height,
        .width = 800,
        .height = 100,
        .x = 0,
        .y = 0,
    }, slices[0]);
    try std.testing.expectEqual(Slice{
        .tile = .{ .generation = 1, .page = 1, .width = 800, .index = 0, .dark = false },
        .source_x = 0,
        .source_y = 0,
        .width = 800,
        .height = 500 - 100 - gap,
        .x = 0,
        .y = 100 + gap,
    }, slices[1]);

    // Wanted: the visible tiles, then none new in the screen below (page 1's
    // first tile reaches past it), then page 0's first tile above.
    const wanted = frame.wanted();
    try std.testing.expectEqual(3, wanted.len);
    try std.testing.expectEqual(.{ 0, 1 }, .{ wanted[0].key.page, wanted[0].key.index });
    try std.testing.expectEqual(.{ 1, 0 }, .{ wanted[1].key.page, wanted[1].key.index });
    try std.testing.expectEqual(.{ 0, 0 }, .{ wanted[2].key.page, wanted[2].key.index });
    try std.testing.expectEqual(1400 - tile_height, wanted[0].height);
}

test "narrow content is centred and wide content is panned" {
    const pages = [_]pdf.Size{.{ .width = 400, .height = 100 }};
    var frame: Frame = undefined;

    const zoomed_out: Geometry = .init(&pages, test_size, 0.5);
    layout(zoomed_out, .{ .page = 0, .y = 0 }, 0, .{ .generation = 1, .dark = false }, &frame);
    try std.testing.expectEqual(.{ 200, 400, 0 }, .{ frame.slices()[0].x, frame.slices()[0].width, frame.slices()[0].source_x });

    const zoomed_in: Geometry = .init(&pages, test_size, 2);
    try std.testing.expectEqual(800, zoomed_in.panMax());
    layout(zoomed_in, .{ .page = 0, .y = 0 }, 300, .{ .generation = 1, .dark = false }, &frame);
    try std.testing.expectEqual(.{ 0, 800, 300 }, .{ frame.slices()[0].x, frame.slices()[0].width, frame.slices()[0].source_x });
}

test "anchors round-trip through offsets and clamp to the document" {
    const pages = [_]pdf.Size{ .{ .width = 400, .height = 700 }, .{ .width = 300, .height = 700 } };
    const geometry: Geometry = .init(&pages, test_size, 1);
    try std.testing.expectEqual(1400 + gap + 1400, geometry.contentHeight());
    try std.testing.expectEqual(Anchor{ .page = 0, .y = 100 }, geometry.anchorAt(200));
    try std.testing.expectEqual(200, geometry.offsetOf(.{ .page = 0, .y = 100 }));
    // Inside the gap after page 0.
    try std.testing.expectEqual(Anchor{ .page = 0, .y = 701 }, geometry.anchorAt(1402));
    try std.testing.expectEqual(Anchor{ .page = 0, .y = 0 }, geometry.anchorAt(-50));
    // The furthest the view's top can go.
    try std.testing.expectEqual(geometry.contentHeight() - 500, geometry.offsetOf(geometry.anchorAt(1 << 40)));
}

test "zoom is capped by the page width limit" {
    const pages = [_]pdf.Size{.{ .width = 400, .height = 100 }};
    const geometry: Geometry = .init(&pages, test_size, 1000);
    try std.testing.expectEqual(page_width_max, geometry.content_width);
}
