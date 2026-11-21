//! The interactive viewer: connects the viewer's logic (`viewer/`) to the
//! terminal, the render thread and the file on disk.
//!
//! `App` handles each kind of input and draws frames to any stream, so tests
//! and the harness drive it against an emulator, with `settle` stepping the
//! renderer on the calling thread. `run` is the event loop around it for a
//! real terminal: it waits on keys, render results, resizes and a timer for
//! watching the file, and owns all blocking.

// std
const builtin = @import("builtin");
const std = @import("std");

// project
const graphics = @import("../graphics/main.zig");
const document = @import("../document/main.zig");
const terminal = @import("../terminal/main.zig");
const viewer = @import("../viewer/main.zig");

// local
const Cache = @import("Cache.zig");
const Highlights = @import("Highlights.zig");
const Renderer = @import("Renderer.zig");

// aliases
const posix = std.posix;
const search = viewer.search;

// ====================================================================================================
// Constants
// ====================================================================================================

/// Bounds both transmitted bytes and decoded image work per frame, including
/// shared memory. Larger batches wait so keys are handled between uploads.
const upload_bytes_per_frame = 8 * 1024 * 1024;
/// How often to check the file for changes when watching.
const watch_interval_ms = 250;
/// Distinguishes Escape from an escape sequence split across reads.
const escape_timeout_ms = 50;
const opener_poll_ms = 250;
/// The longest key sequence kept while waiting for the rest of it.
const pending_input_max = 128;
/// The most bytes `App.input` takes at once.
pub const input_len_max = 256;

// ====================================================================================================
// Types
// ====================================================================================================

pub const Options = struct {
    path: []const u8,
    /// Page to show first, counting from 1.
    page: u32,
    dark: bool,
    watch: bool,
    medium: graphics.Medium,
};

/// When the viewport and its loaded tiles are unchanged, prompt typing and
/// speculative tile results need only redraw the status line. Search may
/// have hundreds of graphics placements, so avoid retransmitting them.
const SearchFrame = struct {
    generation: u32,
    query: u64,
    anchor: viewer.Anchor,
    pan_x: u32,
    zoom: f32,
    dark: bool,
};

