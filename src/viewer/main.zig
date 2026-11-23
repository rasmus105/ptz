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
const document = @import("../document/main.zig");
const terminal = @import("../terminal/main.zig");

// local
const keymap = @import("keymap.zig");
const links = @import("links.zig");
pub const search = @import("search.zig");
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
const command_len_max = search.query_max;
const message_len_max = 160;
const status_len_max = 512;

// ====================================================================================================
// Types
// ====================================================================================================

pub const Tile = tiling.Tile;
pub const Slice = tiling.Slice;
pub const Anchor = tiling.Anchor;
pub const tiles_max = tiling.tiles_max;
pub const wanted_bytes_max = tiling.wanted_bytes_max;
pub const LinkRequest = links.Request;
pub const links_max = links.links_max;

pub const LinkResult = struct {
    id: u64,
    links: []const document.Link,
    incomplete: bool,
};

const Position = struct { anchor: Anchor, pan_x: u32, zoom: f32 };

/// A loaded version of the document.
pub const Document = struct {
    /// Identifies this load; tiles carry it so that tiles of another load
    /// are never mistaken for current ones.
    generation: u32,
    page_sizes: []const document.Size,
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
    links: LinkResult,
    search_result: search.Navigation,
    /// Something to tell the user, e.g. that a reload failed.
    message: []const u8,
};

