//! Link hints belong to one viewport. Keep their labels and positions fixed
//! while typing, so filtering cannot change which link a key sequence opens.

// std
const std = @import("std");

// project
const document = @import("../document/main.zig");
const terminal = @import("../terminal/main.zig");

// local
const tiling = @import("tiling.zig");

// ====================================================================================================
// Constants
// ====================================================================================================

const alphabet = "asdfghjkl";
const label_len_max = 3;
const labels_max = alphabet.len * alphabet.len * alphabet.len;
/// Bounds the memory retained by a single lookup on a densely annotated page.
pub const links_max = 4096;

// ====================================================================================================
// Types
// ====================================================================================================

const Cell = struct { col: usize, row: usize };
const Rect = struct { x0: u16, y0: u16, x1: u16, y1: u16 };

const Placement = struct {
    const Grid = std.StaticBitSet(65536);

    rects: [links_max]Rect = undefined,
    // Ordinary terminals fit this index. Larger viewports query the same
    // rectangles directly so placement remains exact without allocating.
    occupied: Grid = undefined,
    stride: usize = 0,

    fn index(p: *Placement, size: terminal.Size, count: usize) void {
        if (@as(usize, size.cols) * (size.rows - 1) > Grid.bit_length) return;
        p.stride = size.cols;
        p.occupied = .empty;
        for (p.rects[0..count]) |r| {
            for (r.y0..@as(usize, r.y1) + 1) |row| {
                const base = row * p.stride;
                p.occupied.setRangeValue(.{ .start = base + r.x0, .end = base + r.x1 + 1 }, true);
            }
        }
    }

    fn clear(p: *const Placement, col: usize, row: usize, width: usize, count: usize) bool {
        if (p.stride > 0) {
            const start = row * p.stride + col;
            for (start..start + width) |cell| if (p.occupied.isSet(cell)) return false;
        } else {
            for (p.rects[0..count]) |r| {
                if (r.y0 <= row and row <= r.y1 and r.x0 < col + width and col <= r.x1) return false;
            }
        }
        return true;
    }

    fn position(p: *const Placement, r: Rect, size: terminal.Size, width: usize, count: usize) Cell {
        const after = @as(usize, r.x1) + 1;
        const last = @as(usize, size.cols) - width;
        const start = @min(r.x0, last);
        if (r.x0 >= width and p.clear(r.x0 - width, r.y0, width, count))
            return .{ .col = r.x0 - width, .row = r.y0 };
        if (after <= last and p.clear(after, r.y0, width, count))
            return .{ .col = after, .row = r.y0 };

        // Search only the nearby part of the top and bottom edges, keeping
        // the association legible even for a very wide link.
        for (start..@min(last, @min(r.x1, start + 12)) + 1) |col| {
            if (r.y0 > 0 and p.clear(col, r.y0 - 1, width, count))
                return .{ .col = col, .row = r.y0 - 1 };
            if (@as(usize, r.y1) + 1 < size.rows - 1 and p.clear(col, r.y1 + 1, width, count))
                return .{ .col = col, .row = r.y1 + 1 };
        }
        // A link can fill the viewport. Favor its trailing edge so its
        // opening text survives even when the badge must overlap the link.
        return .{ .col = @min(last, after -| width), .row = r.y0 };
    }
};

pub const Request = struct {
    id: u64,
    generation: u32,
    regions: [tiling.tiles_max]Region,
    len: usize,
    incomplete: bool,

    pub const Region = struct { page: u32, area: document.Rect };

    pub fn init(id: u64, generation: u32, geometry: tiling.Geometry, anchor: tiling.Anchor, pan_x: u32) Request {
        var request: Request = .{ .id = id, .generation = generation, .regions = undefined, .len = 0, .incomplete = false };
        if (geometry.page_sizes.len == 0 or geometry.view_height == 0) return request;
        const top = geometry.offsetOf(anchor);
        const bottom = top + geometry.view_height;
        var page = geometry.pageAt(top);
        while (page < geometry.page_sizes.len) : (page += 1) {
            const page_top = geometry.pageTop(page);
            if (page_top >= bottom) break;
            const left = geometry.pageLeft(page, pan_x);
            const width = geometry.pageWidth(page);
            const height = geometry.pageHeight(page);
            const x0 = @max(0, -left);
            const x1 = @min(width, @as(i64, geometry.view_width) - left);
            const y0 = @max(0, top - page_top);
            const y1 = @min(height, bottom - page_top);
            if (x0 >= x1 or y0 >= y1) continue;
            if (request.len == request.regions.len) {
                request.incomplete = true;
                break;
            }
            const w: f32 = @floatFromInt(width);
            const h: f32 = @floatFromInt(height);
            request.regions[request.len] = .{ .page = page, .area = .{
                .x0 = @as(f32, @floatFromInt(x0)) / w,
                .x1 = @as(f32, @floatFromInt(x1)) / w,
                .y0 = @as(f32, @floatFromInt(y0)) / h,
                .y1 = @as(f32, @floatFromInt(y1)) / h,
            } };
            request.len += 1;
        }
        return request;
    }
};

