// std
const std = @import("std");

// project
const document = @import("../document/main.zig");
const viewer = @import("../viewer/main.zig");

// ====================================================================================================
// Types
// ====================================================================================================

pub const Step = union(enum) { more, found: u32, missing };

/// The renderer supplies one page at a time so a new request can interrupt a
/// scan between engine calls. A lap splits the origin page at the starting
/// position and visits every match exactly once.
pub const Scan = struct {
    request: viewer.search.Request,
    page: u32,
    wrapped: bool = false,
    incomplete: bool = false,
    returning: bool = false,
    second_lap: bool = false,
    remaining: u32,
    seen: u32 = 0,

    pub fn init(request: viewer.search.Request) Scan {
        return .{ .request = request, .page = request.page, .remaining = @max(1, request.count) };
    }

    pub fn advance(scan: *Scan, parts: []const document.MatchPart, page_count: u32, incomplete: bool) Step {
        if (page_count == 0 or scan.page >= page_count) return .missing;
        scan.incomplete = scan.incomplete or incomplete;
        if (scan.request.after == null) {
            var nearest: ?u32 = null;
            var best = if (scan.request.backward) -std.math.inf(f32) else std.math.inf(f32);
            const from_viewport = scan.page == scan.request.page and !scan.returning;
            for (0..parts.len) |offset| {
                const index = if (scan.request.backward) parts.len - offset - 1 else offset;
                const part = parts[index];
                if (!part.first) continue;
                // Only the starting page needs a geometric starting point.
                // Pages entered from either end follow document reading order.
                if (!from_viewport) {
                    nearest = @intCast(index);
                    break;
                }
                const y = (part.area.y0 + part.area.y1) / 2;
                if (if (scan.request.backward) y >= scan.request.y else y <= scan.request.y) continue;
                // Equal-y hits keep the first in the direction of travel.
                if (if (scan.request.backward) y > best else y < best) {
                    nearest = @intCast(index);
                    best = y;
                }
            }
            if (nearest) |index| {
                scan.remaining -= 1;
                if (scan.remaining == 0) return .{ .found = index };
                // The rest of a count behaves exactly like repeats from this hit.
                scan.request.page = scan.page;
                scan.request.after = index;
                scan.returning = false;
            } else if (scan.returning) return .missing;
        }
        while (true) {
            if (scan.request.after != null) for (0..parts.len) |offset| {
                const index = if (scan.request.backward) parts.len - offset - 1 else offset;
                const part = parts[index];
                if (!part.first) continue;
                if (scan.page == scan.request.page) {
                    const after = scan.request.after.?;
                    const eligible = if (scan.request.backward) index < after else index > after;
                    if (eligible == scan.returning) continue;
                }
                scan.remaining -= 1;
                if (scan.remaining == 0) return .{ .found = @intCast(index) };
                scan.seen += 1;
            };
            if (scan.page != scan.request.page or !scan.returning) break;
            if (scan.seen == 0 or scan.second_lap) return .missing;
            // Whole laps leave the cursor at the same match. Start the last
            // partial lap on this already-loaded origin page.
            scan.remaining = (scan.remaining - 1) % scan.seen + 1;
            scan.second_lap = true;
            scan.seen = 0;
            scan.returning = false;
        }
        if (scan.request.backward) {
            if (scan.page == 0) {
                scan.page = page_count - 1;
                scan.wrapped = true;
            } else scan.page -= 1;
        } else if (scan.page == page_count - 1) {
            scan.page = 0;
            scan.wrapped = true;
        } else scan.page += 1;
        scan.returning = scan.page == scan.request.page;
        return .more;
    }
};

// ====================================================================================================
// Tests
// ====================================================================================================

