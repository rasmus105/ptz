//! Where pages go on screen, and which tiles of them are needed.
//!
//! Pages are rendered and uploaded in tiles of at most `tile_width` by
//! `tile_height` pixels, so neither a long page nor a high zoom needs one
//! huge image: the terminal only holds tiles in and near the view.

// std
const std = @import("std");

// project
const pdf = @import("../pdf/main.zig");
const terminal = @import("../terminal/main.zig");

// ====================================================================================================
// Constants
// ====================================================================================================

/// A tile is at most 8 MiB of RGBA.
pub const tile_width = 2048;
pub const tile_height = 1024;
const tile_bytes_max = tile_width * tile_height * 4;
/// Tiles a layout lists, visible and wanted alike. Zoomed out, a tall view
/// shows over a hundred small pages, each its own tile.
pub const tiles_max = 256;
/// Pixel bytes of the tiles a layout lists, which bounds the terminal memory
/// a frame keeps in use. Room for 32 full tiles, far more than one screen.
pub const wanted_bytes_max = 32 * tile_bytes_max;
/// Pages are never rendered wider, which keeps pixel offsets far from
/// overflowing and rendering cost per page bounded.
pub const page_width_max = 16384;
/// Space between pages, in pixels.
pub const gap = 12;

// ====================================================================================================
// Types
// ====================================================================================================

/// A point in the document: a page and a distance from its top, in points.
/// The distance may reach into the gap below the page.
pub const Anchor = struct {
    page: u32,
    y: f32,
};

/// A rectangle of a page as rendered at some size. Equal tiles have equal
/// pixels, so a tile can name an uploaded image.
pub const Tile = struct {
    /// Which load of the document; see `viewer.Document`.
    generation: u32,
    page: u32,
    /// The whole page's size in pixels, which fixes the scale.
    page_width: u32,
    page_height: u32,
    column: u32,
    row: u32,
    dark: bool,

    pub fn left(tile: Tile) u32 {
        return tile.column * tile_width;
    }

    pub fn top(tile: Tile) u32 {
        return tile.row * tile_height;
    }

    pub fn width(tile: Tile) u32 {
        return @min(tile_width, tile.page_width - tile.left());
    }

    pub fn height(tile: Tile) u32 {
        return @min(tile_height, tile.page_height - tile.top());
    }

    /// Whether `other` has the same pixels apart from the document version
    /// and colours, so it can stand in while this one renders.
    pub fn sameArea(tile: Tile, other: Tile) bool {
        return tile.page == other.page and tile.page_width == other.page_width and
            tile.page_height == other.page_height and tile.column == other.column and tile.row == other.row;
    }
};

/// The visible part of a tile and where it goes in the view.
pub const Slice = struct {
    tile: Tile,
    source_x: u32,
    source_y: u32,
    width: u32,
    height: u32,
    /// Top left corner in the view, in pixels.
    x: u32,
    y: u32,
};

/// The result of `layout`.
pub const Tiles = struct {
    slices_buffer: [tiles_max]Slice,
    slices_len: u32,
    wanted_buffer: [tiles_max]Tile,
    wanted_len: u32,
    wanted_bytes: u64,

    pub fn slices(tiles: *const Tiles) []const Slice {
        return tiles.slices_buffer[0..tiles.slices_len];
    }

    /// Tiles that should be ready, most urgent first: the visible ones, then
    /// those of the next screen down, then of the screen above.
    pub fn wanted(tiles: *const Tiles) []const Tile {
        return tiles.wanted_buffer[0..tiles.wanted_len];
    }
};

/// What distinguishes tiles beyond geometry.
pub const Version = struct {
    generation: u32,
    dark: bool,
};

/// Where the content's top left corner is relative to the view.
const Origin = struct {
    left: i64,
    top: i64,
};