pub const App = struct {
    gpa: std.mem.Allocator,
    state: viewer.State,
    renderer: Renderer,
    cache: Cache,
    /// The loaded document's page sizes and offsets, which `state` points to.
    page_sizes: []document.Size,
    page_offsets: []f64,
    /// Owns the link strings borrowed by the viewer while hints are active.
    link_arena: ?std.heap.ArenaAllocator = null,
    search_pages: [search.pages_max]?search.Page = @splat(null),
    /// Pin the pages chosen for this viewport while older results arrive.
    highlight_pages: [search.pages_max]u32 = undefined,
    highlight_pages_len: usize = 0,
    highlights: Highlights = .{},
    search_frame: ?SearchFrame = null,
    painted_images: [viewer.tiles_max]graphics.ImageId = undefined,
    painted_images_len: usize = 0,
    url_to_open: ?[]u8 = null,
    frame: viewer.Frame,
    results: std.ArrayList(Renderer.Result),
    /// The start of a key sequence cut off at the end of the last input.
    pending_input: [pending_input_max]u8,
    pending_input_len: u32,
    /// Once a control string exceeds the buffer, discard through its terminator
    /// rather than interpreting the remaining protocol bytes as user commands.
    discarding_string: bool,
    discarded_escape: bool,
    escape_started: ?std.Io.Timestamp,
    /// Whether the screen is out of date.
    dirty: bool,
    /// Whether text drawn at an earlier window size must be erased.
    resized: bool,
    drew_overlay: bool = false,
    preview_drawn: bool = false,
    /// Set when the document can't be loaded and there is nothing to show.
    open_error: ?document.Error,

    /// Initialized in place: the renderer must not move once started.
    pub fn init(
        app: *App,
        io: std.Io,
        gpa: std.mem.Allocator,
        options: Options,
        size: terminal.Size,
        wake_fd: ?posix.fd_t,
    ) void {
        app.* = .{
            .gpa = gpa,
            .state = .init(std.fs.path.basename(options.path), size, options.dark, options.page),
            .renderer = undefined,
            .cache = .init(Cache.uploaded_bytes_max, Cache.pending_bytes_max),
            .page_sizes = &.{},
            .page_offsets = &.{},
            .frame = undefined,
            .results = .empty,
            .pending_input = undefined,
            .pending_input_len = 0,
            .discarding_string = false,
            .discarded_escape = false,
            .escape_started = null,
            .dirty = true,
            .resized = false,
            .open_error = null,
        };
        app.renderer.init(io, gpa, options.path, options.medium, wake_fd);
    }

    pub fn deinit(app: *App) void {
        app.renderer.deinit();
        for (app.results.items) |result| result.deinit(app.gpa);
        app.results.deinit(app.gpa);
        app.cache.deinit(app.gpa);
        app.gpa.free(app.page_sizes);
        app.gpa.free(app.page_offsets);
        if (app.link_arena) |arena| arena.deinit();
        app.clearSearchPages();
        if (app.url_to_open) |url| app.gpa.free(url);
        app.* = undefined;
    }

    /// Handles at most `input_len_max` bytes typed in the terminal, and
    /// returns whether they asked to quit. A key sequence cut off at the end
    /// is kept until the rest arrives.
    pub fn input(app: *App, bytes: []const u8) bool {
        std.debug.assert(bytes.len <= input_len_max);
        if (bytes.len == 0) return false;
        var incoming = bytes;
        if (app.discarding_string) {
            while (incoming.len > 0) {
                const byte = incoming[0];
                incoming = incoming[1..];
                const finished = byte == 0x07 or (app.discarded_escape and byte == '\\');
                app.discarded_escape = byte == 0x1b;
                if (finished) {
                    app.discarding_string = false;
                    app.discarded_escape = false;
                    break;
                }
            }
            if (app.discarding_string or incoming.len == 0) return false;
        }
        var buffer: [pending_input_max + input_len_max]u8 = undefined;
        @memcpy(buffer[0..app.pending_input_len], app.pending_input[0..app.pending_input_len]);
        @memcpy(buffer[app.pending_input_len..][0..incoming.len], incoming);
        var unread = buffer[0 .. app.pending_input_len + incoming.len];
        app.pending_input_len = 0;
        app.escape_started = null;

        // A label and Enter received together must still show the preview
        // before they can open a browser.
        while (unread.len > 0) {
            const decoded = terminal.Key.decode(unread) orelse {
                // Longer than any key: drop it rather than wait forever.
                if (unread.len <= pending_input_max) {
                    @memcpy(app.pending_input[0..unread.len], unread);
                    app.pending_input_len = @intCast(unread.len);
                    if (std.mem.eql(u8, unread, "\x1b")) app.escape_started = .now(app.renderer.io, .awake);
                } else if (std.mem.startsWith(u8, unread, "\x1b_") or
                    std.mem.startsWith(u8, unread, "\x1b]") or
                    std.mem.startsWith(u8, unread, "\x1bP"))
                {
                    app.discarding_string = true;
                    app.discarded_escape = unread[unread.len - 1] == 0x1b;
                }
                return false;
            };
            if (graphics.Reply.parse(unread[0..decoded.len])) |reply| {
                switch (app.highlights.reject(reply)) {
                    .ignored => {},
                    .retry => {
                        app.search_frame = null;
                        app.dirty = true;
                    },
                    .failed => {
                        app.search_frame = null;
                        _ = app.state.update(.{ .message = "Terminal cannot display search highlights" });
                        app.dirty = true;
                    },
                }
                switch (app.cache.reject(reply)) {
                    .ignored => {},
                    .retry => app.dirty = true,
                    .failed => {
                        _ = app.state.update(.{ .message = if (reply.status == .not_found and reply.placement == 1)
                            "terminal cannot retain visible images"
                        else
                            "terminal rejected image" });
                        app.dirty = true;
                    },
                }
                unread = unread[decoded.len..];
                continue;
            }
            unread = unread[decoded.len..];
            if (decoded.key == .release) continue;
            app.dirty = true;
            if (decoded.key == .enter and !app.preview_drawn and app.state.linkPreviewOpen()) continue;
            const effect = app.state.update(.{ .key = decoded.key });
            app.preview_drawn = app.preview_drawn and app.state.linkPreviewOpen();
            if (app.apply(effect)) return true;
        }
        return false;
    }

    /// Resolves a standalone Escape once its continuation deadline passes.
    pub fn expireInput(app: *App, now: std.Io.Timestamp) void {
        const started = app.escape_started orelse return;
        if (started.durationTo(now).toMilliseconds() < escape_timeout_ms) return;
        app.escape_started = null;
        app.pending_input_len = 0;
        app.dirty = true;
        _ = app.apply(app.state.update(.{ .key = .escape }));
    }

    pub fn resize(app: *App, size: terminal.Size) void {
        app.dirty = true;
        app.resized = true;
        app.preview_drawn = false;
        _ = app.apply(app.state.update(.{ .resize = size }));
    }

    /// Takes in what the renderer finished since the last call.
    pub fn collect(app: *App) std.mem.Allocator.Error!void {
        try app.renderer.collect(&app.results);
        defer app.results.clearRetainingCapacity();
        for (app.results.items) |result| {
            app.take(result) catch {
                app.dirty = true;
                // Later results may describe a reload the viewer must observe.
                _ = app.state.update(.{ .message = "out of memory" });
            };
        }
    }

    /// Draws the current frame, asking the renderer for missing tiles and
    /// uploading finished ones. Stays dirty while uploads are pending.
    pub fn draw(app: *App, output: *std.Io.Writer) (std.mem.Allocator.Error || std.Io.Writer.Error || error{Unexpected})!void {
        const frame = &app.frame;
        app.state.layout(frame);

        var visible_tiles: [viewer.tiles_max]viewer.Tile = undefined;
        const visible = visible_tiles[0..frame.slices().len];
        for (visible, frame.slices()) |*tile, slice| tile.* = slice.tile;
        app.cache.beginFrame(visible);

        var missing: [viewer.tiles_max]viewer.Tile = undefined;
        const visible_missing = app.cache.findMissing(visible, &missing).len;
        const speculative_missing = app.cache.findMissing(frame.wanted()[visible.len..], missing[visible_missing..]).len;
        app.renderer.want(missing[0 .. visible_missing + speculative_missing], visible_missing);
        try app.cache.reserve(output, if (app.state.search_visible) Highlights.budget_bytes else 0);
        app.dirty = try app.cache.upload(app.gpa, output, visible, upload_bytes_per_frame);

        try output.writeAll(terminal.sync_begin);
        const force_repaint = app.resized or app.drew_overlay;
        if (force_repaint) try output.writeAll(terminal.clear_text);
        app.resized = false;
        app.drew_overlay = frame.labels.len > 0 or frame.preview != null;
        if (!app.drew_overlay) {
            if (app.link_arena) |arena| arena.deinit();
            app.link_arena = null;
        }
        app.preview_drawn = frame.preview != null;
        const size = app.state.size;
        var images: [viewer.tiles_max]graphics.ImageId = undefined;
        const shown = images[0..visible.len];
        for (shown, visible) |*id, tile| id.* = app.cache.shown(tile) orelse 0;
        const scene: ?SearchFrame = if (app.state.search_visible and !app.drew_overlay) .{
            .generation = app.state.document.generation,
            .query = app.state.search_query.?.id,
            .anchor = app.state.anchor,
            .pan_x = app.state.pan_x,
            .zoom = app.state.zoom,
            .dark = app.state.dark,
        } else null;
        const reuse_scene = !force_repaint and scene != null and std.meta.eql(scene, app.search_frame) and
            std.mem.eql(graphics.ImageId, shown, app.painted_images[0..app.painted_images_len]);
        if (!reuse_scene) {
            try graphics.clearPlacements(output);
            for (frame.slices(), shown) |slice, image| {
                if (image == 0) continue;
                try graphics.place(output, .{
                    .image = image,
                    .source = .{ .x = slice.source_x, .y = slice.source_y, .width = slice.width, .height = slice.height },
                    .col = @intCast(slice.x / size.cell_width),
                    .row = @intCast(slice.y / size.cell_height),
                    .x_offset = @intCast(slice.x % size.cell_width),
                    .y_offset = @intCast(slice.y % size.cell_height),
                    .behind_text = app.drew_overlay,
                });
            }
            if (app.state.search_visible) {
                try app.drawSearch(output);
            } else {
                app.highlights.clear(output);
                app.highlight_pages_len = 0;
            }
            if (scene != null) {
                @memcpy(app.painted_images[0..shown.len], shown);
                app.painted_images_len = shown.len;
            }
        }
        app.search_frame = scene;
        if (app.drew_overlay) try drawOverlay(output, frame, size);
        try drawStatus(output, frame.status(), size);
        try output.writeAll(terminal.sync_end);
        try app.cache.evict(app.gpa, output);
        try output.flush();
    }

    /// Renders on the calling thread, drawing to `output`, until there is
    /// nothing left to do. For tests and the harness; `run` renders on a
    /// thread instead.
    pub fn settle(app: *App, output: *std.Io.Writer) !void {
        std.debug.assert(app.renderer.thread == null);
        while (true) {
            try app.collect();
            if (app.open_error != null) return;
            if (app.dirty) try app.draw(output);
            if (!app.renderer.step() and !app.dirty) return;
        }
    }

    fn apply(app: *App, effect: viewer.Effect) bool {
        switch (effect) {
            .none => {},
            .quit => return true,
            .reload => app.renderer.reload(),
            .find_links => {
                app.search_frame = null;
                app.renderer.cancelText();
                if (app.link_arena) |arena| arena.deinit();
                app.link_arena = null;
                app.renderer.findLinks(app.state.linkRequest());
            },
            .cancel_links => app.renderer.cancelLinks(),
            .find_text => app.renderer.findText(app.state.search_request.?),
            .cancel_search => {
                app.search_frame = null;
                app.renderer.cancelText();
            },
            .open_url => |url| {
                if (app.url_to_open) |old| app.gpa.free(old);
                app.url_to_open = app.gpa.dupe(u8, url) catch blk: {
                    _ = app.state.update(.{ .message = "Could not open link: out of memory" });
                    break :blk null;
                };
            },
        }
        return false;
    }

    fn clearSearchPages(app: *App) void {
        for (&app.search_pages) |*entry| {
            if (entry.*) |page| app.gpa.free(page.parts);
            entry.* = null;
        }
    }

    fn drawSearch(app: *App, output: *std.Io.Writer) (std.mem.Allocator.Error || std.Io.Writer.Error || error{Unexpected})!void {
        const state = &app.state;
        const query = state.search_query orelse return;
        const active = state.search_selection;
        const geometry = state.geometry;
        const top = geometry.offsetOf(state.anchor);
        var needed: search.Viewport = .{ .query = query, .pages = undefined, .len = 0 };
        var cached: [search.pages_max]search.Page = undefined;
        var cached_len: usize = 0;
        app.highlight_pages_len = 0;
        if (active) |match| {
            for (app.frame.slices()) |slice| {
                if (slice.tile.page == match.page) {
                    app.highlight_pages[0] = match.page;
                    app.highlight_pages_len = 1;
                    break;
                }
            }
        }
        var previous: ?u32 = null;
        for (app.frame.slices()) |slice| {
            const page = slice.tile.page;
            if (page == previous or (active != null and active.?.page == page)) continue;
            previous = page;
            if (app.highlight_pages_len == search.pages_max) break;
            app.highlight_pages[app.highlight_pages_len] = page;
            app.highlight_pages_len += 1;
        }
        pages: for (app.highlight_pages[0..app.highlight_pages_len]) |page| {
            for (app.search_pages) |slot| {
                if (slot != null and slot.?.number == page and slot.?.query_id == query.id and slot.?.generation == query.generation) {
                    const entry = slot.?;
                    cached[cached_len] = entry;
                    cached_len += 1;
                    continue :pages;
                }
            }
            needed.pages[needed.len] = page;
            needed.len += 1;
        }
        app.renderer.wantSearchPages(needed);

        // Active rectangles get space first even when there are many other hits.
        var regions: [256]Highlights.Region = undefined;
        var len: usize = 0;
        full: for ([2]bool{ true, false }) |active_pass| {
            if (active_pass and active == null) continue;
            for (cached[0..cached_len]) |entry| {
                const active_part: ?usize = if (active != null and active.?.page == entry.number) active.?.part else null;
                if (active_pass and active_part == null) continue;
                var is_active = false;
                for (entry.parts, 0..) |part, i| {
                    if (part.first) is_active = i == active_part;
                    if (is_active != active_pass) continue;
                    const rect = search.screenRect(geometry, top, state.pan_x, entry.number, part.area) orelse continue;
                    regions[len] = .{ .rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height }, .active = is_active };
                    len += 1;
                    if (len == regions.len) break :full;
                }
            }
            // The selected area remains available when copying page matches
            // out of the render worker fails.
            if (active_pass and len == 0) {
                if (search.screenRect(geometry, top, state.pan_x, active.?.page, active.?.area)) |rect| {
                    regions[0] = .{ .rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height }, .active = true };
                    len = 1;
                }
            }
        }
        try app.highlights.draw(app.gpa, output, regions[0..len], state.size, state.dark, app.drew_overlay);
    }

    fn take(app: *App, result: Renderer.Result) std.mem.Allocator.Error!void {
        switch (result) {
            .opened => |opened| {
                _ = app.state.update(.{ .document = .{
                    .generation = opened.generation,
                    .page_sizes = opened.page_sizes,
                    .page_offsets = opened.page_offsets,
                } });
                app.gpa.free(app.page_sizes);
                app.gpa.free(app.page_offsets);
                app.page_sizes = opened.page_sizes;
                app.page_offsets = opened.page_offsets;
                if (app.link_arena) |arena| arena.deinit();
                app.link_arena = null;
                app.clearSearchPages();
            },
            .open_failed => |err| {
                if (app.state.document.generation == 0) app.open_error = err;
                var buffer: [64]u8 = undefined;
                const text = std.fmt.bufPrint(&buffer, "reload failed: {t}", .{err}) catch unreachable;
                _ = app.state.update(.{ .message = text });
            },
            .tile => |tile| {
                try app.cache.put(app.gpa, tile.tile, tile.encoded);
                if (!app.cache.needsFrame(tile.tile)) return;
            },
            .links => |links| {
                if (!app.state.expectsLinks(links.view.id)) {
                    links.arena.deinit();
                    return;
                }
                if (app.link_arena) |arena| arena.deinit();
                app.link_arena = links.arena;
                _ = app.state.update(.{ .links = links.view });
            },
            .search => |found| {
                if (found.page) |page| {
                    const query = app.state.search_query;
                    if (query != null and page.query_id == query.?.id and page.generation == query.?.generation) {
                        const pinned = app.highlight_pages[0..app.highlight_pages_len];
                        var replacement: ?*?search.Page = null;
                        for (&app.search_pages) |*slot| {
                            if (slot.*) |old| {
                                if (old.number == page.number and old.query_id == page.query_id and old.generation == page.generation) {
                                    replacement = slot;
                                    break;
                                }
                                if (replacement == null and (old.query_id != page.query_id or old.generation != page.generation or
                                    std.mem.findScalar(u32, pinned, old.number) == null))
                                    replacement = slot;
                            } else if (replacement == null or replacement.?.* != null) {
                                replacement = slot;
                            }
                        }
                        if (replacement == null and found.navigation != null) replacement = &app.search_pages[0];
                        if (replacement) |slot| {
                            const had_hits = slot.* != null and slot.*.?.parts.len > 0 and slot.*.?.query_id == page.query_id;
                            if (slot.*) |old| app.gpa.free(old.parts);
                            slot.* = page;
                            if ((had_hits or page.parts.len > 0) and app.state.search_visible and
                                std.mem.findScalar(u32, pinned, page.number) != null)
                            {
                                app.search_frame = null;
                                app.dirty = true;
                            }
                        } else {
                            app.gpa.free(page.parts);
                        }
                    } else {
                        app.gpa.free(page.parts);
                    }
                }
                if (found.navigation) |navigation| {
                    if (app.state.search_request) |request| {
                        if (request.id == navigation.id) {
                            _ = app.apply(app.state.update(.{ .search_result = navigation }));
                            app.search_frame = null;
                            app.dirty = true;
                        }
                    }
                }
                return;
            },
            .render_failed => |tile| {
                try app.cache.putFailed(app.gpa, tile);
                var buffer: [64]u8 = undefined;
                const text = std.fmt.bufPrint(&buffer, "cannot render page {d}", .{tile.page + 1}) catch unreachable;
                _ = app.state.update(.{ .message = text });
            },
        }
        app.dirty = true;
    }
};

