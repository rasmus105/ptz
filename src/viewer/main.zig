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
const tiling = @import("tiling.zig");

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
const status_len_max = 512;

// ====================================================================================================
// Types
// ====================================================================================================

pub const Tile = tiling.Tile;
pub const Slice = tiling.Slice;
pub const Anchor = tiling.Anchor;
pub const tiles_max = tiling.tiles_max;
pub const tile_bytes_max = tiling.tile_bytes_max;

/// A loaded version of the document.
pub const Document = struct {
    /// Identifies this load; tiles carry it so that tiles of another load
    /// are never mistaken for current ones.
    generation: u32,
    page_sizes: []const pdf.Size,
    /// Each page's distance from the first page's top, in points, without
    /// the gaps between pages: the running sum of page heights. Computed
    /// once per load, so layouts at any zoom are cheap.
    page_offsets: []const f64,
};

pub const Event = union(enum) {
    key: terminal.Key,
    resize: terminal.Size,
    /// A document was (re)loaded. Its slices must stay valid until the next
    /// `document` event. The position is kept, clamped to the document.
    document: Document,
    /// Something to tell the user, e.g. that a reload failed.
    message: []const u8,
};

/// What the shell should do after an event.
pub const Effect = enum { none, quit, reload };

/// The status line: `left` is truncated to make room for `right`.
pub const Status = struct {
    left: []const u8,
    right: []const u8,
    /// Truncate `left` at its start instead of its end, e.g. to show where
    /// typing happens on the command line.
    keep_end: bool,
};

/// What to draw: the visible parts of tiles, the tiles to have ready, and
/// the status line.
pub const Frame = struct {
    tiles: tiling.Tiles,
    status_buffer: [status_len_max]u8,
    status_left_len: u32,
    status_right_len: u32,
    status_keep_end: bool,

    pub fn slices(frame: *const Frame) []const Slice {
        return frame.tiles.slices();
    }

    /// Most urgent first: the visible tiles, then those of the next screen
    /// down, then of the screen above.
    pub fn wanted(frame: *const Frame) []const Tile {
        return frame.tiles.wanted();
    }

    pub fn status(frame: *const Frame) Status {
        const left = frame.status_buffer[0..frame.status_left_len];
        return .{
            .left = left,
            .right = frame.status_buffer[left.len..][0..frame.status_right_len],
            .keep_end = frame.status_keep_end,
        };
    }
};