/// The document's layout at one zoom and window size.
pub const Geometry = struct {
    page_sizes: []const pdf.Size,
    /// Each page's distance from the first page's top, in points, without
    /// gaps; see `viewer.Document`.
    page_offsets: []const f64,
    /// The view excludes the status line.
    view_width: u32,
    view_height: u32,
    /// Pixels per point.
    scale: f32,
    /// Size of all pages: the widest page by all pages and the gaps between them.
    content_width: u32,
    content_height: i64,

    pub fn init(page_sizes: []const pdf.Size, page_offsets: []const f64, size: terminal.Size, zoom: f32) Geometry {
        std.debug.assert(zoom > 0);
        std.debug.assert(page_offsets.len == page_sizes.len);
        std.debug.assert(size.cols > 0 and size.cell_width > 0 and size.cell_height > 0);
        const view_width = @as(u32, size.cols) * size.cell_width;
        var widest: f32 = 0;
        for (page_sizes) |page| widest = @max(widest, page.width);
        var geometry: Geometry = .{
            .page_sizes = page_sizes,
            .page_offsets = page_offsets,
            .view_width = view_width,
            .view_height = @as(u32, size.rows -| 1) * size.cell_height,
            .scale = if (widest == 0) 1 else @min(
                @as(f32, @floatFromInt(view_width)) / widest * zoom,
                page_width_max / widest,
            ),
            .content_width = 0,
            .content_height = 0,
        };
        if (page_sizes.len > 0) {
            geometry.content_width = @max(1, @as(u32, @intFromFloat(@round(widest * geometry.scale))));
            const last: u32 = @intCast(page_sizes.len - 1);
            geometry.content_height = geometry.pageTop(last) + geometry.pageHeight(last);
        }
        return geometry;
    }

    pub fn pageWidth(geometry: Geometry, page: u32) u32 {
        return @max(1, @as(u32, @intFromFloat(@round(geometry.page_sizes[page].width * geometry.scale))));
    }

    pub fn pageHeight(geometry: Geometry, page: u32) u32 {
        return @max(1, @as(u32, @intFromFloat(@round(geometry.page_sizes[page].height * geometry.scale))));
    }

    /// Distance of the page's top from the document's top, in pixels.
    pub fn pageTop(geometry: Geometry, page: u32) i64 {
        const offset = geometry.page_offsets[page] * geometry.scale;
        return @as(i64, @intFromFloat(@round(offset))) + @as(i64, page) * gap;
    }

    pub fn panMax(geometry: Geometry) u32 {
        return geometry.content_width -| geometry.view_width;
    }

    /// Distance of the anchor from the document's top, in pixels.
    pub fn offsetOf(geometry: Geometry, anchor: Anchor) i64 {
        return geometry.pageTop(anchor.page) + @as(i64, @intFromFloat(@round(anchor.y * geometry.scale)));
    }

    /// The anchor at `offset` pixels from the document's top, clamped so the
    /// view stays within the document.
    pub fn anchorAt(geometry: Geometry, offset: i64) Anchor {
        if (geometry.page_sizes.len == 0) return .{ .page = 0, .y = 0 };
        const offset_max = @max(0, geometry.content_height - geometry.view_height);
        const clamped = std.math.clamp(offset, 0, offset_max);
        const page = geometry.pageAt(clamped);
        return .{ .page = page, .y = @as(f32, @floatFromInt(clamped - geometry.pageTop(page))) / geometry.scale };
    }

    /// The page whose area, including the gap below it, contains `offset`;
    /// the first or last page for offsets beyond the document.
    pub fn pageAt(geometry: Geometry, offset: i64) u32 {
        std.debug.assert(geometry.page_sizes.len > 0);
        // The first page starting after `offset`, minus one.
        var low: u32 = 0;
        var high: u32 = @intCast(geometry.page_sizes.len);
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (geometry.pageTop(middle) <= offset) low = middle + 1 else high = middle;
        }
        return low -| 1;
    }
};

// ====================================================================================================
// Public API
// ====================================================================================================

pub fn layout(geometry: Geometry, anchor: Anchor, pan_x: u32, version: Version, tiles: *Tiles) void {
    tiles.slices_len = 0;
    tiles.wanted_len = 0;
    tiles.wanted_bytes = 0;
    if (geometry.page_sizes.len == 0 or geometry.view_height == 0) return;

    const top = geometry.offsetOf(anchor);
    const height: i64 = geometry.view_height;
    // Content narrower than the view is centred; wider content is panned.
    const left: i64 = if (geometry.content_width <= geometry.view_width)
        @divFloor(@as(i64, geometry.view_width) - geometry.content_width, 2)
    else
        -@as(i64, pan_x);
    const origin: Origin = .{ .left = left, .top = top };
    // Visible tiles first, so they also lead the wanted list.
    addTiles(geometry, version, origin, top, top + height, tiles, true);
    addTiles(geometry, version, origin, top + height, top + 2 * height, tiles, false);
    addTiles(geometry, version, origin, top - height, top, tiles, false);
}

// ====================================================================================================
// Private Functions
// ====================================================================================================