/// Notices when the file has changed and stopped changing: a reload waits
/// until two checks in a row agree, so it doesn't read a half-written file.
const Watch = struct {
    path: []const u8,
    loaded: ?Stamp,
    pending: ?Stamp,
    checked: std.Io.Timestamp,

    const Stamp = struct { size: u64, mtime: i96, inode: u64 };

    fn init(io: std.Io, path: []const u8) Watch {
        return .{ .path = path, .loaded = stamp(io, path), .pending = null, .checked = .now(io, .awake) };
    }

    /// Checks the file at most every `watch_interval_ms`.
    fn changed(watch: *Watch, io: std.Io) bool {
        const now: std.Io.Timestamp = .now(io, .awake);
        if (watch.checked.durationTo(now).toMilliseconds() < watch_interval_ms) return false;
        watch.checked = now;
        return watch.observe(stamp(io, watch.path) orelse return false);
    }

    /// Whether to reload, given the file's state at this check.
    fn observe(watch: *Watch, current: Stamp) bool {
        if (watch.loaded != null and std.meta.eql(current, watch.loaded.?)) {
            watch.pending = null;
            return false;
        }
        if (watch.pending != null and std.meta.eql(current, watch.pending.?)) {
            watch.loaded = current;
            watch.pending = null;
            return true;
        }
        watch.pending = current;
        return false;
    }

    fn stamp(io: std.Io, path: []const u8) ?Stamp {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
        return .{ .size = stat.size, .mtime = stat.mtime.toNanoseconds(), .inode = @intCast(stat.inode) };
    }
};