pub const State = struct {
    file_name: []const u8,
    size: terminal.Size,
    document: Document,
    /// Derived from the document, size and zoom; see `relayout`.
    geometry: tiling.Geometry,
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

    /// Starts at `page`, counting from 1, once the document is loaded.
    pub fn init(file_name: []const u8, size: terminal.Size, dark: bool, page: u32) State {
        var state: State = .{
            .file_name = file_name,
            .size = size,
            .document = .{ .generation = 0, .page_sizes = &.{}, .page_offsets = &.{} },
            .geometry = undefined,
            .anchor = .{ .page = page -| 1, .y = 0 },
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
        state.relayout();
        return state;
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
                state.relayout();
            },
            .document => |document| {
                std.debug.assert(document.page_offsets.len == document.page_sizes.len);
                std.debug.assert(document.generation > state.document.generation);
                // Clears e.g. an earlier "reload failed".
                state.message_len = 0;
                state.document = document;
                state.relayout();
            },
            .message => |text| {
                state.message_len = @intCast(@min(text.len, message_len_max));
                @memcpy(state.message_buffer[0..state.message_len], text[0..state.message_len]);
            },
        }
        return .none;
    }

    pub fn layout(state: *const State, frame: *Frame) void {
        tiling.layout(state.geometry, state.anchor, state.pan_x, .{
            .generation = state.document.generation,
            .dark = state.dark,
        }, &frame.tiles);
        state.writeStatus(frame);
    }

    fn apply(state: *State, action: keymap.Action) Effect {
        const view_height: i64 = state.geometry.view_height;
        switch (action) {
            .scroll_lines => |n| state.scrollBy(@as(i64, n) * line_rows * state.size.cell_height),
            .scroll_half_screens => |n| state.scrollBy(@divTrunc(n * view_height, 2)),
            .scroll_screens => |n| state.scrollBy(n * view_height),
            .pan_lines => |n| {
                const pan = @as(i64, state.pan_x) + @as(i64, n) * line_rows * state.size.cell_width;
                state.pan_x = @intCast(std.math.clamp(pan, 0, state.geometry.panMax()));
            },
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

    fn scrollBy(state: *State, delta: i64) void {
        if (state.document.page_sizes.len == 0) return;
        state.anchor = state.geometry.anchorAt(state.geometry.offsetOf(state.anchor) + delta);
    }

    fn gotoPage(state: *State, page: i64) void {
        const pages = state.document.page_sizes.len;
        if (pages == 0) return;
        const anchor: Anchor = .{ .page = @intCast(std.math.clamp(page, 0, @as(i64, @intCast(pages - 1)))), .y = 0 };
        state.anchor = state.geometry.anchorAt(state.geometry.offsetOf(anchor));
        // Keep the page in view horizontally: a narrower page than the last
        // may lie entirely outside the current pan.
        const geometry = state.geometry;
        const width = geometry.pageWidth(anchor.page);
        const left = (geometry.content_width - width) / 2;
        state.pan_x = if (width <= geometry.view_width)
            @min((left + width / 2) -| geometry.view_width / 2, geometry.panMax())
        else
            std.math.clamp(state.pan_x, left, left + width - geometry.view_width);
    }

    fn setZoom(state: *State, zoom: f32) void {
        const half_width = @as(f32, @floatFromInt(state.geometry.view_width)) / 2;
        // Relayout clamps pan to the new bounds, so save the old centre first.
        const old_centre = @as(f32, @floatFromInt(state.pan_x)) + half_width;
        const old_scale = state.geometry.scale;
        state.zoom = std.math.clamp(zoom, zoom_min, zoom_max);
        state.relayout();
        const centre = old_centre * (state.geometry.scale / old_scale);
        const pan_max: f32 = @floatFromInt(state.geometry.panMax());
        state.pan_x = @intFromFloat(std.math.clamp(centre - half_width, 0, pan_max));
    }

    /// Recomputes the geometry after the document, size or zoom changed, and
    /// keeps the position inside the document.
    fn relayout(state: *State) void {
        state.geometry = .init(state.document.page_sizes, state.document.page_offsets, state.size, state.zoom);
        const pages = state.document.page_sizes.len;
        if (pages == 0) return;
        if (state.anchor.page >= pages) state.anchor = .{ .page = @intCast(pages - 1), .y = 0 };
        state.anchor = state.geometry.anchorAt(state.geometry.offsetOf(state.anchor));
        state.pan_x = @min(state.pan_x, state.geometry.panMax());
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
        const extra = words.next() != null;
        if (std.mem.indexOfNone(u8, name, "0123456789") == null) {
            // Too many digits just means the last page, as with `G`.
            const page = std.fmt.parseInt(u32, name, 10) catch std.math.maxInt(u32);
            return state.apply(.{ .goto_page = page });
        }
        if (std.mem.eql(u8, name, "q") or std.mem.eql(u8, name, "quit")) return .quit;
        if (std.mem.eql(u8, name, "reload")) return .reload;
        if (std.mem.eql(u8, name, "dark")) return state.apply(.toggle_dark);
        if (std.mem.eql(u8, name, "zoom")) {
            // Plain decimals only: parseFloat also takes `nan` and hex.
            const text = argument orelse "";
            const valid = !extra and text.len > 0 and std.mem.indexOfNone(u8, text, "0123456789.") == null;
            const percent = if (valid) std.fmt.parseFloat(f32, text) catch 0 else 0;
            if (percent <= 0) return state.update(.{ .message = "usage: zoom <percent>" });
            state.setZoom(percent / 100);
            return .none;
        }
        return state.update(.{ .message = "unknown command" });
    }

    /// The last row: the command line while it is open, otherwise any
    /// message or else the file name, with the position on the right.
    fn writeStatus(state: *const State, frame: *Frame) void {
        var writer: std.Io.Writer = .fixed(&frame.status_buffer);
        frame.status_keep_end = state.command_open;
        if (state.command_open) {
            writer.print(":{s}", .{state.command_buffer[0..state.command_len]}) catch {};
            frame.status_left_len = @intCast(writer.end);
            frame.status_right_len = 0;
            return;
        }
        const message = state.message_buffer[0..state.message_len];
        writer.writeAll(if (message.len > 0) message else state.file_name) catch {};
        frame.status_left_len = @intCast(writer.end);
        const pages = state.document.page_sizes.len;
        if (state.document.generation == 0) {
            writer.writeAll("loading...") catch {};
        } else if (pages == 0) {
            writer.writeAll("no pages") catch {};
        } else {
            writer.print("{d}/{d}  {d}%{s}", .{
                state.anchor.page + 1,
                pages,
                @as(u32, @intFromFloat(@round(state.zoom * 100))),
                if (state.dark) "  dark" else "",
            }) catch {};
        }
        frame.status_right_len = @intCast(writer.end - frame.status_left_len);
    }
};

// ====================================================================================================
// Tests
// ====================================================================================================

test {
    _ = keymap;
    _ = tiling;
}

const test_size: terminal.Size = .{ .cols = 80, .rows = 25, .cell_width = 10, .cell_height = 20 };
/// An 800x480 px view; A4 pages fit to 800 px wide are about 1132 px tall.
const test_pages: [3]pdf.Size = @splat(.{ .width = 595, .height = 842 });
const test_offsets = [_]f64{ 0, 842, 2 * 842 };

const TestViewer = struct {
    state: State,

    fn init(viewer: *TestViewer) void {
        viewer.state = .init("doc.pdf", test_size, false, 1);
        _ = viewer.state.update(.{ .document = .{ .generation = 1, .page_sizes = &test_pages, .page_offsets = &test_offsets } });
    }

    fn feed(viewer: *TestViewer, keys: []const u8) Effect {
        var effect: Effect = .none;
        for (keys) |byte| effect = viewer.state.update(.{ .key = terminal.Key.decode(&.{byte}).?.key });
        return effect;
    }
};

test "scrolling is clamped to the document" {
    var viewer: TestViewer = undefined;
    viewer.init();
    _ = viewer.feed("k");
    try std.testing.expectEqual(Anchor{ .page = 0, .y = 0 }, viewer.state.anchor);
    _ = viewer.feed("G");
    try std.testing.expectEqual(2, viewer.state.anchor.page);
    // Scrolling past the end leaves the last page's bottom at the bottom of
    // the view.
    _ = viewer.feed("99j");
    const geometry = viewer.state.geometry;
    try std.testing.expectEqual(geometry.content_height - geometry.view_height, geometry.offsetOf(viewer.state.anchor));
}

test "page jumps and counts" {
    var viewer: TestViewer = undefined;
    viewer.init();
    _ = viewer.feed("l");
    try std.testing.expectEqual(Anchor{ .page = 1, .y = 0 }, viewer.state.anchor);
    _ = viewer.feed("gg");
    try std.testing.expectEqual(0, viewer.state.anchor.page);
    _ = viewer.feed("3G");
    try std.testing.expectEqual(2, viewer.state.anchor.page);
    _ = viewer.feed("2h");
    try std.testing.expectEqual(0, viewer.state.anchor.page);
}

test "zooming keeps the position in the page and the centre of the view" {
    var viewer: TestViewer = undefined;
    viewer.init();
    _ = viewer.feed("lj");
    const before = viewer.state.anchor;
    _ = viewer.feed("++");
    try std.testing.expectEqual(before.page, viewer.state.anchor.page);
    try std.testing.expectApproxEqAbs(before.y, viewer.state.anchor.y, 0.5);
    try std.testing.expectApproxEqAbs(1.5625, viewer.state.zoom, 0.0001);
    // Centred: the view's 400 px middle maps to 625 px, so pan is 225.
    try std.testing.expectEqual(225, viewer.state.pan_x);
    _ = viewer.feed("=");
    try std.testing.expectEqual(1, viewer.state.zoom);
    try std.testing.expectEqual(0, viewer.state.pan_x);
}

test "zooming out preserves the horizontal centre until it reaches a boundary" {
    for ([_]struct { pan: u32, expected: u32 }{
        .{ .pan = 0, .expected = 0 },
        .{ .pan = 400, .expected = 240 },
        .{ .pan = 800, .expected = 480 },
    }) |case| {
        var viewer: TestViewer = undefined;
        viewer.init();
        _ = viewer.feed(":zoom 200\r");
        viewer.state.pan_x = case.pan;
        _ = viewer.feed("-");
        try std.testing.expectEqual(case.expected, viewer.state.pan_x);
    }
}

test "page navigation at minimum zoom fits a one-pixel-wide view" {
    var viewer: TestViewer = undefined;
    viewer.init();
    _ = viewer.state.update(.{ .resize = .{ .cols = 1, .rows = 2, .cell_width = 1, .cell_height = 1 } });
    _ = viewer.feed(":zoom 25\rG");
    var frame: Frame = undefined;
    viewer.state.layout(&frame);
    try std.testing.expectEqual(2, viewer.state.anchor.page);
    try std.testing.expectEqual(0, viewer.state.pan_x);
    try std.testing.expectEqual(1, frame.slices().len);
    try std.testing.expectEqual(1, frame.slices()[0].width);
    try std.testing.expectEqual(0, frame.slices()[0].x);
}

test "command line" {
    var viewer: TestViewer = undefined;
    viewer.init();
    _ = viewer.feed(":3\r");
    try std.testing.expectEqual(2, viewer.state.anchor.page);
    try std.testing.expect(!viewer.state.command_open);
    _ = viewer.feed(":zoom 50\r");
    try std.testing.expectEqual(0.5, viewer.state.zoom);
    try std.testing.expectEqual(.reload, viewer.feed(":reload\r"));
    try std.testing.expectEqual(.quit, viewer.feed(":q\r"));

    _ = viewer.feed(":nope\r");
    var frame: Frame = undefined;
    viewer.state.layout(&frame);
    try std.testing.expectEqualStrings("unknown command", frame.status().left);
    for ([_][]const u8{ ":zoom -5\r", ":zoom nan\r", ":zoom 0x10\r", ":zoom 50 extra\r" }) |keys| {
        _ = viewer.feed(keys);
        try std.testing.expectEqual(0.5, viewer.state.zoom);
    }
    _ = viewer.feed(":99999999999\r");
    try std.testing.expectEqual(2, viewer.state.anchor.page);
    // Backspace removes whole characters, then closes the empty line.
    _ = viewer.state.update(.{ .key = .{ .char = ':' } });
    _ = viewer.state.update(.{ .key = .{ .char = 0xe9 } });
    _ = viewer.state.update(.{ .key = .backspace });
    try std.testing.expectEqual(0, viewer.state.command_len);
    _ = viewer.state.update(.{ .key = .backspace });
    try std.testing.expect(!viewer.state.command_open);
}

test "a reload keeps the position, clamped to the new page count" {
    var viewer: TestViewer = undefined;
    viewer.init();
    _ = viewer.feed("G");
    _ = viewer.state.update(.{ .document = .{ .generation = 2, .page_sizes = test_pages[0..1], .page_offsets = test_offsets[0..1] } });
    try std.testing.expectEqual(0, viewer.state.anchor.page);
}

test "jumping to a narrower page brings it into view" {
    const pages = [_]pdf.Size{ .{ .width = 2000, .height = 100 }, .{ .width = 200, .height = 100 } };
    const offsets = [_]f64{ 0, 100 };
    var state: State = .init("doc.pdf", test_size, false, 1);
    _ = state.update(.{ .document = .{ .generation = 1, .page_sizes = &pages, .page_offsets = &offsets } });
    // At 800% the narrow page spans 2880..3520 px of 6400; pan to the far
    // right of the wide page (5600..6400), then jump to the narrow one.
    for (":zoom 800\r") |byte| _ = state.update(.{ .key = terminal.Key.decode(&.{byte}).?.key });
    state.pan_x = state.geometry.panMax();
    _ = state.update(.{ .key = .{ .char = 'l' } });
    var frame: Frame = undefined;
    state.layout(&frame);
    for (frame.slices()) |slice| {
        if (slice.tile.page == 1) break;
    } else return error.TestUnexpectedResult;
}

test "status line" {
    var frame: Frame = undefined;
    var state: State = .init("doc.pdf", test_size, false, 1);
    state.layout(&frame);
    try std.testing.expectEqualStrings("loading...", frame.status().right);
    _ = state.update(.{ .document = .{ .generation = 1, .page_sizes = &.{}, .page_offsets = &.{} } });
    state.layout(&frame);
    try std.testing.expectEqualStrings("no pages", frame.status().right);
    // Messages still show without pages.
    _ = state.update(.{ .message = "hello" });
    state.layout(&frame);
    try std.testing.expectEqualStrings("hello", frame.status().left);
}

test "a window with no room for pages draws nothing and doesn't crash" {
    var viewer: TestViewer = undefined;
    viewer.init();
    _ = viewer.state.update(.{ .resize = .{ .cols = 10, .rows = 1, .cell_width = 10, .cell_height = 20 } });
    _ = viewer.feed("jjGk");
    var frame: Frame = undefined;
    viewer.state.layout(&frame);
    try std.testing.expectEqual(0, frame.slices().len);
}

test "the first page applies once the document arrives" {
    var state: State = .init("doc.pdf", test_size, false, 3);
    _ = state.update(.{ .document = .{ .generation = 1, .page_sizes = &test_pages, .page_offsets = &test_offsets } });
    try std.testing.expectEqual(2, state.anchor.page);
}

test "zooming beyond the maximum keeps the horizontal position" {
    var viewer: TestViewer = undefined;
    viewer.init();
    _ = viewer.state.update(.{ .resize = .{ .cols = 40, .rows = 25, .cell_width = 10, .cell_height = 20 } });
    _ = viewer.feed(":zoom 800\r");
    viewer.state.pan_x = 12;
    _ = viewer.feed("+");
    try std.testing.expectEqual(12, viewer.state.pan_x);
}