pub const Label = struct {
    col: u16,
    row: u16,
    code: [label_len_max]u8,
    len: usize,
    link: usize,

    pub fn text(label: *const Label) []const u8 {
        return label.code[0..label.len];
    }
};

pub const Hints = struct {
    mode: enum { off, loading, select, confirm } = .off,
    request_id: u64 = 0,
    links: []const document.Link = &.{},
    incomplete: bool = false,
    /// Prior batches in this Tab cycle. A crowded link can wait while
    /// other links that fit on screen get a badge in the current batch.
    shown: std.StaticBitSet(links_max) = .empty,
    shown_count: usize = 0,
    count: usize = 0,
    labels: [labels_max]Label = undefined,
    prefix: [label_len_max]u8 = undefined,
    prefix_len: usize = 0,
    preview: ?document.Link.Web = null,

    pub fn close(hints: *Hints) void {
        hints.mode = .off;
        hints.links = &.{};
        hints.preview = null;
        hints.shown = .empty;
        hints.shown_count = 0;
    }

    pub fn show(hints: *Hints, geometry: tiling.Geometry, size: terminal.Size, anchor: tiling.Anchor, pan_x: u32) void {
        if (hints.shown_count == hints.links.len) {
            hints.shown = .empty;
            hints.shown_count = 0;
        }
        hints.count = 0;
        hints.prefix_len = 0;
        var width: usize = 1;
        var capacity: usize = alphabet.len;
        const remaining = hints.links.len - hints.shown_count;
        while (capacity < remaining and width < @min(label_len_max, size.cols)) {
            width += 1;
            capacity *= alphabet.len;
        }

        const top = geometry.offsetOf(anchor);
        var placement: Placement = .{};
        for (hints.links, 0..) |link, i| {
            placement.rects[i] = cells(geometry, size, top, pan_x, link);
        }
        placement.index(size, hints.links.len);
        for (placement.rects[0..hints.links.len], 0..) |rect, i| {
            if (hints.shown.isSet(i)) continue;
            const pos = placement.position(rect, size, width, hints.links.len);
            // Coincident links share a natural badge position. Tab cycles them
            // without scattering badges around an indistinguishable target.
            if (!hints.freeAt(pos.col, pos.row, width)) continue;
            hints.labels[hints.count] = .{ .col = @intCast(pos.col), .row = @intCast(pos.row), .code = undefined, .len = 0, .link = i };
            hints.count += 1;
            hints.shown.set(i);
            if (hints.count == @min(capacity, remaining)) break;
        }
        hints.shown_count += hints.count;

        // Expand only as many prefixes as this batch needs. Ten links, for
        // example, can use eight one-key labels and two with a shared prefix.
        while (width > 1 and hints.count <= capacity / alphabet.len) {
            width -= 1;
            capacity /= alphabet.len;
        }
        const base = capacity / alphabet.len;
        const expanded = ((hints.count -| base) + alphabet.len - 2) / (alphabet.len - 1);
        const short = if (width == 1) 0 else base - expanded;
        for (hints.labels[0..hints.count], 0..) |*label, i| {
            label.len = if (i < short) width - 1 else width;
            var index = if (i < short) i else short * alphabet.len + i - short;
            var digit = label.len;
            while (digit > 0) {
                digit -= 1;
                label.code[digit] = alphabet[index % alphabet.len];
                index /= alphabet.len;
            }
        }
    }

    pub fn more(hints: *const Hints) bool {
        return hints.count < hints.links.len;
    }

    fn freeAt(hints: *const Hints, col: usize, row: usize, width: usize) bool {
        for (hints.labels[0..hints.count]) |label| {
            if (label.row == row and label.col < col + width and col < label.col + width)
                return false;
        }
        return true;
    }
};