/// What the shell should do after an event.
pub const Effect = union(enum) {
    none,
    quit,
    reload,
    move_files: i32,
    find_links,
    cancel_links,
    find_text,
    cancel_search,
    open_url: []const u8,
};

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
    labels: []const links.Label,
    hint_prefix: []const u8,
    preview: ?document.Link.Web,

    pub fn slices(frame: *const Frame) []const Slice {
        return frame.tiles.slices();
    }

    /// Visible tiles first, followed by any tiles ahead in the scroll direction.
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
    prefetch: tiling.Prefetch,
    /// Horizontal scroll in pixels when the pages are wider than the window.
    pan_x: u32,
    /// 1 fits the widest page to the window width.
    zoom: f32,
    dark: bool,
    keymap: keymap.KeyMap,
    prompt: enum { none, command, search } = .none,
    command_buffer: [command_len_max]u8,
    command_len: u32,
    message_buffer: [message_len_max]u8,
    message_len: u32,
    hints: links.Hints = .{},
    search_query: ?search.Query = null,
    search_request: ?search.Request = null,
    /// Repeats typed before a search from the viewport has found its first match.
    search_repeats: i32 = 0,
    search_id: u64 = 0,
    search_visible: bool = false,
    /// The search cursor persists independently of scrolling and resizing.
    search_selection: ?search.Navigation.Match = null,
    /// Positions on either side of link and search jumps, in chronological order.
    jumps: [64]Position = undefined,
    jump_index: usize = 0,
    jump_end: usize = 0,

    /// Starts at `page`, counting from 1, once the document is loaded.
    pub fn init(file_name: []const u8, size: terminal.Size, dark: bool, page: u32) State {
        var state: State = .{
            .file_name = file_name,
            .size = size,
            .document = .{ .generation = 0, .page_sizes = &.{}, .page_offsets = &.{} },
            .geometry = undefined,
            .anchor = .{ .page = page -| 1, .y = 0 },
            .prefetch = .none,
            .pan_x = 0,
            .zoom = 1,
            .dark = dark,
            .keymap = .{},
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
                if (state.hints.mode != .off) return state.editHints(key);
                if (state.prompt != .none) return state.editCommand(key);
                const action = state.keymap.feed(key) orelse if (key == .escape) .hide_search else return .none;
                const before = if (state.search_request != null) state.position() else null;
                const effect = state.apply(action);
                if (before != null and effect == .none and !std.meta.eql(before.?, state.position())) {
                    state.search_request = null;
                    return .cancel_search;
                }
                return effect;
            },
            .resize => |size| {
                const changed = !std.meta.eql(size, state.size);
                const cancel_lookup = changed and state.hints.mode == .loading;
                if (changed and state.hints.mode != .confirm) state.hints.close();
                const cancel_search = changed and state.search_request != null;
                if (cancel_search) state.search_request = null;
                const old_width = state.geometry.view_width;
                state.size = size;
                state.relayout();
                if (state.geometry.view_width != old_width and state.document.page_sizes.len > 0)
                    state.panToPage(state.centrePage(), .if_hidden);
                if (cancel_lookup) return .cancel_links;
                if (cancel_search) return .cancel_search;
            },
            .document => |doc| {
                std.debug.assert(doc.page_offsets.len == doc.page_sizes.len);
                std.debug.assert(doc.generation > state.document.generation);
                // Clears e.g. an earlier "reload failed".
                state.message_len = 0;
                state.hints.close();
                state.jump_index = 0;
                state.jump_end = 0;
                state.search_request = null;
                state.search_selection = null;
                state.search_visible = false;
                if (state.search_query) |*query| query.generation = doc.generation;
                state.document = doc;
                state.relayout();
            },
            .links => |result| {
                if (!state.expectsLinks(result.id)) return .none;
                std.debug.assert(result.links.len <= links_max);
                if (result.links.len == 0) {
                    state.hints.close();
                    return state.update(.{ .message = if (result.incomplete) "Could not read links in view" else "No links in view" });
                }
                state.hints.mode = .select;
                state.hints.links = result.links;
                state.hints.incomplete = result.incomplete;
                state.hints.show(state.geometry, state.size, state.anchor, state.pan_x);
            },
            .search_result => |result| {
                const request = state.search_request orelse return .none;
                if (request.id != result.id) return .none;
                state.search_request = null;
                const repeats = state.search_repeats;
                state.search_repeats = 0;
                const match = result.match orelse {
                    state.search_visible = false;
                    state.search_selection = null;
                    return state.update(.{ .message = if (result.incomplete) "Search incomplete: no match found" else "Pattern not found" });
                };
                const origin = state.position();
                const geometry = state.geometry;
                const height: f32 = @floatFromInt(geometry.pageHeight(match.page));
                const y: i64 = @intFromFloat(@round((match.area.y0 + match.area.y1) / 2 * height));
                state.anchor = geometry.anchorAt(geometry.pageTop(match.page) + y - geometry.view_height / 2);
                state.prefetch = .none;
                state.panToPage(match.page, .always);
                const width = geometry.pageWidth(match.page);
                if (width > geometry.view_width) {
                    const page_left = (geometry.content_width -| width) / 2;
                    const x = page_left + @as(u32, @intFromFloat((match.area.x0 + match.area.x1) / 2 * @as(f32, @floatFromInt(width))));
                    if (x < state.pan_x or x >= state.pan_x + geometry.view_width)
                        state.pan_x = std.math.clamp(x -| geometry.view_width / 2, page_left, page_left + width - geometry.view_width);
                }
                state.recordJump(origin);
                state.search_selection = match;
                state.search_visible = true;
                if (repeats != 0) return state.repeatSearch(repeats);
                if (result.incomplete or result.wrapped)
                    return state.update(.{ .message = if (result.incomplete) "Match found; search incomplete" else "Search wrapped" });
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
        }, state.prefetch, &frame.tiles);
        const hints = &state.hints;
        frame.labels = if (hints.mode == .select) hints.labels[0..hints.count] else &.{};
        frame.hint_prefix = hints.prefix[0..hints.prefix_len];
        frame.preview = hints.preview;
        state.writeStatus(frame);
    }

    pub fn expectsLinks(state: *const State, id: u64) bool {
        return state.hints.mode == .loading and state.hints.request_id == id;
    }

    pub fn linkRequest(state: *const State) LinkRequest {
        return .init(state.hints.request_id, state.document.generation, state.geometry, state.anchor, state.pan_x);
    }

    pub fn linkPreviewOpen(state: *const State) bool {
        return state.hints.mode == .confirm;
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
            .move_files => |n| return .{ .move_files = n },
            .goto_page => |page| state.gotoPage(@as(i64, page) - 1),
            .goto_last_page => state.gotoPage(std.math.maxInt(i32)),
            .zoom_steps => |n| state.setZoom(state.zoom * std.math.pow(f32, zoom_step, @floatFromInt(n))),
            .zoom_fit_width => state.setZoom(1),
            .toggle_dark => {
                state.dark = !state.dark;
                state.prefetch = .none;
            },
            .open_command_line => {
                state.prompt = .command;
                state.command_len = 0;
                if (state.search_request != null) {
                    state.search_request = null;
                    return .cancel_search;
                }
            },
            .open_search => {
                state.prompt = .search;
                state.command_len = 0;
                if (state.search_request != null) {
                    state.search_request = null;
                    return .cancel_search;
                }
            },
            .repeat_search => |n| return state.repeatSearch(n),
            .hide_search => {
                if (state.search_visible or state.search_request != null) {
                    state.search_visible = false;
                    state.search_request = null;
                    return .cancel_search;
                }
            },
            .follow_link => {
                if (state.document.generation == 0)
                    return state.update(.{ .message = "Still loading the document" });
                if (state.document.page_sizes.len == 0 or state.geometry.view_height == 0)
                    return state.update(.{ .message = "No links in view" });
                state.search_request = null;
                state.hints.request_id = @max(1, state.hints.request_id +% 1);
                state.hints.mode = .loading;
                return .find_links;
            },
            .older_jump, .newer_jump => {
                const index = state.jump_index;
                if ((action == .older_jump and index == 0) or
                    (action == .newer_jump and index == state.jump_end))
                    return state.update(.{ .message = if (action == .older_jump) "No earlier jump" else "No later jump" });
                state.jumps[index] = state.position();
                state.jump_index = if (action == .older_jump) index - 1 else index + 1;
                const saved = state.jumps[state.jump_index];
                state.anchor = saved.anchor;
                state.pan_x = saved.pan_x;
                state.zoom = saved.zoom;
                state.relayout();
            },
            .quit => return .quit,
        }
        return .none;
    }

    fn scrollBy(state: *State, delta: i64) void {
        if (state.document.page_sizes.len == 0) return;
        state.prefetch = if (delta > 0) .below else .above;
        const page = state.centrePage();
        state.anchor = state.geometry.anchorAt(state.geometry.offsetOf(state.anchor) + delta);
        if (state.centrePage() != page) state.panToPage(state.centrePage(), .always);
    }

    /// The page at the middle of the view, which the user is looking at.
    fn centrePage(state: *const State) u32 {
        return state.geometry.pageAt(state.geometry.offsetOf(state.anchor) + state.geometry.view_height / 2);
    }

    fn gotoPage(state: *State, page: i64) void {
        state.prefetch = .none;
        const pages = state.document.page_sizes.len;
        if (pages == 0) return;
        const anchor: Anchor = .{ .page = @intCast(std.math.clamp(page, 0, @as(i64, @intCast(pages - 1)))), .y = 0 };
        state.anchor = state.geometry.anchorAt(state.geometry.offsetOf(anchor));
        state.panToPage(anchor.page, .always);
    }

    /// Keeps `page` in view horizontally: a narrower page than the last may
    /// lie entirely outside the current pan.
    fn panToPage(state: *State, page: u32, when: enum { always, if_hidden }) void {
        const geometry = state.geometry;
        const width = geometry.pageWidth(page);
        // Content rounds to 0 px wide in a tiny view, where pages are 1 px.
        const left = (geometry.content_width -| width) / 2;
        if (when == .if_hidden and left < state.pan_x + geometry.view_width and left + width > state.pan_x) return;
        state.pan_x = if (width <= geometry.view_width)
            @min((left + width / 2) -| geometry.view_width / 2, geometry.panMax())
        else
            std.math.clamp(state.pan_x, left, left + width - geometry.view_width);
    }

    fn setZoom(state: *State, zoom: f32) void {
        const half_width = @as(f32, @floatFromInt(state.geometry.view_width)) / 2;
        // Relayout clamps pan to the new bounds, so save the old centre first.
        const was_centred = state.geometry.panMax() == 0;
        const old_centre = @as(f32, @floatFromInt(state.pan_x)) + half_width;
        const old_scale = state.geometry.scale;
        state.zoom = std.math.clamp(zoom, zoom_min, zoom_max);
        state.relayout();
        if (was_centred) {
            state.pan_x = state.geometry.panMax() / 2;
            return;
        }
        const centre = old_centre * (state.geometry.scale / old_scale);
        const pan_max: f32 = @floatFromInt(state.geometry.panMax());
        state.pan_x = @intFromFloat(std.math.clamp(centre - half_width, 0, pan_max));
    }

    /// Recomputes the geometry after the document, size or zoom changed, and
    /// keeps the position inside the document.
    fn relayout(state: *State) void {
        state.prefetch = .none;
        state.geometry = .init(state.document.page_sizes, state.document.page_offsets, state.size, state.zoom);
        const pages = state.document.page_sizes.len;
        if (pages == 0) return;
        if (state.anchor.page >= pages) state.anchor = .{ .page = @intCast(pages - 1), .y = 0 };
        state.anchor = state.geometry.anchorAt(state.geometry.offsetOf(state.anchor));
        state.pan_x = @min(state.pan_x, state.geometry.panMax());
    }

    fn editHints(state: *State, key: terminal.Key) Effect {
        const hints = &state.hints;
        if (key == .ctrl and key.ctrl == 'c') return .quit;
        if (key == .escape or (key == .backspace and (hints.mode != .select or hints.prefix_len == 0))) {
            const cancel_lookup = hints.mode == .loading;
            hints.close();
            return if (cancel_lookup) .cancel_links else .none;
        }
        switch (hints.mode) {
            .off => unreachable,
            .loading => {},
            .confirm => if (key == .enter) {
                const preview = hints.preview.?;
                if (preview.authority_end > @as(usize, state.size.cols) * (state.size.rows - 1)) return .none;
                hints.close();
                return .{ .open_url = preview.uri };
            },
            .select => switch (key) {
                .tab => if (hints.more()) {
                    hints.show(state.geometry, state.size, state.anchor, state.pan_x);
                },
                .backspace => hints.prefix_len -= 1,
                .char => |char| {
                    if (char > 0x7f) return .none;
                    hints.prefix[hints.prefix_len] = @intCast(char);
                    const prefix = hints.prefix[0 .. hints.prefix_len + 1];
                    for (hints.labels[0..hints.count]) |*label| {
                        if (!std.mem.startsWith(u8, label.text(), prefix)) continue;
                        if (prefix.len < label.len) {
                            hints.prefix_len += 1;
                            return .none;
                        }
                        switch (hints.links[label.link].target) {
                            .url => |url| {
                                hints.preview = url;
                                hints.mode = .confirm;
                            },
                            .position => |dest| {
                                hints.close();
                                state.followPosition(dest);
                            },
                        }
                        return .none;
                    }
                    return state.update(.{ .message = "No matching hint" });
                },
                else => {},
            },
        }
        return .none;
    }

    fn followPosition(state: *State, dest: document.Destination) void {
        const origin = state.position();
        state.prefetch = .none;
        const geometry = state.geometry;
        const height = geometry.pageHeight(dest.page);
        const y = std.math.clamp(dest.y orelse 0, 0, 1);
        const offset = @min(height - 1, @as(u32, @intFromFloat(@round(y * @as(f32, @floatFromInt(height))))));
        // Leave a row of context above coordinates within a page.
        state.anchor = geometry.anchorAt(geometry.pageTop(dest.page) + (offset -| state.size.cell_height));
        state.panToPage(dest.page, .always);
        if (dest.x) |x| {
            const width = geometry.pageWidth(dest.page);
            if (width > geometry.view_width) {
                const page_left = (geometry.content_width -| width) / 2;
                const fraction = std.math.clamp(x, 0, 1);
                const target_x = page_left + @min(width - 1, @as(u32, @intFromFloat(@round(fraction * @as(f32, @floatFromInt(width))))));
                if (target_x < state.pan_x or target_x >= state.pan_x + geometry.view_width)
                    state.pan_x = std.math.clamp(target_x -| state.size.cell_width, page_left, page_left + width - geometry.view_width);
            }
        }
        state.recordJump(origin);
    }

    fn position(state: *const State) Position {
        return .{ .anchor = state.anchor, .pan_x = state.pan_x, .zoom = state.zoom };
    }

    fn recordJump(state: *State, origin: Position) void {
        if (std.meta.eql(origin, state.position())) return;
        if (state.jump_index + 1 == state.jumps.len) {
            std.mem.copyForwards(Position, state.jumps[0 .. state.jump_index - 1], state.jumps[1..state.jump_index]);
            state.jump_index -= 1;
        }
        state.jumps[state.jump_index] = origin;
        state.jump_index += 1;
        state.jump_end = state.jump_index;
    }

    fn repeatSearch(state: *State, n: i32) Effect {
        const query = state.search_query orelse return state.update(.{ .message = "Use / to search" });
        if (state.document.page_sizes.len == 0)
            return state.update(.{ .message = "No pages to search" });
        var steps = n;
        if (state.search_request) |pending| {
            if (pending.after == null) {
                // The first match establishes the search cursor. In particular,
                // a fast N must step back from it once the worker finds it.
                state.search_repeats = std.math.clamp(state.search_repeats + n, -1_000_000, 1_000_000);
                return .none;
            }
            // Key repeat may outrun the worker. Replace it with the aggregate
            // distance from the same origin, avoiding a queue of stale jumps.
            const previous: i32 = @intCast(pending.count);
            steps = std.math.clamp(n + if (pending.backward) -previous else previous, -1_000_000, 1_000_000);
            if (steps == 0) {
                state.search_request = null;
                return .cancel_search;
            }
        }
        const selection = state.search_selection;
        const page, const y = if (selection) |match| .{ match.page, @as(f32, 0) } else origin: {
            const geometry = state.geometry;
            const centre = geometry.offsetOf(state.anchor) + geometry.view_height / 2;
            const page = geometry.pageAt(centre);
            const height = geometry.pageHeight(page);
            const offset = std.math.clamp(centre - geometry.pageTop(page), 0, height);
            break :origin .{ page, @as(f32, @floatFromInt(offset)) / @as(f32, @floatFromInt(height)) };
        };
        state.search_repeats = 0;
        state.search_id = @max(1, state.search_id +% 1);
        state.search_request = .{
            .id = state.search_id,
            .query = query,
            .page = page,
            .y = y,
            .after = if (selection) |match| match.part else null,
            .backward = steps < 0,
            .count = @abs(steps),
        };
        state.search_visible = true;
        return .find_text;
    }

    fn editCommand(state: *State, key: terminal.Key) Effect {
        std.debug.assert(state.prompt != .none);
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
                    state.prompt = .none;
                } else {
                    // Drop the last whole character.
                    state.command_len -= 1;
                    while (state.command_len > 0 and state.command_buffer[state.command_len] & 0xc0 == 0x80) {
                        state.command_len -= 1;
                    }
                }
            },
            .escape, .ctrl => state.prompt = .none,
            .enter => {
                const prompt = state.prompt;
                state.prompt = .none;
                const line = state.command_buffer[0..state.command_len];
                if (prompt == .search) {
                    if (line.len > 0) {
                        state.search_id = @max(1, state.search_id +% 1);
                        var query: search.Query = .{
                            .generation = state.document.generation,
                            .id = state.search_id,
                            .bytes = undefined,
                            .len = @intCast(line.len),
                        };
                        @memcpy(query.bytes[0..line.len], line);
                        query.bytes[line.len] = 0;
                        state.search_query = query;
                        state.search_selection = null;
                    }
                    return state.repeatSearch(1);
                }
                return state.runCommand(std.mem.trim(u8, line, " "));
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
        if (std.mem.eql(u8, name, "noh")) return state.apply(.hide_search);
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
        frame.status_keep_end = state.prompt != .none;
        if (state.prompt != .none) {
            writer.print("{c}{s}", .{ if (state.prompt == .search) @as(u8, '/') else ':', state.command_buffer[0..state.command_len] }) catch {};
            frame.status_left_len = @intCast(writer.end);
            frame.status_right_len = 0;
            return;
        }
        const message = state.message_buffer[0..state.message_len];
        const hints = &state.hints;
        if (hints.mode != .off) {
            switch (hints.mode) {
                .off => unreachable,
                .loading => writer.writeAll("Finding links...  Esc cancel") catch {},
                .select => {
                    if (message.len > 0) {
                        writer.print("{s}  ", .{message}) catch {};
                    } else if (hints.prefix_len > 0) {
                        writer.print("Link: {s}  Backspace undo  ", .{hints.prefix[0..hints.prefix_len]}) catch {};
                    } else {
                        writer.writeAll("Type a link hint  ") catch {};
                    }
                    writer.writeAll("Esc cancel") catch {};
                    if (hints.incomplete) writer.writeAll("  Some links unavailable") catch {};
                },
                .confirm => {
                    const preview = hints.preview.?;
                    const capacity = @as(usize, state.size.cols) * (state.size.rows - 1);
                    writer.writeAll(if (preview.authority_end > capacity)
                        "Enlarge to open  Esc cancel"
                    else if (capacity == preview.authority_end and preview.uri.len > capacity)
                        // The address panel has no room for an ellipsis after the host.
                        "URL cut  Enter open"
                    else
                        "Enter open in browser  Esc cancel") catch {};
                },
            }
            frame.status_left_len = @intCast(writer.end);
            if (hints.mode == .select and hints.more()) writer.print("Tab {d}-{d}/{d}", .{
                hints.shown_count - hints.count + 1, hints.shown_count, hints.links.len,
            }) catch {};
            frame.status_right_len = @intCast(writer.end - frame.status_left_len);
            return;
        }
        if (state.search_request) |request| {
            writer.print("Searching for {s}...  Esc cancel", .{request.query.text()}) catch {};
        } else if (message.len == 0 and state.search_visible) {
            writer.print("/{s}", .{state.search_query.?.text()}) catch {};
        } else {
            writer.writeAll(if (message.len > 0) message else state.file_name) catch {};
        }
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
    _ = links;
    _ = tiling;
}

