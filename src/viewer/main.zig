//! The viewer's logic, free of I/O: what the viewer shows, how keys change
//! it, and what to draw. Feeding the same events always gives the same
//! frames, so all of it is tested without a terminal or a document.
//!
//! The shell around it (`app/`) turns terminal input and render results into
//! `Event`s, performs the returned `Effect`, and draws `Frame`s.
//!
//! Pages are laid out top to bottom with a gap, scaled to the same scale and
//! centred. The scroll position is kept as a point in a page (`Anchor`), so it
//! survives zooming, resizing and reloads that change page sizes.

// std
const std = @import("std");

// project
const pdf = @import("../pdf/main.zig");
const terminal = @import("../terminal/main.zig");

// local
const keymap = @import("keymap.zig");
const layout_ = @import("layout.zig");

// ====================================================================================================
// Constants
// ====================================================================================================

/// Zoom is relative to fitting the widest page to the window width.
const zoom_step = 1.25;
const zoom_min = 0.25;
const zoom_max = 8;
/// Rows scrolled by `j` and `k`.
const line_rows = 2;
const command_len_max = 128;
const message_len_max = 160;

// ====================================================================================================
// Types
// ====================================================================================================

pub const Action = keymap.Action;
pub const Frame = layout_.Frame;
pub const Tile = layout_.Tile;
pub const Slice = layout_.Slice;
pub const Anchor = layout_.Anchor;
pub const wanted_max = layout_.wanted_max;

pub const Event = union(enum) {
    key: terminal.Key,
    resize: terminal.Size,
    /// A document was (re)loaded. The page sizes must stay valid until the
    /// next `document` event. The position is kept, clamped to the document.
    document: []const pdf.Size,
    /// Something to tell the user, e.g. that a reload failed.
    message: []const u8,
};

/// What the shell should do after an event.
pub const Effect = enum { none, quit, reload };