// ====================================================================================================
// Private Functions
// ====================================================================================================

fn cells(geometry: tiling.Geometry, size: terminal.Size, top: i64, pan_x: u32, link: document.Link) Rect {
    const left: f64 = @floatFromInt(geometry.pageLeft(link.page, pan_x));
    const y: f64 = @floatFromInt(geometry.pageTop(link.page) - top);
    const width: f64 = @floatFromInt(geometry.pageWidth(link.page));
    const height: f64 = @floatFromInt(geometry.pageHeight(link.page));
    const cell_w: f64 = @floatFromInt(size.cell_width);
    const cell_h: f64 = @floatFromInt(size.cell_height);
    const last_col: f64 = @floatFromInt(size.cols - 1);
    const last_row: f64 = @floatFromInt(size.rows - 2);
    return .{
        .x0 = @intFromFloat(std.math.clamp(@floor((left + width * link.area.x0) / cell_w), 0, last_col)),
        .y0 = @intFromFloat(std.math.clamp(@floor((y + height * link.area.y0) / cell_h), 0, last_row)),
        .x1 = @intFromFloat(std.math.clamp(@ceil((left + width * link.area.x1) / cell_w) - 1, 0, last_col)),
        .y1 = @intFromFloat(std.math.clamp(@ceil((y + height * link.area.y1) / cell_h) - 1, 0, last_row)),
    };
}

// ====================================================================================================
// Tests
// ====================================================================================================

test "a link sharing a cell waits for Tab without hiding later links that fit" {
    const size: terminal.Size = .{ .cols = 20, .rows = 6, .cell_width = 10, .cell_height = 20 };
    const geometry: tiling.Geometry = .init(&.{.{ .width = 200, .height = 200 }}, &.{0}, size, 1);
    const anchor: tiling.Anchor = .{ .page = 0, .y = 0 };
    const shared: document.Rect = .{ .x0 = 0, .y0 = 0, .x1 = 0.03, .y1 = 0.05 };
    const other: document.Rect = .{ .x0 = 0.5, .y0 = 0, .x1 = 0.6, .y1 = 0.05 };
    const here: document.Link.Target = .{ .position = .{ .page = 0, .x = null, .y = null } };
    var hints: Hints = .{ .links = &.{
        .{ .page = 0, .area = shared, .target = here },
        .{ .page = 0, .area = shared, .target = here },
        .{ .page = 0, .area = other, .target = here },
    } };
    hints.show(geometry, size, anchor, 0);
    try std.testing.expectEqual(2, hints.count);
    try std.testing.expectEqual(9, hints.labels[1].col);
    try std.testing.expect(hints.more());
    hints.show(geometry, size, anchor, 0);
    try std.testing.expectEqual(1, hints.count);
    try std.testing.expectEqual(1, hints.labels[0].link);
    hints.show(geometry, size, anchor, 0);
    try std.testing.expectEqual(2, hints.count);
}

test "zoomed adjacent links leave both titles clear after clipping and panning" {
    const size: terminal.Size = .{ .cols = 16, .rows = 6, .cell_width = 10, .cell_height = 20 };
    const geometry: tiling.Geometry = .init(&.{.{ .width = 160, .height = 160 }}, &.{0}, size, 2);
    const here: document.Link.Target = .{ .position = .{ .page = 0, .x = null, .y = null } };
    var hints: Hints = .{ .links = &.{
        .{ .page = 0, .area = .{ .x0 = 0, .x1 = 0.28, .y0 = 0.14, .y1 = 0.17 }, .target = here },
        .{ .page = 0, .area = .{ .x0 = 0.28, .x1 = 0.38, .y0 = 0.14, .y1 = 0.17 }, .target = here },
    } };
    hints.show(geometry, size, .{ .page = 0, .y = 0 }, 40);
    try std.testing.expectEqual(2, hints.count);
    // The first title runs off the left edge. The second starts in the
    // same cell the first one ends in. Both touch row 2, columns 0..8.
    for (hints.labels[0..hints.count]) |label| {
        try std.testing.expect(label.row != 2 or label.col > 8);
        try std.testing.expect(label.row < size.rows - 1);
    }
}