/// Adds the tiles overlapping document rows [`start`, `end`) and the view's
/// columns to the wanted list, and with `visible` their visible parts to the
/// slices. Tiles beyond the capacity are dropped.
fn addTiles(geometry: Geometry, version: Version, origin: Origin, start: i64, end: i64, tiles: *Tiles, visible: bool) void {
    var page = geometry.pageAt(start);
    while (page < geometry.page_sizes.len) : (page += 1) {
        const page_top = geometry.pageTop(page);
        if (page_top >= end) break;
        const page_width = geometry.pageWidth(page);
        const page_height = geometry.pageHeight(page);
        const page_left = origin.left + @divFloor(@as(i64, geometry.content_width) - page_width, 2);

        // The page's pixels within the range and the view, if any.
        const x_start = @max(0, -page_left);
        const x_end = @min(page_width, @as(i64, geometry.view_width) - page_left);
        const y_start = @max(0, start - page_top);
        const y_end = @min(page_height, end - page_top);
        if (x_start >= x_end or y_start >= y_end) continue;

        var row: u32 = @intCast(@divFloor(y_start, tile_height));
        while (row * tile_height < y_end) : (row += 1) {
            var column: u32 = @intCast(@divFloor(x_start, tile_width));
            while (column * tile_width < x_end) : (column += 1) {
                const tile: Tile = .{
                    .generation = version.generation,
                    .page = page,
                    .page_width = page_width,
                    .page_height = page_height,
                    .column = column,
                    .row = row,
                    .dark = version.dark,
                };
                if (!addWanted(tiles, tile)) return;
                if (visible) addSlice(geometry, tile, page_left, page_top, origin.top, tiles);
            }
        }
    }
}

/// Returns false once the list is full.
fn addWanted(tiles: *Tiles, tile: Tile) bool {
    for (tiles.wanted()) |other| if (std.meta.eql(other, tile)) return true;
    const tile_bytes = @as(u64, tile.width()) * tile.height() * 4;
    if (tiles.wanted_len == tiles_max or tiles.wanted_bytes + tile_bytes > wanted_bytes_max) return false;
    tiles.wanted_buffer[tiles.wanted_len] = tile;
    tiles.wanted_len += 1;
    tiles.wanted_bytes += tile_bytes;
    return true;
}

fn addSlice(geometry: Geometry, tile: Tile, page_left: i64, page_top: i64, view_top: i64, tiles: *Tiles) void {
    // Every visible tile is also wanted, so the slices can't overflow first.
    std.debug.assert(tiles.slices_len < tiles_max);
    const tile_left = page_left + tile.left();
    const tile_top = page_top + tile.top() - view_top;
    const visible_left = @max(tile_left, 0);
    const visible_top = @max(tile_top, 0);
    const visible_right = @min(tile_left + tile.width(), geometry.view_width);
    const visible_bottom = @min(tile_top + tile.height(), geometry.view_height);
    std.debug.assert(visible_left < visible_right);
    std.debug.assert(visible_top < visible_bottom);

    tiles.slices_buffer[tiles.slices_len] = .{
        .tile = tile,
        .source_x = @intCast(visible_left - tile_left),
        .source_y = @intCast(visible_top - tile_top),
        .width = @intCast(visible_right - visible_left),
        .height = @intCast(visible_bottom - visible_top),
        .x = @intCast(visible_left),
        .y = @intCast(visible_top),
    };
    tiles.slices_len += 1;
}

// ====================================================================================================
// Tests
// ====================================================================================================

const test_size: terminal.Size = .{ .cols = 80, .rows = 26, .cell_width = 10, .cell_height = 20 };
const test_version: Version = .{ .generation = 1, .dark = false };

/// Offsets for pages of these sizes, as `viewer.Document` defines them.
fn testOffsets(comptime pages: []const pdf.Size) [pages.len]f64 {
    var offsets: [pages.len]f64 = undefined;
    var offset: f64 = 0;
    for (pages, &offsets) |page, *page_offset| {
        page_offset.* = offset;
        offset += page.height;
    }
    return offsets;
}

test "pages fill the width and are cut into tiles at the view's edges" {
    // Two 400x700 pt pages at 2 px/pt: 800x1400 px, so two tile rows each.
    const pages: [2]pdf.Size = @splat(.{ .width = 400, .height = 700 });
    const offsets = testOffsets(&pages);
    const geometry: Geometry = .init(&pages, &offsets, test_size, 1);
    try std.testing.expectEqual(2, geometry.scale);
    try std.testing.expectEqual(500, geometry.view_height);

    var tiles: Tiles = undefined;
    // 1300 px down: the last 100 px of page 0's second tile row, the gap,
    // then the first 388 px of page 1.
    layout(geometry, geometry.anchorAt(1300), 0, test_version, &tiles);
    const slices = tiles.slices();
    try std.testing.expectEqual(2, slices.len);
    try std.testing.expectEqual(Slice{
        .tile = .{ .generation = 1, .page = 0, .page_width = 800, .page_height = 1400, .column = 0, .row = 1, .dark = false },
        .source_x = 0,
        .source_y = 1300 - tile_height,
        .width = 800,
        .height = 100,
        .x = 0,
        .y = 0,
    }, slices[0]);
    try std.testing.expectEqual(.{ 1, 0, 0, 388, 100 + gap }, .{
        slices[1].tile.page, slices[1].tile.row, slices[1].source_y, slices[1].height, slices[1].y,
    });

    // Wanted: the visible tiles, none new in the screen below (page 1's
    // first tile reaches past it), then page 0's first tile above.
    const wanted = tiles.wanted();
    try std.testing.expectEqual(3, wanted.len);
    try std.testing.expectEqual(.{ 0, 1 }, .{ wanted[0].page, wanted[0].row });
    try std.testing.expectEqual(.{ 1, 0 }, .{ wanted[1].page, wanted[1].row });
    try std.testing.expectEqual(.{ 0, 0 }, .{ wanted[2].page, wanted[2].row });
    try std.testing.expectEqual(1400 - tile_height, wanted[0].height());
}