// ====================================================================================================
// Public API
// ====================================================================================================

/// Runs the viewer full screen until quit. Expects raw mode, and that the
/// terminal supports images.
pub fn run(io: std.Io, gpa: std.mem.Allocator, options: Options, size: terminal.Size, output: *std.Io.Writer) !void {
    var wake_fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&wake_fds) != 0) return error.Unexpected;
    defer for (wake_fds) |fd| {
        _ = std.c.close(fd);
    };
    for (wake_fds) |fd| {
        if (std.c.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC)) != 0) return error.Unexpected;
    }
    // Wake bytes may coalesce; neither the worker nor a signal may block here.
    const flags: c_int = @bitCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
    if (std.c.fcntl(wake_fds[1], posix.F.SETFL, flags) != 0) return error.Unexpected;
    terminal.notifySignals(wake_fds[1]);
    defer terminal.notifySignals(null);

    const app = try gpa.create(App);
    defer gpa.destroy(app);
    app.init(io, gpa, options, size, wake_fds[1]);
    defer app.deinit();
    var watch: Watch = .init(io, options.path);
    try app.renderer.start();

    try output.writeAll(terminal.fullscreen_enter);
    defer {
        app.highlights.clear(output);
        app.cache.clear(gpa, output);
        output.writeAll(terminal.fullscreen_leave) catch {};
        output.flush() catch {};
    }

    var read_buffer: [input_len_max]u8 = undefined;
    var opener_ids: [16]posix.pid_t = undefined;
    var openers: std.ArrayList(posix.pid_t) = .initBuffer(&opener_ids);
    while (true) {
        if (app.dirty) try app.draw(output);
        if (app.open_error) |err| return err;

        var fds = [_]posix.pollfd{
            .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = wake_fds[0], .events = posix.POLL.IN, .revents = 0 },
        };
        var timeout_ms: i32 = if (app.dirty) 0 else if (options.watch) watch_interval_ms else -1;
        if (openers.items.len > 0) timeout_ms = if (timeout_ms < 0) opener_poll_ms else @min(timeout_ms, opener_poll_ms);
        if (app.escape_started) |started| {
            const elapsed = started.durationTo(.now(io, .awake)).toMilliseconds();
            const remaining: i32 = @intCast(@max(0, escape_timeout_ms - elapsed));
            timeout_ms = if (timeout_ms < 0) remaining else @min(timeout_ms, remaining);
        }
        _ = try posix.poll(&fds, timeout_ms);

        if (fds[0].revents != 0) {
            const len = try posix.read(posix.STDIN_FILENO, &read_buffer);
            // The terminal went away.
            if (len == 0) return;
            if (app.input(read_buffer[0..len])) return;
        }
        if (fds[1].revents != 0) {
            _ = try posix.read(wake_fds[0], &read_buffer);
        }
        const signals = terminal.takeSignals();
        if (signals.quit) return;
        if (signals.resized) {
            var stdin: terminal.Input = .init(&read_buffer, 100);
            const resized = terminal.size(&stdin.interface, output) catch app.state.size;
            app.resize(resized);
        }
        app.expireInput(.now(io, .awake));
        try app.collect();
        // Desktop openers may stay alive until the browser closes.
        var i: usize = 0;
        while (i < openers.items.len) {
            var status: c_int = 0;
            const reaped = std.c.waitpid(openers.items[i], &status, posix.W.NOHANG);
            if (reaped == 0 or posix.errno(reaped) == .INTR) {
                i += 1;
                continue;
            }
            _ = openers.swapRemove(i);
            if (reaped < 0 or status != 0) {
                _ = app.state.update(.{ .message = "Could not open link in browser" });
                app.dirty = true;
            }
        }
        if (app.url_to_open) |url| {
            app.url_to_open = null;
            defer gpa.free(url);
            const opener = if (builtin.os.tag == .macos) "/usr/bin/open" else "xdg-open";
            if (openers.items.len == openers.capacity) {
                _ = app.state.update(.{ .message = "Too many browser launches in progress" });
            } else if (std.process.spawn(io, .{
                .argv = &.{ opener, url },
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            })) |child| {
                openers.appendAssumeCapacity(child.id.?);
            } else |_| {
                _ = app.state.update(.{ .message = "Could not start browser opener" });
            }
            app.dirty = true;
        }
        if (options.watch and watch.changed(io)) app.renderer.reload();
    }
}

// ====================================================================================================
// Private Functions
// ====================================================================================================

fn drawOverlay(output: *std.Io.Writer, frame: *const viewer.Frame, size: terminal.Size) std.Io.Writer.Error!void {
    for (frame.labels) |*label| {
        const code = label.text();
        if (!std.mem.startsWith(u8, code, frame.hint_prefix)) continue;
        try terminal.moveCursor(output, label.row, label.col);
        try output.writeAll("\x1b[1;38;2;28;23;14;48;2;255;207;89m");
        if (frame.hint_prefix.len > 0) {
            try output.writeAll("\x1b[48;2;235;161;53m");
            try output.writeAll(frame.hint_prefix);
            try output.writeAll("\x1b[48;2;255;207;89m");
        }
        try output.writeAll(code[frame.hint_prefix.len..]);
    }
    if (frame.preview) |preview| {
        const cols: usize = size.cols;
        const authority_rows = std.math.divCeil(usize, preview.authority_end + 3, cols) catch unreachable;
        const url_rows = std.math.divCeil(usize, preview.uri.len, cols) catch unreachable;
        const rows = @min(@min(@max(4, authority_rows), size.rows -| 1), url_rows);
        const shown = @min(preview.uri.len, rows * cols);
        const reserve = if (shown < preview.authority_end) 0 else preview.authority_end;
        const marker = if (shown == preview.uri.len) 0 else @min(shown - reserve, cols, 3);
        const text = preview.uri[0 .. shown - marker];
        try output.writeAll("\x1b[38;2;232;239;253;48;2;34;48;70m");
        for (0..rows) |row| {
            try terminal.moveCursor(output, @intCast(size.rows - 1 - rows + row), 0);
            const chunk = text[row * cols .. @min(text.len, (row + 1) * cols)];
            try terminal.writeText(output, chunk);
            if (row + 1 == rows) try output.splatByteAll('.', marker);
            try output.splatByteAll(' ', cols - chunk.len - if (row + 1 == rows) marker else 0);
        }
    }
    try output.writeAll(terminal.style_reset);
}

