//! Vim-style key bindings: turns key presses into viewer actions, handling
//! counts (`5j`, `12G`) and the two-key `gg`.

// std
const std = @import("std");

// project
const Key = @import("../terminal/main.zig").Key;

// ====================================================================================================
// Constants
// ====================================================================================================

/// Larger counts are clamped; no document needs more.
const count_max = 1_000_000;

// ====================================================================================================
// Types
// ====================================================================================================

pub const Action = union(enum) {
    /// Scroll by this many lines; negative is up.
    scroll_lines: i32,
    /// Scroll by this many half screens; negative is up.
    scroll_half_screens: i32,
    /// Scroll by this many screens; negative is up.
    scroll_screens: i32,
    /// Pan horizontally by this many lines; negative is left.
    pan_lines: i32,
    /// Move this many pages; negative is back.
    move_pages: i32,
    /// Go to this page, counting from 1.
    goto_page: u32,
    goto_last_page,
    /// Zoom in by this many steps; negative zooms out.
    zoom_steps: i32,
    zoom_fit_width,
    toggle_dark,
    open_command_line,
    quit,
};

pub const KeyMap = struct {
    count: ?u32 = null,
    pending_g: bool = false,

    /// Returns the action `key` completes, or null if it only starts or
    /// extends one (a count digit, the first `g`) or is unbound.
    pub fn feed(map: *KeyMap, key: Key) ?Action {
        if (map.pending_g) {
            map.pending_g = false;
            const count = map.takeCount();
            if (key == .char and key.char == 'g') return .{ .goto_page = count orelse 1 };
            return null;
        }
        if (key == .char) switch (key.char) {
            '1'...'9' => return map.appendDigit(@intCast(key.char - '0')),
            '0' => if (map.count != null) return map.appendDigit(0),
            'g' => {
                map.pending_g = true;
                return null;
            },
            else => {},
        };

        const count = map.takeCount();
        const n: i32 = @intCast(count orelse 1);
        return switch (key) {
            .char => |char| switch (char) {
                'j' => .{ .scroll_lines = n },
                'k' => .{ .scroll_lines = -n },
                'l' => .{ .move_pages = n },
                'h' => .{ .move_pages = -n },
                ' ' => .{ .scroll_screens = n },
                'G' => if (count) |page| .{ .goto_page = page } else .goto_last_page,
                '+' => .{ .zoom_steps = n },
                '-' => .{ .zoom_steps = -n },
                '=' => .zoom_fit_width,
                'i' => .toggle_dark,
                ':' => .open_command_line,
                'q' => .quit,
                else => null,
            },
            .ctrl => |letter| switch (letter) {
                'd' => .{ .scroll_half_screens = n },
                'u' => .{ .scroll_half_screens = -n },
                'f' => .{ .scroll_screens = n },
                'b' => .{ .scroll_screens = -n },
                'c' => .quit,
                else => null,
            },
            .down => .{ .scroll_lines = n },
            .up => .{ .scroll_lines = -n },
            .right => .{ .pan_lines = n },
            .left => .{ .pan_lines = -n },
            .page_down => .{ .scroll_screens = n },
            .page_up => .{ .scroll_screens = -n },
            .home => .{ .goto_page = 1 },
            .end => .goto_last_page,
            // Escape only cancels the count, which `takeCount` already did.
            else => null,
        };
    }

    fn appendDigit(map: *KeyMap, digit: u32) ?Action {
        std.debug.assert(digit <= 9);
        map.count = @min(count_max, (map.count orelse 0) * 10 + digit);
        return null;
    }

    fn takeCount(map: *KeyMap) ?u32 {
        defer map.count = null;
        return map.count;
    }
};

// ====================================================================================================
// Tests
// ====================================================================================================

fn expectActions(keys: []const Key, expected: []const ?Action) !void {
    std.debug.assert(keys.len == expected.len);
    var map: KeyMap = .{};
    for (keys, expected) |key, action| try std.testing.expectEqual(action, map.feed(key));
}

test "counts apply to the next action and then reset" {
    try expectActions(
        &.{ .{ .char = '1' }, .{ .char = '0' }, .{ .char = 'j' }, .{ .char = 'j' } },
        &.{ null, null, .{ .scroll_lines = 10 }, .{ .scroll_lines = 1 } },
    );
    try expectActions(
        &.{ .{ .char = '3' }, .{ .ctrl = 'u' }, .{ .char = '2' }, .{ .char = '-' } },
        &.{ null, .{ .scroll_half_screens = -3 }, null, .{ .zoom_steps = -2 } },
    );
}

test "G and gg go to a page, defaulting to the last and first" {
    try expectActions(&.{.{ .char = 'G' }}, &.{.goto_last_page});
    try expectActions(&.{ .{ .char = '4' }, .{ .char = '2' }, .{ .char = 'G' } }, &.{ null, null, .{ .goto_page = 42 } });
    try expectActions(&.{ .{ .char = 'g' }, .{ .char = 'g' } }, &.{ null, .{ .goto_page = 1 } });
    try expectActions(&.{ .{ .char = '7' }, .{ .char = 'g' }, .{ .char = 'g' } }, &.{ null, null, .{ .goto_page = 7 } });
}

test "an interrupted sequence does nothing and leaves no state behind" {
    // `g` followed by anything but `g` is dropped, count included.
    try expectActions(
        &.{ .{ .char = '5' }, .{ .char = 'g' }, .{ .char = 'x' }, .{ .char = 'j' } },
        &.{ null, null, null, .{ .scroll_lines = 1 } },
    );
    try expectActions(&.{ .{ .char = '9' }, .escape, .{ .char = 'k' } }, &.{ null, null, .{ .scroll_lines = -1 } });
    // A leading zero is not a count.
    try expectActions(&.{ .{ .char = '0' }, .{ .char = 'j' } }, &.{ null, .{ .scroll_lines = 1 } });
}

test "counts are clamped" {
    var map: KeyMap = .{};
    for (0..12) |_| _ = map.feed(.{ .char = '9' });
    try std.testing.expectEqual(Action{ .goto_page = count_max }, map.feed(.{ .char = 'G' }).?);
}