test "large backward counts wrap, omit continuation parts, and revisit the origin" {
    const parts = [_]document.MatchPart{
        .{ .area = .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 0.2 }, .first = true },
        .{ .area = .{ .x0 = 0, .y0 = 0.2, .x1 = 1, .y1 = 0.4 }, .first = false },
        .{ .area = .{ .x0 = 0, .y0 = 0.8, .x1 = 1, .y1 = 1 }, .first = true },
    };
    var scan = Scan.init(.{ .id = 1, .query = undefined, .page = 0, .y = 0, .after = 0, .backward = true, .count = 3_000_000_002 });
    // Order is page 1, then the last and first hits of page 0.
    for (0..5) |_| {
        const step = scan.advance(if (scan.page == 1) parts[0..1] else &parts, 2, false);
        if (step == .more) continue;
        try std.testing.expect(scan.wrapped and !scan.incomplete);
        try std.testing.expectEqual(0, scan.page);
        try std.testing.expectEqual(Step{ .found = 2 }, step);
        return;
    }
    return error.TestUnexpectedResult;
}

test "a match above the origin is reachable after a failed page" {
    const parts = [_]document.MatchPart{.{ .area = .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 0.1 }, .first = true }};
    var scan = Scan.init(.{ .id = 1, .query = undefined, .page = 0, .y = 0.6, .after = null, .backward = false, .count = 1 });
    try std.testing.expectEqual(Step.more, scan.advance(&parts, 2, false));
    try std.testing.expectEqual(Step.more, scan.advance(&.{}, 2, true));
    try std.testing.expectEqual(Step{ .found = 0 }, scan.advance(&parts, 2, false));
    try std.testing.expect(scan.wrapped and scan.incomplete);
}

test "viewport search picks the nearest column then follows text order across laps" {
    const parts = [_]document.MatchPart{
        .{ .area = .{ .x0 = 0, .x1 = 0.2, .y0 = 0.8, .y1 = 1 }, .first = true },
        .{ .area = .{ .x0 = 0.5, .x1 = 1, .y0 = 0.1, .y1 = 0.3 }, .first = true },
        .{ .area = .{ .x0 = 0.5, .x1 = 1, .y0 = 0.55, .y1 = 0.65 }, .first = true },
        .{ .area = .{ .x0 = 0.5, .x1 = 1, .y0 = 0.75, .y1 = 0.85 }, .first = true },
    };
    for ([_]u32{ 1, 2, 3, 7, 100 }) |count| {
        var scan = Scan.init(.{ .id = 1, .query = undefined, .page = 0, .y = 0.5, .after = null, .backward = false, .count = count });
        var found = scan.advance(&parts, 1, true);
        for (0..2) |_| {
            if (found != .more) break;
            found = scan.advance(&parts, 1, false);
        }
        try std.testing.expectEqual(Step{ .found = (2 + count - 1) % 4 }, found);
        try std.testing.expect(scan.incomplete);
        try std.testing.expectEqual(count >= 3, scan.wrapped);
    }
}

test "a page entered during search starts from its first match in reading order" {
    const parts = [_]document.MatchPart{
        .{ .area = .{ .x0 = 0, .x1 = 0.2, .y0 = 0.6, .y1 = 0.8 }, .first = true },
        .{ .area = .{ .x0 = 0.5, .x1 = 1, .y0 = 0.1, .y1 = 0.3 }, .first = true },
    };
    var forward = Scan.init(.{ .id = 1, .query = undefined, .page = 0, .y = 0.5, .after = null, .backward = false, .count = 1 });
    try std.testing.expectEqual(Step.more, forward.advance(&.{}, 2, false));
    try std.testing.expectEqual(Step{ .found = 0 }, forward.advance(&parts, 2, false));
    var backward = Scan.init(.{ .id = 2, .query = undefined, .page = 1, .y = 0.5, .after = null, .backward = true, .count = 1 });
    try std.testing.expectEqual(Step.more, backward.advance(&.{}, 2, false));
    try std.testing.expectEqual(Step{ .found = 1 }, backward.advance(&parts, 2, false));
}