test "narrow content is centred, and only visible columns of wide content are used" {
    const pages = [_]pdf.Size{.{ .width = 400, .height = 100 }};
    const offsets = testOffsets(&pages);
    var tiles: Tiles = undefined;

    const zoomed_out: Geometry = .init(&pages, &offsets, test_size, 0.5);
    layout(zoomed_out, .{ .page = 0, .y = 0 }, 0, test_version, &tiles);
    try std.testing.expectEqual(.{ 200, 400, 0 }, .{ tiles.slices()[0].x, tiles.slices()[0].width, tiles.slices()[0].source_x });

    // 8x: 6400 px wide, panned to 4000: columns 1 (2048..4096) and 2.
    const zoomed_in: Geometry = .init(&pages, &offsets, test_size, 8);
    layout(zoomed_in, .{ .page = 0, .y = 0 }, 4000, test_version, &tiles);
    const slices = tiles.slices();
    try std.testing.expectEqual(2, slices.len);
    try std.testing.expectEqual(.{ 1, 4000 - tile_width, 96, 0 }, .{ slices[0].tile.column, slices[0].source_x, slices[0].width, slices[0].x });
    try std.testing.expectEqual(.{ 2, 0, 800 - 96, 96 }, .{ slices[1].tile.column, slices[1].source_x, slices[1].width, slices[1].x });
}

test "anchors round-trip through offsets and clamp to the document" {
    const pages = [_]pdf.Size{ .{ .width = 400, .height = 700 }, .{ .width = 300, .height = 700 } };
    const offsets = testOffsets(&pages);
    const geometry: Geometry = .init(&pages, &offsets, test_size, 1);
    try std.testing.expectEqual(1400 + gap + 1400, geometry.content_height);
    try std.testing.expectEqual(Anchor{ .page = 0, .y = 100 }, geometry.anchorAt(200));
    try std.testing.expectEqual(200, geometry.offsetOf(.{ .page = 0, .y = 100 }));
    // Inside the gap after page 0, and the start of page 1.
    try std.testing.expectEqual(Anchor{ .page = 0, .y = 701 }, geometry.anchorAt(1402));
    try std.testing.expectEqual(Anchor{ .page = 1, .y = 0 }, geometry.anchorAt(1400 + gap));
    try std.testing.expectEqual(Anchor{ .page = 0, .y = 0 }, geometry.anchorAt(-50));
    // The furthest the view's top can go.
    try std.testing.expectEqual(geometry.content_height - 500, geometry.offsetOf(geometry.anchorAt(1 << 40)));
}

test "every visible page is drawn, however many fit on screen" {
    // 2 px tall pages, so 36 fit in the 500 px view.
    const pages: [500]pdf.Size = @splat(.{ .width = 400, .height = 1 });
    const offsets = testOffsets(&pages);
    const geometry: Geometry = .init(&pages, &offsets, test_size, 1);
    var tiles: Tiles = undefined;
    layout(geometry, .{ .page = 0, .y = 0 }, 0, test_version, &tiles);
    try std.testing.expectEqual(36, tiles.slices_len);
    try std.testing.expect(tiles.wanted_len <= tiles_max);
}

test "the wanted tiles stay within the memory bound" {
    // Zoomed in on long pages, the screens above and below need far more
    // full tiles than are allowed.
    const pages: [4]pdf.Size = @splat(.{ .width = 400, .height = 4000 });
    const offsets = testOffsets(&pages);
    const tall: terminal.Size = .{ .cols = 400, .rows = 200, .cell_width = 10, .cell_height = 20 };
    const geometry: Geometry = .init(&pages, &offsets, tall, 8);
    var tiles: Tiles = undefined;
    layout(geometry, geometry.anchorAt(100_000), 0, test_version, &tiles);
    try std.testing.expect(tiles.slices_len > 0);
    var bytes: u64 = 0;
    for (tiles.wanted()) |tile| bytes += @as(u64, tile.width()) * tile.height() * 4;
    try std.testing.expect(bytes <= wanted_bytes_max);
}