pub const State = struct {
    file_name: []const u8,
    size: terminal.Size,
    /// Empty until the document is loaded.
    page_sizes: []const pdf.Size,
    /// Incremented on every `document` event, so tiles of an older version
    /// of the document are never mistaken for current ones.
    generation: u32,
    anchor: Anchor,
    /// Horizontal scroll in pixels when the pages are wider than the window.
    pan_x: u32,
    /// 1 fits the widest page to the window width.
    zoom: f32,
    dark: bool,
    keymap: keymap.KeyMap,
    /// Whether the `:` command line is open, and what has been typed.
    command_open: bool,
    command_buffer: [command_len_max]u8,
    command_len: u32,
    message_buffer: [message_len_max]u8,
    message_len: u32,

    pub fn init(file_name: []const u8, size: terminal.Size, dark: bool) State {
        return .{
            .file_name = file_name,
            .size = size,
            .page_sizes = &.{},
            .generation = 0,
            .anchor = .{ .page = 0, .y = 0 },
            .pan_x = 0,
            .zoom = 1,
            .dark = dark,
            .keymap = .{},
            .command_open = false,
            .command_buffer = undefined,
            .command_len = 0,
            .message_buffer = undefined,
            .message_len = 0,
        };
    }

    pub fn update(state: *State, event: Event) Effect {
        switch (event) {
            .key => |key| {
                state.message_len = 0;
                if (state.command_open) return state.editCommand(key);
                const action = state.keymap.feed(key) orelse return .none;
                return state.apply(action);
            },
            .resize => |size| {
                state.size = size;
                state.clamp();
            },
            .document => |page_sizes| {
                state.page_sizes = page_sizes;
                state.generation += 1;
                state.clamp();
            },
            .message => |text| {
                state.message_len = @intCast(@min(text.len, message_len_max));
                @memcpy(state.message_buffer[0..state.message_len], text[0..state.message_len]);
            },
        }
        return .none;
    }

    pub fn apply(state: *State, action: Action) Effect {
        const geometry = state.computeGeometry();
        switch (action) {
            .scroll_lines => |n| state.scrollBy(@as(i64, n) * line_rows * state.size.cell_height),
            .scroll_half_screens => |n| state.scrollBy(@divTrunc(@as(i64, n) * geometry.view_height, 2)),
            .scroll_screens => |n| state.scrollBy(@as(i64, n) * geometry.view_height),
            .pan_lines => |n| state.panBy(@as(i64, n) * line_rows * state.size.cell_width),
            .move_pages => |n| state.gotoPage(@as(i64, state.anchor.page) + n),
            .goto_page => |page| state.gotoPage(@as(i64, page) - 1),
            .goto_last_page => state.gotoPage(std.math.maxInt(i32)),
            .zoom_steps => |n| state.setZoom(state.zoom * std.math.pow(f32, zoom_step, @floatFromInt(n))),
            .zoom_fit_width => state.setZoom(1),
            .toggle_dark => state.dark = !state.dark,
            .open_command_line => {
                state.command_open = true;
                state.command_len = 0;
            },
            .quit => return .quit,
        }
        return .none;
    }

    pub fn layout(state: *const State, frame: *Frame) void {
        layout_.layout(state.computeGeometry(), state.anchor, state.pan_x, .{
            .generation = state.generation,
            .dark = state.dark,
        }, frame);
        state.writeStatus(frame);
    }

    fn computeGeometry(state: *const State) layout_.Geometry {
        return .init(state.page_sizes, state.size, state.zoom);
    }

    fn scrollBy(state: *State, delta: i64) void {
        const geometry = state.computeGeometry();
        state.anchor = geometry.anchorAt(geometry.offsetOf(state.anchor) + delta);
    }

    fn panBy(state: *State, delta: i64) void {
        const pan_max = state.computeGeometry().panMax();
        state.pan_x = @intCast(std.math.clamp(@as(i64, state.pan_x) + delta, 0, pan_max));
    }

    fn gotoPage(state: *State, page: i64) void {
        if (state.page_sizes.len == 0) return;
        const last: i64 = @intCast(state.page_sizes.len - 1);
        const geometry = state.computeGeometry();
        const anchor: Anchor = .{ .page = @intCast(std.math.clamp(page, 0, last)), .y = 0 };
        state.anchor = geometry.anchorAt(geometry.offsetOf(anchor));
    }

    fn setZoom(state: *State, zoom: f32) void {
        const old_scale = state.computeGeometry().scale;
        state.zoom = std.math.clamp(zoom, zoom_min, zoom_max);
        const geometry = state.computeGeometry();
        if (state.page_sizes.len == 0) return;
        // Keep the horizontal centre of the view where it was.
        const half_width = @as(f32, @floatFromInt(geometry.view_width)) / 2;
        const centre = @as(f32, @floatFromInt(state.pan_x)) + half_width;
        const pan = centre * geometry.scale / old_scale - half_width;
        state.pan_x = @intFromFloat(std.math.clamp(pan, 0, @as(f32, @floatFromInt(geometry.panMax()))));
        state.clamp();
    }

    /// Keeps the anchor and pan inside the document after it or the window
    /// changed.
    fn clamp(state: *State) void {
        if (state.page_sizes.len == 0) return;
        const geometry = state.computeGeometry();
        if (state.anchor.page >= state.page_sizes.len) {
            state.anchor = .{ .page = @intCast(state.page_sizes.len - 1), .y = 0 };
        }
        state.anchor = geometry.anchorAt(geometry.offsetOf(state.anchor));
        state.pan_x = @min(state.pan_x, geometry.panMax());
    }

    fn editCommand(state: *State, key: terminal.Key) Effect {
        std.debug.assert(state.command_open);
        switch (key) {
            .char => |char| {
                var utf8: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(char, &utf8) catch return .none;
                if (state.command_len + len > command_len_max) return .none;
                @memcpy(state.command_buffer[state.command_len..][0..len], utf8[0..len]);
                state.command_len += len;
            },
            .backspace => {
                if (state.command_len == 0) {
                    state.command_open = false;
                } else {
                    // Drop the last whole character.
                    state.command_len -= 1;
                    while (state.command_len > 0 and state.command_buffer[state.command_len] & 0xc0 == 0x80) {
                        state.command_len -= 1;
                    }
                }
            },
            .escape, .ctrl => state.command_open = false,
            .enter => {
                state.command_open = false;
                const line = std.mem.trim(u8, state.command_buffer[0..state.command_len], " ");
                return state.runCommand(line);
            },
            else => {},
        }
        return .none;
    }

    /// Commands: `<page>`, `q`, `zoom <percent>`, `dark`, `reload`.
    fn runCommand(state: *State, line: []const u8) Effect {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const name = words.next() orelse return .none;
        const argument = words.next();
        if (std.fmt.parseInt(u32, name, 10)) |page| return state.apply(.{ .goto_page = page }) else |_| {}
        if (eql(name, "q") or eql(name, "quit")) return .quit;
        if (eql(name, "reload")) return .reload;
        if (eql(name, "dark")) return state.apply(.toggle_dark);
        if (eql(name, "zoom")) {
            const percent = std.fmt.parseFloat(f32, argument orelse "") catch
                return state.update(.{ .message = "usage: zoom <percent>" });
            state.setZoom(percent / 100);
            return .none;
        }
        return state.update(.{ .message = "unknown command" });
    }

    /// The last row: the command line while it is open, otherwise the file
    /// name and position, with any message in place of the file name.
    fn writeStatus(state: *const State, frame: *Frame) void {
        var writer: std.Io.Writer = .fixed(&frame.status_buffer);
        if (state.command_open) {
            writer.print(":{s}", .{state.command_buffer[0..state.command_len]}) catch {};
        } else if (state.page_sizes.len == 0) {
            writer.print("{s}  loading...", .{state.file_name}) catch {};
        } else {
            const left = if (state.message_len > 0) state.message_buffer[0..state.message_len] else state.file_name;
            writer.print("{s}  {d}/{d}  {d}%{s}", .{
                left,
                state.anchor.page + 1,
                state.page_sizes.len,
                @as(u32, @intFromFloat(@round(state.zoom * 100))),
                if (state.dark) "  dark" else "",
            }) catch {};
        }
        frame.status_len = @intCast(writer.end);
    }
};