/// The status line in reverse video across the last row.
fn drawStatus(output: *std.Io.Writer, status: viewer.Status, size: terminal.Size) std.Io.Writer.Error!void {
    const gap = "  ";
    const right = truncate(status.right, size.cols, false);
    const right_cols = terminal.textWidth(right);
    const left_room = (size.cols - right_cols) -| if (right_cols > 0) gap.len else 0;
    const left = truncate(status.left, left_room, status.keep_end);
    const padding = size.cols - right_cols - terminal.textWidth(left);

    try terminal.moveCursor(output, size.rows - 1, 0);
    try output.writeAll(terminal.style_reverse);
    try terminal.writeText(output, left);
    try output.splatByteAll(' ', padding);
    try terminal.writeText(output, right);
    try output.writeAll(terminal.style_reset);
}

/// The longest prefix (or suffix, with `keep_end`) of `text` at most `cols`
/// cells wide.
fn truncate(text: []const u8, cols: usize, keep_end: bool) []const u8 {
    if (terminal.textWidth(text) <= cols) return text;
    if (keep_end) {
        var start: usize = 0;
        while (terminal.textWidth(text[start..]) > cols) start += terminal.charLen(text[start..]);
        return text[start..];
    }
    var end: usize = 0;
    while (end < text.len) {
        const next = end + terminal.charLen(text[end..]);
        if (terminal.textWidth(text[0..next]) > cols) break;
        end = next;
    }
    return text[0..end];
}

// ====================================================================================================
// Tests
// ====================================================================================================

const Emulator = @import("../emulator/main.zig").Emulator;

test {
    _ = Cache;
    _ = Renderer;
    _ = @import("recovery_test.zig");
}

test "a change reloads once it has held for a check, and only once" {
    const a: Watch.Stamp = .{ .size = 1, .mtime = 1, .inode = 1 };
    const b: Watch.Stamp = .{ .size = 2, .mtime = 2, .inode = 1 };
    const c: Watch.Stamp = .{ .size = 3, .mtime = 3, .inode = 2 };
    var watch: Watch = .{ .path = "", .loaded = a, .pending = null, .checked = undefined };
    // Still being written: b, then c.
    try std.testing.expect(!watch.observe(b));
    try std.testing.expect(!watch.observe(c));
    // c held for a whole interval.
    try std.testing.expect(watch.observe(c));
    try std.testing.expect(!watch.observe(c));
    // A change that reverts before the next check doesn't reload.
    try std.testing.expect(!watch.observe(a));
    try std.testing.expect(!watch.observe(c));
}

test "the status line keeps the position visible and fits the width" {
    const gpa = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    const size: terminal.Size = .{ .cols = 16, .rows = 2, .cell_width = 1, .cell_height = 1 };
    try drawStatus(&output.writer, .{ .left = "a-long-file-name.pdf", .right = "3/9", .keep_end = false }, size);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "a-long-file  3/9") != null);

    output.clearRetainingCapacity();
    try drawStatus(&output.writer, .{ .left = ":typed\xc3\xa9 a long command", .right = "", .keep_end = true }, size);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\xc3\xa9 a long command") != null);

    // Wide characters take two cells, and invalid bytes one: nothing may
    // spill past the last column.
    output.clearRetainingCapacity();
    try drawStatus(&output.writer, .{ .left = "\xe6\x97\xa5\xe6\x9c\xac\xff-name-that-is-long", .right = "1/2", .keep_end = false }, size);
    const line = output.written()[std.mem.indexOf(u8, output.written(), terminal.style_reverse).? + terminal.style_reverse.len ..];
    const text = line[0..std.mem.indexOf(u8, line, terminal.style_reset).?];
    try std.testing.expectEqual(16, terminal.textWidth(text));
}

