//! Search work crosses the renderer boundary by value. The query identifies
//! reusable page matches, while each request identifies one navigation.

// std
const std = @import("std");

// project
const document = @import("../document/main.zig");

// local
const tiling = @import("tiling.zig");

// ====================================================================================================
// Constants
// ====================================================================================================

pub const query_max = 128;
pub const pages_max = 32;
pub const parts_max = 2048;

// ====================================================================================================
// Types
// ====================================================================================================

pub const Query = struct {
    generation: u32,
    id: u64,
    bytes: [query_max:0]u8,
    len: u8,

    pub fn text(query: *const Query) [:0]const u8 {
        return query.bytes[0..query.len :0];
    }
};

pub const Request = struct {
    query: Query,
    id: u64,
    page: u32,
    /// Start at the viewport's center, or immediately after/before a match.
    y: f32,
    after: ?u32,
    backward: bool,
    count: u32,
};

pub const Page = struct {
    query_id: u64,
    generation: u32,
    number: u32,
    parts: []document.MatchPart,
};

pub const Navigation = struct {
    id: u64,
    match: ?Match,
    wrapped: bool,
    incomplete: bool,

    pub const Match = struct { page: u32, part: u32, area: document.Rect };
};

pub const Viewport = struct {
    query: Query,
    pages: [pages_max]u32,
    len: usize,
};

pub const ScreenRect = struct { x: u32, y: u32, width: u32, height: u32 };

// ====================================================================================================
// Public API
// ====================================================================================================

pub fn screenRect(geometry: tiling.Geometry, top: i64, pan_x: u32, page: u32, area: document.Rect) ?ScreenRect {
    const left: f64 = @floatFromInt(geometry.pageLeft(page, pan_x));
    const y: f64 = @floatFromInt(geometry.pageTop(page) - top);
    const w: f64 = @floatFromInt(geometry.pageWidth(page));
    const h: f64 = @floatFromInt(geometry.pageHeight(page));
    const view_w: f64 = @floatFromInt(geometry.view_width);
    const view_h: f64 = @floatFromInt(geometry.view_height);
    const x0: u32 = @intFromFloat(std.math.clamp(@floor(left + w * area.x0), 0, view_w));
    const x1: u32 = @intFromFloat(std.math.clamp(@ceil(left + w * area.x1), 0, view_w));
    const y0: u32 = @intFromFloat(std.math.clamp(@floor(y + h * area.y0), 0, view_h));
    const y1: u32 = @intFromFloat(std.math.clamp(@ceil(y + h * area.y1), 0, view_h));
    if (x0 >= x1 or y0 >= y1) return null;
    return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
}