// ====================================================================================================
// Private Functions
// ====================================================================================================

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ====================================================================================================
// Tests
// ====================================================================================================

test {
    _ = keymap;
    _ = layout_;
}

const test_size: terminal.Size = .{ .cols = 80, .rows = 25, .cell_width = 10, .cell_height = 20 };
/// An 800x480 px view; A4 pages fit to 800 px wide are about 1132 px tall.
const test_pages: [3]pdf.Size = @splat(.{ .width = 595, .height = 842 });

fn testState() State {
    var state: State = .init("doc.pdf", test_size, false);
    _ = state.update(.{ .document = &test_pages });
    return state;
}

fn feed(state: *State, keys: []const u8) Effect {
    var effect: Effect = .none;
    for (keys) |byte| effect = state.update(.{ .key = terminal.Key.decode(&.{byte}).key });
    return effect;
}

test "scrolling is clamped to the document" {
    var state = testState();
    _ = feed(&state, "k");
    try std.testing.expectEqual(Anchor{ .page = 0, .y = 0 }, state.anchor);
    _ = feed(&state, "G");
    try std.testing.expectEqual(2, state.anchor.page);
    // Scrolling past the end leaves the last page's bottom at the bottom of
    // the view.
    _ = feed(&state, "99j");
    const geometry = state.computeGeometry();
    try std.testing.expectEqual(geometry.contentHeight() - geometry.view_height, geometry.offsetOf(state.anchor));
}

test "page jumps and counts" {
    var state = testState();
    _ = feed(&state, "l");
    try std.testing.expectEqual(Anchor{ .page = 1, .y = 0 }, state.anchor);
    _ = feed(&state, "gg");
    try std.testing.expectEqual(0, state.anchor.page);
    _ = feed(&state, "3G");
    try std.testing.expectEqual(2, state.anchor.page);
    _ = feed(&state, "2h");
    try std.testing.expectEqual(0, state.anchor.page);
}

test "zooming keeps the position in the page" {
    var state = testState();
    _ = feed(&state, "lj");
    const before = state.anchor;
    _ = feed(&state, "++");
    try std.testing.expectEqual(before.page, state.anchor.page);
    try std.testing.expectApproxEqAbs(before.y, state.anchor.y, 0.5);
    try std.testing.expectApproxEqAbs(1.5625, state.zoom, 0.0001);
    _ = feed(&state, "=");
    try std.testing.expectEqual(1, state.zoom);
}

test "command line" {
    var state = testState();
    _ = feed(&state, ":3\r");
    try std.testing.expectEqual(2, state.anchor.page);
    try std.testing.expect(!state.command_open);
    _ = feed(&state, ":zoom 50\r");
    try std.testing.expectEqual(0.5, state.zoom);
    try std.testing.expectEqual(.reload, feed(&state, ":reload\r"));
    try std.testing.expectEqual(.quit, feed(&state, ":q\r"));

    _ = feed(&state, ":nope\r");
    var frame: Frame = undefined;
    state.layout(&frame);
    try std.testing.expect(std.mem.startsWith(u8, frame.status(), "unknown command"));
    // Backspace on an empty command line closes it.
    _ = feed(&state, ":x\x7f\x7f");
    try std.testing.expect(!state.command_open);
}

test "a reload keeps the position, clamped to the new page count" {
    var state = testState();
    _ = feed(&state, "G");
    _ = state.update(.{ .document = test_pages[0..1] });
    try std.testing.expectEqual(0, state.anchor.page);
    try std.testing.expectEqual(2, state.generation);
}