test "link hints follow a clipped viewport, preserve their codes, and leave no stale text" {
    const gpa = std.testing.allocator;
    const size: terminal.Size = .{ .cols = 80, .rows = 25, .cell_width = 10, .cell_height = 20 };
    const emulator: *Emulator = try .create(std.testing.io, gpa, size);
    defer emulator.destroy();
    const app = try gpa.create(App);
    defer gpa.destroy(app);
    app.init(std.testing.io, gpa, .{
        .path = "src/document/testdata/links.pdf",
        .page = 1,
        .dark = false,
        .watch = false,
        .medium = .direct,
    }, size, null);
    defer app.deinit();
    try emulator.output.writeAll(terminal.fullscreen_enter);
    try app.settle(&emulator.output);
    const original = try emulator.text(gpa);
    defer gpa.free(original);

    // A lookup can complete after Escape. No late result should reopen hints.
    try std.testing.expect(!app.input("f\x1b"));
    try std.testing.expect(app.renderer.step());
    app.expireInput(app.escape_started.?.addDuration(.fromSeconds(1)));
    try app.settle(&emulator.output);
    try std.testing.expectEqual(0, app.frame.labels.len);

    try std.testing.expect(!app.input("f"));
    try app.settle(&emulator.output);
    // Includes the link cut off by the bottom edge. The next link lies
    // below the view, and the file URL is not a followable destination.
    try std.testing.expectEqual(11, app.frame.labels.len);
    const text = try emulator.text(gpa);
    defer gpa.free(text);
    try std.testing.expect(std.mem.find(u8, text, "   a                                   s") != null);
    try std.testing.expect(std.mem.find(u8, text, "   ld") != null);

    try std.testing.expect(!app.input("l"));
    try app.settle(&emulator.output);
    const filtered = try emulator.text(gpa);
    defer gpa.free(filtered);
    try std.testing.expect(std.mem.find(u8, filtered, "   a                                   s") == null);
    try std.testing.expect(std.mem.find(u8, filtered, "   ld") != null);
    try std.testing.expect(!app.input("\x7f"));
    try app.settle(&emulator.output);
    const restored = try emulator.text(gpa);
    defer gpa.free(restored);
    try std.testing.expectEqualStrings(text, restored);

    try std.testing.expect(!app.input("\x1b"));
    app.expireInput(app.escape_started.?.addDuration(.fromSeconds(1)));
    try app.settle(&emulator.output);
    const after_cancel = try emulator.text(gpa);
    defer gpa.free(after_cancel);
    try std.testing.expectEqualStrings(original, after_cancel);

    try std.testing.expect(!app.input("f"));
    try app.settle(&emulator.output);
    try std.testing.expect(!app.input("a"));
    try app.settle(&emulator.output);
    // Named destination specifies 390 pt from the bottom of an 820 pt
    // page. A 10 pt margin keeps the heading visible below the top edge.
    try std.testing.expectEqual(viewer.Anchor{ .page = 1, .y = 420 }, app.state.anchor);
    try std.testing.expect(!app.input("j"));
    const departure = app.state.anchor;
    try std.testing.expect(!app.input("\x0f")); // Ctrl-O
    try std.testing.expectEqual(viewer.Anchor{ .page = 0, .y = 0 }, app.state.anchor);
    try std.testing.expect(!app.input("\t")); // Ctrl-I and Tab send the same byte.
    try std.testing.expectEqual(departure, app.state.anchor);
    try std.testing.expect(!app.input("\x0f"));
    // Ghostty can distinguish Ctrl-I from Tab. It can arrive in two reads,
    // and a key-up report must not trigger a second history movement.
    try std.testing.expect(!app.input("\x1b[105;"));
    try std.testing.expectEqual(viewer.Anchor{ .page = 0, .y = 0 }, app.state.anchor);
    try std.testing.expect(!app.input("5u\x1b[105;5:3u"));
    try std.testing.expectEqual(departure, app.state.anchor);
    try std.testing.expect(!app.input("\x0f"));

    try std.testing.expect(!app.input("f"));
    try app.settle(&emulator.output);
    try std.testing.expect(!app.input("s\r"));
    try std.testing.expect(app.url_to_open == null);
    try app.settle(&emulator.output);
    const narrow: terminal.Size = .{ .cols = 8, .rows = 2, .cell_width = 10, .cell_height = 20 };
    try emulator.resize(narrow);
    app.resize(narrow);
    try app.settle(&emulator.output);
    try std.testing.expect(!app.input("\r"));
    try std.testing.expect(app.url_to_open == null);
    const authority_only: terminal.Size = .{ .cols = "https://example.org".len, .rows = 2, .cell_width = 10, .cell_height = 20 };
    try emulator.resize(authority_only);
    app.resize(authority_only);
    try app.settle(&emulator.output);
    const clipped_preview = try emulator.text(gpa);
    defer gpa.free(clipped_preview);
    try std.testing.expect(std.mem.find(u8, clipped_preview, "https://example.org") != null);
    try std.testing.expect(std.mem.find(u8, clipped_preview, "URL cut") != null);
    try emulator.resize(size);
    app.resize(size);
    try app.settle(&emulator.output);
    const preview = try emulator.text(gpa);
    defer gpa.free(preview);
    const url = "https://example.org/guide?chapter=2&part=a";
    try std.testing.expect(std.mem.find(u8, preview, url) != null);
    try std.testing.expect(!app.input("\r"));
    try std.testing.expectEqualStrings(url, app.url_to_open.?);
    try app.settle(&emulator.output);
    const after_confirm = try emulator.text(gpa);
    defer gpa.free(after_confirm);
    try std.testing.expectEqualStrings(original, after_confirm);
    try std.testing.expect(app.link_arena == null);

    try std.testing.expect(!app.input("f"));
    app.renderer.reload();
    try app.settle(&emulator.output);
    try std.testing.expectEqual(0, app.frame.labels.len);

    // With one content cell, every hint overlaps every other. Tab still
    // reaches the web link and its destination is the same as in a wide view.
    const tiny: terminal.Size = .{ .cols = 1, .rows = 2, .cell_width = 10, .cell_height = 20 };
    try emulator.resize(tiny);
    app.resize(tiny);
    try std.testing.expect(!app.input("f"));
    try app.settle(&emulator.output);
    try std.testing.expectEqual(1, app.frame.labels.len);
    try std.testing.expect(!app.input("\ta"));
    try app.settle(&emulator.output);
    try std.testing.expectEqualStrings(url, app.frame.preview.?.uri);
}

test "EPUB search crosses chapters, highlights the match, and can be canceled or repeated" {
    const gpa = std.testing.allocator;
    const size: terminal.Size = .{ .cols = 80, .rows = 25, .cell_width = 10, .cell_height = 20 };
    const emulator: *Emulator = try .create(std.testing.io, gpa, size);
    defer emulator.destroy();
    const app = try gpa.create(App);
    defer gpa.destroy(app);
    app.init(std.testing.io, gpa, .{
        .path = "src/document/testdata/chapters.epub",
        .page = 1,
        .dark = false,
        .watch = false,
        .medium = .direct,
    }, size, null);
    defer app.deinit();
    try app.settle(&emulator.output);
    try std.testing.expect(!app.input("/Blue chapter\r\x1b"));
    app.expireInput(app.escape_started.?.addDuration(.fromSeconds(1)));
    try app.settle(&emulator.output);
    try std.testing.expect(app.state.search_selection == null);
    try std.testing.expectEqual(viewer.Anchor{ .page = 0, .y = 0 }, app.state.anchor);

    try std.testing.expect(!app.input("n"));
    try app.settle(&emulator.output);
    try std.testing.expectEqual(2, app.state.search_selection.?.page);
    const selected = app.state.anchor;
    const with_highlight = try emulator.screenshot(gpa);
    defer gpa.free(with_highlight.pixels);

    // A status-only change should not resend either page or highlight placements.
    var commands: std.Io.Writer.Allocating = .init(gpa);
    defer commands.deinit();
    try std.testing.expect(!app.input(":"));
    try app.draw(&commands.writer);
    try std.testing.expect(std.mem.find(u8, commands.written(), "\x1b_Ga=p") == null);
    try std.testing.expect(!app.input("noh\r"));
    try app.settle(&emulator.output);
    const without = try emulator.screenshot(gpa);
    defer gpa.free(without.pixels);
    try std.testing.expectEqual(selected, app.state.anchor);
    try std.testing.expect(!std.mem.eql(u8, with_highlight.pixels, without.pixels));

    try std.testing.expect(!app.input("N"));
    try app.settle(&emulator.output);
    try std.testing.expectEqual(selected, app.state.anchor);
    try std.testing.expectEqual(2, app.state.search_selection.?.page);
    const again = try emulator.screenshot(gpa);
    defer gpa.free(again.pixels);
    try std.testing.expectEqualSlices(u8, with_highlight.pixels, again.pixels);
}