const test_size: terminal.Size = .{ .cols = 80, .rows = 25, .cell_width = 10, .cell_height = 20 };
/// An 800x480 px view; A4 pages fit to 800 px wide are about 1132 px tall.
const test_pages: [3]document.Size = @splat(.{ .width = 595, .height = 842 });
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

test "scrolling prepares the next screen, while page jumps and zoom request only visible tiles" {
    var viewer: TestViewer = undefined;
    viewer.init();
    var frame: Frame = undefined;
    _ = viewer.feed("2G2j");
    viewer.state.layout(&frame);
    try std.testing.expect(frame.wanted().len > frame.slices().len);
    try std.testing.expectEqual(1, frame.wanted()[frame.slices().len].row);

    for ([_][]const u8{ "3G", "2j+" }) |keys| {
        _ = viewer.feed(keys);
        viewer.state.layout(&frame);
        try std.testing.expectEqual(frame.slices().len, frame.wanted().len);
    }
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

test "zooming in from a centred page keeps its midpoint in view" {
    var viewer: TestViewer = undefined;
    viewer.init();
    _ = viewer.feed(":zoom 50\r:zoom 200\r");
    try std.testing.expectEqual(400, viewer.state.pan_x);
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
    try std.testing.expect(viewer.state.prompt == .none);
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
    try std.testing.expect(viewer.state.prompt == .none);
}

test "a reload keeps the position, clamped to the new page count" {
    var viewer: TestViewer = undefined;
    viewer.init();
    _ = viewer.feed("G");
    _ = viewer.state.update(.{ .document = .{ .generation = 2, .page_sizes = test_pages[0..1], .page_offsets = test_offsets[0..1] } });
    try std.testing.expectEqual(0, viewer.state.anchor.page);
}

test "jumping to a narrower page brings it into view" {
    const pages = [_]document.Size{ .{ .width = 2000, .height = 100 }, .{ .width = 200, .height = 100 } };
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

test "scrolling onto a narrower page brings it into view" {
    const pages = [_]document.Size{ .{ .width = 2000, .height = 100 }, .{ .width = 200, .height = 100 } };
    const offsets = [_]f64{ 0, 100 };
    var state: State = .init("doc.pdf", test_size, false, 1);
    _ = state.update(.{ .document = .{ .generation = 1, .page_sizes = &pages, .page_offsets = &offsets } });
    for (":zoom 800\r") |byte| _ = state.update(.{ .key = terminal.Key.decode(&.{byte}).?.key });
    state.pan_x = state.geometry.panMax();
    // The narrow page is too short to reach the top, but fills the view's
    // middle once scrolled to the end.
    for (0..20) |_| _ = state.update(.{ .key = .{ .ctrl = 'd' } });
    var frame: Frame = undefined;
    state.layout(&frame);
    for (frame.slices()) |slice| {
        if (slice.tile.page == 1) break;
    } else return error.TestUnexpectedResult;
}

test "resizing brings a hidden page into view and preserves a visible pan" {
    var viewer = TestViewer{ .state = .init("doc.pdf", test_size, false, 1) };
    const pages = [_]document.Size{ .{ .width = 1000, .height = 1000 }, .{ .width = 50, .height = 1000 } };
    _ = viewer.state.update(.{ .document = .{ .generation = 1, .page_sizes = &pages, .page_offsets = &.{ 0, 1000 } } });
    _ = viewer.feed(":zoom 800\rG");
    var size = test_size;
    size.cols /= 2;
    _ = viewer.state.update(.{ .resize = size });
    var frame: Frame = undefined;
    viewer.state.layout(&frame);
    for (frame.slices()) |slice| {
        if (slice.tile.page == 1) break;
    } else return error.TestUnexpectedResult;

    // Leave only the rightmost 20 px visible, then widen by one cell.
    _ = viewer.feed("13");
    _ = viewer.state.update(.{ .key = .right });
    const pan = viewer.state.pan_x;
    size.cols += 1;
    _ = viewer.state.update(.{ .resize = size });
    try std.testing.expectEqual(pan, viewer.state.pan_x);
}

test "a view too small to show pages doesn't crash" {
    var state: State = .init("doc.pdf", .{ .cols = 1, .rows = 2, .cell_width = 1, .cell_height = 1 }, false, 1);
    _ = state.update(.{ .document = .{ .generation = 1, .page_sizes = &test_pages, .page_offsets = &test_offsets } });
    for ("-----hl") |byte| _ = state.update(.{ .key = terminal.Key.decode(&.{byte}).?.key });
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