test "search repeats move from the selected match after scrolling or rapid input" {
    const gpa = std.testing.allocator;
    const size: terminal.Size = .{ .cols = 80, .rows = 25, .cell_width = 10, .cell_height = 20 };
    const emulator = try Emulator.create(std.testing.io, gpa, size);
    defer emulator.destroy();
    const app = try gpa.create(App);
    defer gpa.destroy(app);
    app.init(std.testing.io, gpa, .{
        .path = "src/document/testdata/links.pdf",
        .page = 1,
        .dark = false,
        .watch = false,
        .medium = .direct,
    }, size, null);
    defer app.deinit();
    try app.settle(&emulator.output);
    try std.testing.expect(!app.input("/Section\r"));
    try app.settle(&emulator.output);
    const first = app.state.search_selection.?;
    // The fixture draws Sections 1 and 2 next to one another on page one.
    try std.testing.expectEqual(0, first.page);
    try std.testing.expectEqual(0, first.part);
    try std.testing.expect(!app.input("2G"));
    try std.testing.expectEqual(1, app.state.anchor.page);
    try std.testing.expect(!app.input("n"));
    try app.settle(&emulator.output);
    const second = app.state.search_selection.?;
    try std.testing.expectEqual(0, second.page);
    try std.testing.expectEqual(1, second.part);

    try std.testing.expect(!app.input("2GN"));
    try app.settle(&emulator.output);
    try std.testing.expectEqual(first, app.state.search_selection.?);

    try std.testing.expect(!app.input("2G/Section\rn"));
    try app.settle(&emulator.output);
    try std.testing.expectEqual(second, app.state.search_selection.?);
    // Both repeat keys arrive before the worker sees the new query.
    try std.testing.expect(!app.input("2G/Section\rnN"));
    try app.settle(&emulator.output);
    try std.testing.expectEqual(first, app.state.search_selection.?);

    try std.testing.expect(!app.input("/ Section \r"));
    try std.testing.expectEqualStrings(" Section ", app.state.search_request.?.query.text());
}

test "shows the document, and keys move through it" {
    const gpa = std.testing.allocator;
    const size: terminal.Size = .{ .cols = 40, .rows = 11, .cell_width = 10, .cell_height = 20 };
    const emulator: *Emulator = try .create(std.testing.io, gpa, size);
    defer emulator.destroy();
    const app = try gpa.create(App);
    defer gpa.destroy(app);
    app.init(std.testing.io, gpa, .{
        .path = "src/document/testdata/red-square.pdf",
        .page = 1,
        .dark = false,
        .watch = false,
        .medium = .shared_memory,
    }, size, null);
    defer app.deinit();
    try app.settle(&emulator.output);

    // 400 px wide view: the 200x100 pt page at 2x, so the red square spans
    // x 40..120 and y 80..160.
    const screen = try emulator.screenshot(gpa);
    defer gpa.free(screen.pixels);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, screen.pixel(80, 120));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, screen.pixel(300, 40));
    const text = try emulator.text(gpa);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "red-square.pdf") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "1/1  100%") != null);

    // Dark mode inverts the page; the `i` arrives split from nothing, and
    // an arrow key split across two inputs is still one key.
    try std.testing.expect(!app.input("\x1b["));
    try std.testing.expect(!app.input("Bi"));
    try app.settle(&emulator.output);
    const dark = try emulator.screenshot(gpa);
    defer gpa.free(dark.pixels);
    try std.testing.expectEqual([4]u8{ 0, 255, 255, 255 }, dark.pixel(80, 120));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, dark.pixel(300, 40));
    try std.testing.expect(app.input("q"));
}

test "prefetched tiles wait for a visible placement without redrawing" {
    const gpa = std.testing.allocator;
    const size: terminal.Size = .{ .cols = 60, .rows = 4, .cell_width = 10, .cell_height = 20 };
    const emulator: *Emulator = try .create(std.testing.io, gpa, size);
    defer emulator.destroy();
    const app = try gpa.create(App);
    defer gpa.destroy(app);
    app.init(std.testing.io, gpa, .{
        .path = "src/document/testdata/odd-sizes.pdf",
        .page = 1,
        .dark = false,
        .watch = false,
        .medium = .direct,
    }, size, null);
    defer app.deinit();
    try app.settle(&emulator.output);

    // The first scroll requests page two, but its top still lies below the view.
    try std.testing.expect(!app.input("j"));
    try app.draw(&emulator.output);
    try std.testing.expect(app.renderer.step());
    try app.collect();
    try std.testing.expect(!app.dirty);

    // Advance onto page two and draw without letting the renderer run again.
    try std.testing.expect(!app.input("j"));
    try app.draw(&emulator.output);
    const screen = try emulator.screenshot(gpa);
    defer gpa.free(screen.pixels);
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, screen.pixel(300, 48));
}

test "a tile cache allocation failure preserves a reload in the same batch" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    const app = try gpa.create(App);
    defer gpa.destroy(app);
    app.init(std.testing.io, gpa, .{
        .path = "src/document/testdata/red-square.pdf",
        .page = 1,
        .dark = false,
        .watch = false,
        .medium = .direct,
    }, .{ .cols = 40, .rows = 11, .cell_width = 10, .cell_height = 20 }, null);
    defer app.deinit();
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();

    try std.testing.expect(app.renderer.step());
    try app.collect();
    try app.draw(&output.writer);
    try std.testing.expect(app.renderer.step());
    app.renderer.reload();
    try std.testing.expect(app.renderer.step());

    // Collection can move both results, but caching the first tile will fail.
    try app.results.ensureTotalCapacity(gpa, 2);
    failing.fail_index = failing.alloc_index;
    try app.collect();
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(2, app.state.document.generation);
}

test "an empty file stays open and reloads when PDF content arrives" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "empty.pdf", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(io, "empty.pdf", gpa);
    defer gpa.free(path);

    const size: terminal.Size = .{ .cols = 40, .rows = 11, .cell_width = 10, .cell_height = 20 };
    const emulator: *Emulator = try .create(io, gpa, size);
    defer emulator.destroy();
    const app = try gpa.create(App);
    defer gpa.destroy(app);
    app.init(io, gpa, .{
        .path = path,
        .page = 1,
        .dark = false,
        .watch = true,
        .medium = .shared_memory,
    }, size, null);
    defer app.deinit();
    var watch: Watch = .init(io, path);
    try app.settle(&emulator.output);
    try std.testing.expectEqual(null, app.open_error);
    try std.testing.expectEqualStrings("no pages", app.frame.status().right);
    try std.testing.expectEqual(0, app.frame.slices().len);
    try std.testing.expect(!app.input("jG+-"));
    try app.settle(&emulator.output);

    try tmp.dir.writeFile(io, .{ .sub_path = "empty.pdf", .data = @embedFile("../document/testdata/red-square.pdf") });
    const current = Watch.stamp(io, path).?;
    try std.testing.expect(!watch.observe(current));
    try std.testing.expect(watch.observe(current));
    app.renderer.reload();
    try app.settle(&emulator.output);
    try std.testing.expectEqual(null, app.open_error);
    try std.testing.expectEqual(1, app.page_sizes.len);
    const screen = try emulator.screenshot(gpa);
    defer gpa.free(screen.pixels);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, screen.pixel(80, 120));
}

test "navigation sequences survive every input split without closing commands" {
    const gpa = std.testing.allocator;
    const size: terminal.Size = .{ .cols = 40, .rows = 3, .cell_width = 10, .cell_height = 20 };
    const reference = try gpa.create(App);
    defer gpa.destroy(reference);
    const fragmented = try gpa.create(App);
    defer gpa.destroy(fragmented);
    const pages = [_]document.Size{.{ .width = 200, .height = 1000 }};
    const offsets = [_]f64{0};
    for ([_][]const u8{ "\x1b[A", "\x1b[B", "\x1bOC", "\x1b[1;5D", "\x1b[5~", "\x1b[6~", "\x1b[H", "\x1b[F" }) |sequence| {
        for ([_]bool{ false, true }) |command| {
            for (1..sequence.len) |split| {
                for ([_]*App{ reference, fragmented }) |app| {
                    app.init(std.testing.io, gpa, .{ .path = "unused.pdf", .page = 1, .dark = false, .watch = false, .medium = .direct }, size, null);
                    _ = app.state.update(.{ .document = .{ .generation = 1, .page_sizes = &pages, .page_offsets = &offsets } });
                    try std.testing.expect(!app.input("j"));
                    if (command) try std.testing.expect(!app.input(":zoom 200"));
                }
                defer reference.deinit();
                defer fragmented.deinit();
                try std.testing.expect(!reference.input(sequence));
                try std.testing.expect(!fragmented.input(sequence[0..split]));
                try std.testing.expect(!fragmented.input(sequence[split..]));
                try std.testing.expectEqual(reference.state.anchor, fragmented.state.anchor);
                try std.testing.expectEqual(reference.state.pan_x, fragmented.state.pan_x);
                try std.testing.expectEqual(reference.state.prompt, fragmented.state.prompt);
                try std.testing.expectEqual(0, fragmented.pending_input_len);
                if (command) {
                    try std.testing.expect(!fragmented.input("\r"));
                    try std.testing.expectEqual(2, fragmented.state.zoom);
                }
            }
        }
    }
}

test "standalone Escape closes the command only after its deadline" {
    const gpa = std.testing.allocator;
    const app = try gpa.create(App);
    defer gpa.destroy(app);
    app.init(std.testing.io, gpa, .{ .path = "unused.pdf", .page = 1, .dark = false, .watch = false, .medium = .direct }, .{ .cols = 40, .rows = 3, .cell_width = 10, .cell_height = 20 }, null);
    defer app.deinit();
    try std.testing.expect(!app.input(":zoom 200\x1b"));
    const started = app.escape_started.?;
    app.expireInput(started.addDuration(.fromMilliseconds(escape_timeout_ms - 1)));
    try std.testing.expect(app.state.prompt == .command);
    app.expireInput(started.addDuration(.fromMilliseconds(escape_timeout_ms)));
    try std.testing.expect(app.state.prompt == .none);
    try std.testing.expectEqual(0, app.pending_input_len);
    try std.testing.expect(app.input("q"));
}

test "control-bearing filenames cannot change the terminal through the status line" {
    const gpa = std.testing.allocator;
    const size: terminal.Size = .{ .cols = 80, .rows = 3, .cell_width = 1, .cell_height = 1 };
    const emulator: *Emulator = try .create(std.testing.io, gpa, size);
    defer emulator.destroy();
    try emulator.output.writeAll("sentinel");
    var state: viewer.State = .init("report\x1b[2J\r\n\x07\x7f\xc2\x9b\xff.pdf", size, false, 1);
    var frame: viewer.Frame = undefined;
    state.layout(&frame);
    try drawStatus(&emulator.output, frame.status(), size);
    try emulator.output.flush();
    const text = try emulator.text(gpa);
    defer gpa.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "sentinel"));
    try std.testing.expect(std.mem.indexOf(u8, text, "report?[2J??????.pdf") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "loading...") != null);
}

test "tiles stay on screen through a resize that keeps them" {
    const gpa = std.testing.allocator;
    const size: terminal.Size = .{ .cols = 40, .rows = 11, .cell_width = 10, .cell_height = 20 };
    const emulator: *Emulator = try .create(std.testing.io, gpa, size);
    defer emulator.destroy();
    const app = try gpa.create(App);
    defer gpa.destroy(app);
    app.init(std.testing.io, gpa, .{
        .path = "src/document/testdata/red-square.pdf",
        .page = 1,
        .dark = false,
        .watch = false,
        .medium = .shared_memory,
    }, size, null);
    defer app.deinit();
    try app.settle(&emulator.output);

    // Only the height changes, so the same tiles are wanted and are placed
    // again without being uploaded again.
    const taller: terminal.Size = .{ .cols = 40, .rows = 12, .cell_width = 10, .cell_height = 20 };
    try emulator.resize(taller);
    app.resize(taller);
    try app.settle(&emulator.output);
    const screen = try emulator.screenshot(gpa);
    defer gpa.free(screen.pixels);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, screen.pixel(80, 120));
}

test "images render in the terminal, survive failed reloads, and reload across formats" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "image", .data = @embedFile("../document/testdata/red-square.png") });
    const path = try tmp.dir.realPathFileAlloc(io, "image", gpa);
    defer gpa.free(path);
    const size: terminal.Size = .{ .cols = 40, .rows = 11, .cell_width = 10, .cell_height = 20 };
    const emulator: *Emulator = try .create(io, gpa, size);
    defer emulator.destroy();
    const app = try gpa.create(App);
    defer gpa.destroy(app);
    app.init(io, gpa, .{ .path = path, .page = 1, .dark = false, .watch = true, .medium = .direct }, size, null);
    defer app.deinit();
    try app.settle(&emulator.output);
    try std.testing.expectEqual(null, app.open_error);
    const screen = try emulator.screenshot(gpa);
    defer gpa.free(screen.pixels);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, screen.pixel(80, 120));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, screen.pixel(300, 40));
    try std.testing.expect(!app.input("i++j"));
    try app.settle(&emulator.output);
    const generation = app.state.document.generation;
    const zoomed = try emulator.screenshot(gpa);
    defer gpa.free(zoomed.pixels);

    try tmp.dir.writeFile(io, .{ .sub_path = "image", .data = @embedFile("../document/testdata/red-square.png")[0..40] });
    app.renderer.reload();
    try app.settle(&emulator.output);
    try std.testing.expectEqual(generation, app.state.document.generation);
    try std.testing.expectEqual(null, app.open_error);
    const unchanged = try emulator.screenshot(gpa);
    defer gpa.free(unchanged.pixels);
    try std.testing.expectEqualSlices(u8, zoomed.pixels, unchanged.pixels);

    // Failed loads leave the previous image available even for uncached tiles.
    try std.testing.expect(!app.input("=igg"));
    try app.settle(&emulator.output);
    const retained = try emulator.screenshot(gpa);
    defer gpa.free(retained.pixels);
    try std.testing.expectEqualSlices(u8, screen.pixels, retained.pixels);

    for ([_][]const u8{
        @embedFile("../document/testdata/red-square.pdf"),
        @embedFile("../document/testdata/red-square.png"),
    }, 1..) |bytes, index| {
        try tmp.dir.writeFile(io, .{ .sub_path = "image", .data = bytes });
        app.renderer.reload();
        try app.settle(&emulator.output);
        try std.testing.expectEqual(generation + @as(u32, @intCast(index)), app.state.document.generation);
        const reloaded = try emulator.screenshot(gpa);
        defer gpa.free(reloaded.pixels);
        try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, reloaded.pixel(80, 120));
    }
}
