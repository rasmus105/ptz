//! Renders tiles on a thread of its own, and owns the document while doing
//! so: every engine call happens here, so the UI never waits on the engine.
//!
//! The UI requests reloads, link lookups, search and tiles. It picks up `Result`s
//! with `collect`; `wake_fd` gets a byte whenever new results are ready. `step`
//! does one unit of work on the calling thread. The thread only loops over
//! it, and tests call it directly to run deterministically.

// std
const std = @import("std");

// project
const graphics = @import("../graphics/main.zig");
const document = @import("../document/main.zig");
const viewer = @import("../viewer/main.zig");

// local
const Search = @import("Search.zig");

// aliases
const Renderer = @This();
const Tile = viewer.Tile;
const search = viewer.search;

// ====================================================================================================
// Types
// ====================================================================================================

pub const Result = union(enum) {
    /// The document was (re)loaded; owns the slices. See `viewer.Document`.
    opened: struct { generation: u32, page_sizes: []document.Size, page_offsets: []f64 },
    open_failed: document.Error,
    links: struct { view: viewer.LinkResult, arena: std.heap.ArenaAllocator },
    search: struct { page: ?search.Page = null, navigation: ?search.Navigation = null },
    tile: struct { tile: Tile, encoded: graphics.Encoded },
    render_failed: Tile,

    pub fn deinit(result: Result, gpa: std.mem.Allocator) void {
        switch (result) {
            .opened => |opened| {
                gpa.free(opened.page_sizes);
                gpa.free(opened.page_offsets);
            },
            .tile => |tile| tile.encoded.deinit(gpa),
            .links => |links| links.arena.deinit(),
            .search => |found| if (found.page) |page| gpa.free(page.parts),
            .open_failed, .render_failed => {},
        }
    }
};

// ====================================================================================================
// Fields
// ====================================================================================================

io: std.Io,
gpa: std.mem.Allocator,
path: []const u8,
medium: graphics.Medium,
wake_fd: ?std.posix.fd_t,
thread: ?std.Thread,
/// The newest link lookup, or 0 when canceled. Checked between engine calls.
link_id: std.atomic.Value(u64),

mutex: std.Io.Mutex,
condition: std.Io.Condition,
// Guarded by `mutex`:
reload_requested: bool,
/// A reload or lookup is running without the mutex held.
loading: bool,
link_request: ?viewer.LinkRequest,
search_scan: ?Search.Scan = null,
search_viewport: ?search.Viewport = null,
searching_page: ?struct { id: u64, page: u32 } = null,
/// Tiles to render, most urgent first. Replaced as a whole by `want`.
wanted: [viewer.tiles_max]Tile,
wanted_len: u32,
wanted_visible_len: u32 = 0,
/// The tile being rendered, which `want` must not queue again.
rendering: ?Tile,
results: std.ArrayList(Result),
stopping: bool,

// Only used by whoever runs `step`:
doc: ?document.Document,
/// Counts successful loads; tiles of any other generation are skipped.
generation: u32,
/// Cache the last result and pages without hits for the current query. The
/// engine separately caches its structured text, which survives query edits.
search_generation: u32 = 0,
search_query_id: u64 = 0,
search_empty_pages: []u8 = &.{},
last_match_page: ?u32 = null,
last_matches: [search.parts_max]document.MatchPart = undefined,
last_matches_len: usize = 0,
last_match_failed: bool = false,

// ====================================================================================================
// Public API
// ====================================================================================================

/// The first `step` loads the document.
pub fn init(
    renderer: *Renderer,
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    medium: graphics.Medium,
    wake_fd: ?std.posix.fd_t,
) void {
    renderer.* = .{
        .io = io,
        .gpa = gpa,
        .path = path,
        .medium = medium,
        .wake_fd = wake_fd,
        .thread = null,
        .link_id = .init(0),
        .mutex = .init,
        .condition = .init,
        .reload_requested = true,
        .loading = false,
        .link_request = null,
        .wanted = undefined,
        .wanted_len = 0,
        .rendering = null,
        .results = .empty,
        .stopping = false,
        .doc = null,
        .generation = 0,
    };
}

pub fn deinit(renderer: *Renderer) void {
    if (renderer.thread) |thread| {
        renderer.mutex.lockUncancelable(renderer.io);
        renderer.stopping = true;
        renderer.link_id.store(0, .monotonic);
        renderer.condition.signal(renderer.io);
        renderer.mutex.unlock(renderer.io);
        thread.join();
    }
    if (renderer.doc) |*doc| doc.close();
    renderer.gpa.free(renderer.search_empty_pages);
    for (renderer.results.items) |result| result.deinit(renderer.gpa);
    renderer.results.deinit(renderer.gpa);
    renderer.* = undefined;
}

/// Runs `step` on a new thread until `deinit`.
pub fn start(renderer: *Renderer) std.Thread.SpawnError!void {
    std.debug.assert(renderer.thread == null);
    renderer.thread = try std.Thread.spawn(.{}, run, .{renderer});
}

/// Loads the document again, keeping the current one if that fails.
pub fn reload(renderer: *Renderer) void {
    renderer.mutex.lockUncancelable(renderer.io);
    defer renderer.mutex.unlock(renderer.io);
    renderer.reload_requested = true;
    renderer.condition.signal(renderer.io);
}

pub fn findLinks(renderer: *Renderer, request: viewer.LinkRequest) void {
    renderer.mutex.lockUncancelable(renderer.io);
    defer renderer.mutex.unlock(renderer.io);
    renderer.link_request = request;
    renderer.link_id.store(request.id, .monotonic);
    renderer.condition.signal(renderer.io);
}

pub fn cancelLinks(renderer: *Renderer) void {
    renderer.mutex.lockUncancelable(renderer.io);
    defer renderer.mutex.unlock(renderer.io);
    renderer.link_request = null;
    renderer.link_id.store(0, .monotonic);
}

pub fn findText(renderer: *Renderer, request: search.Request) void {
    renderer.mutex.lockUncancelable(renderer.io);
    defer renderer.mutex.unlock(renderer.io);
    renderer.search_scan = .init(request);
    renderer.search_viewport = null;
    renderer.condition.signal(renderer.io);
}

pub fn cancelText(renderer: *Renderer) void {
    renderer.mutex.lockUncancelable(renderer.io);
    defer renderer.mutex.unlock(renderer.io);
    renderer.search_scan = null;
    renderer.search_viewport = null;
}

pub fn wantSearchPages(renderer: *Renderer, viewport: search.Viewport) void {
    renderer.mutex.lockUncancelable(renderer.io);
    defer renderer.mutex.unlock(renderer.io);
    var pending: search.Viewport = .{ .query = viewport.query, .pages = undefined, .len = 0 };
    pages: for (viewport.pages[0..viewport.len]) |page| {
        if (renderer.searching_page) |running|
            if (running.id == viewport.query.id and running.page == page) continue;
        for (renderer.results.items) |result| {
            if (result == .search) if (result.search.page) |done| {
                if (done.query_id == viewport.query.id and done.generation == viewport.query.generation and done.number == page)
                    continue :pages;
            };
        }
        pending.pages[pending.len] = page;
        pending.len += 1;
    }
    renderer.search_viewport = if (pending.len > 0) pending else null;
    if (pending.len > 0) renderer.condition.signal(renderer.io);
}

/// Replaces the tiles to render, most urgent first. Tiles being rendered or
/// waiting to be collected are left out, so they aren't rendered twice.
pub fn want(renderer: *Renderer, tiles: []const Tile, visible_len: usize) void {
    std.debug.assert(tiles.len <= renderer.wanted.len);
    renderer.mutex.lockUncancelable(renderer.io);
    defer renderer.mutex.unlock(renderer.io);
    renderer.wanted_len = 0;
    renderer.wanted_visible_len = 0;
    next: for (tiles, 0..) |tile, i| {
        if (renderer.rendering != null and std.meta.eql(renderer.rendering.?, tile)) continue;
        for (renderer.results.items) |result| switch (result) {
            .tile => |done| if (std.meta.eql(done.tile, tile)) continue :next,
            .render_failed => |failed| if (std.meta.eql(failed, tile)) continue :next,
            .opened, .open_failed, .links, .search => {},
        };
        renderer.wanted[renderer.wanted_len] = tile;
        renderer.wanted_len += 1;
        if (i < visible_len) renderer.wanted_visible_len += 1;
    }
    renderer.condition.signal(renderer.io);
}

/// Moves finished results into `results`, which must be empty and use the
/// renderer's allocator. The caller frees them. On allocation failure, leaves
/// them queued so the caller can retry or shut down.
pub fn collect(renderer: *Renderer, results: *std.ArrayList(Result)) std.mem.Allocator.Error!void {
    std.debug.assert(results.items.len == 0);
    renderer.mutex.lockUncancelable(renderer.io);
    defer renderer.mutex.unlock(renderer.io);
    // Keep the worker's reserved slot even if collection happens during a load.
    try results.appendSlice(renderer.gpa, renderer.results.items);
    renderer.results.clearRetainingCapacity();
}

/// Whether all requested work has finished and its results were collected.
/// Unlike an empty queue, this also accounts for an in-progress reload.
pub fn idle(renderer: *Renderer) bool {
    renderer.mutex.lockUncancelable(renderer.io);
    defer renderer.mutex.unlock(renderer.io);
    return !renderer.reload_requested and !renderer.loading and
        renderer.link_request == null and renderer.wanted_len == 0 and
        renderer.search_scan == null and renderer.search_viewport == null and
        renderer.rendering == null and renderer.results.items.len == 0;
}

/// Search yields between pages and takes priority over speculative tiles.
/// Returns false if there was nothing to do.
pub fn step(renderer: *Renderer) bool {
    renderer.mutex.lockUncancelable(renderer.io);
    // Make room for the result first: dropping a load's result would leave
    // the UI waiting for a generation it never hears about.
    renderer.results.ensureUnusedCapacity(renderer.gpa, 1) catch {
        renderer.mutex.unlock(renderer.io);
        return false;
    };
    const reload_requested = renderer.reload_requested;
    renderer.reload_requested = false;
    const link_request = if (reload_requested) null else renderer.link_request;
    if (link_request != null) renderer.link_request = null;
    const can_search = !reload_requested and link_request == null and renderer.wanted_visible_len == 0;
    var scan = if (can_search) renderer.search_scan else null;
    var query: ?search.Query = null;
    var page: u32 = 0;
    if (scan) |active| {
        query = active.request.query;
        page = active.page;
    } else if (can_search) {
        if (renderer.search_viewport) |*viewport| {
            query = viewport.query;
            page = viewport.pages[0];
            std.mem.copyForwards(u32, viewport.pages[0 .. viewport.len - 1], viewport.pages[1..viewport.len]);
            viewport.len -= 1;
            if (viewport.len == 0) renderer.search_viewport = null;
        }
    }
    if (query) |current| renderer.searching_page = .{ .id = current.id, .page = page };
    renderer.loading = reload_requested or link_request != null or query != null;
    if (!renderer.loading and renderer.wanted_len > 0) {
        renderer.rendering = renderer.wanted[0];
        std.mem.copyForwards(Tile, renderer.wanted[0 .. renderer.wanted_len - 1], renderer.wanted[1..renderer.wanted_len]);
        renderer.wanted_len -= 1;
        renderer.wanted_visible_len -|= 1;
    }
    const tile = renderer.rendering;
    renderer.mutex.unlock(renderer.io);

    const result = if (reload_requested)
        renderer.load()
    else if (link_request) |request|
        renderer.readLinks(request)
    else if (query) |current|
        renderer.readMatches(current, page, if (scan) |*active| active else null)
    else if (tile) |t|
        renderer.render(t)
    else
        return false;

    renderer.mutex.lockUncancelable(renderer.io);
    renderer.rendering = null;
    renderer.searching_page = null;
    renderer.loading = false;
    var publish = true;
    if (scan) |active| {
        publish = renderer.search_scan != null and renderer.search_scan.?.request.id == active.request.id;
        if (publish) {
            renderer.search_scan = if (result == null and active.request.query.generation == renderer.generation) active else null;
        }
    }
    if (result) |r| {
        if (publish) renderer.results.appendAssumeCapacity(r) else r.deinit(renderer.gpa);
    }
    renderer.mutex.unlock(renderer.io);
    if (result != null and publish) if (renderer.wake_fd) |fd| {
        _ = std.c.write(fd, "t", 1);
    };
    return true;
}

// ====================================================================================================
// Private Functions
// ====================================================================================================

fn run(renderer: *Renderer) void {
    while (true) {
        renderer.mutex.lockUncancelable(renderer.io);
        while (!renderer.stopping and !renderer.reload_requested and renderer.link_request == null and renderer.wanted_len == 0 and
            renderer.search_scan == null and renderer.search_viewport == null)
        {
            renderer.condition.waitUncancelable(renderer.io, &renderer.mutex);
        }
        const stopping = renderer.stopping;
        renderer.mutex.unlock(renderer.io);
        if (stopping) return;
        _ = renderer.step();
    }
}

fn readMatches(renderer: *Renderer, query: search.Query, page: u32, scan: ?*Search.Scan) ?Result {
    if (query.generation != renderer.generation) return null;
    const doc = &(renderer.doc orelse return null);
    if (renderer.search_query_id != query.id or renderer.search_generation != query.generation) {
        renderer.search_query_id = query.id;
        renderer.search_generation = query.generation;
        renderer.last_match_page = null;
        // One bit per page avoids reopening empty pages on n/N or wrapping.
        // It's an optional optimization for large documents and low memory.
        const bytes = @min((@as(usize, doc.pageCount()) + 7) / 8, 128 * 1024);
        if (renderer.search_empty_pages.len != bytes) {
            renderer.gpa.free(renderer.search_empty_pages);
            renderer.search_empty_pages = renderer.gpa.alloc(u8, bytes) catch &.{};
        }
        @memset(renderer.search_empty_pages, 0);
    }
    const byte_index = page / 8;
    const bit = @as(u8, 1) << @as(u3, @truncate(page));
    const known_empty = byte_index < renderer.search_empty_pages.len and renderer.search_empty_pages[byte_index] & bit != 0;
    var failed = false;
    var parts: []const document.MatchPart = &.{};
    if (!known_empty) {
        if (renderer.last_match_page != page) {
            renderer.last_match_page = page;
            renderer.last_match_failed = false;
            const matches = doc.searchPage(page, query.text(), &renderer.last_matches) catch document.PageMatches{
                .parts = renderer.last_matches[0..0],
                .truncated = true,
            };
            renderer.last_matches_len = matches.parts.len;
            renderer.last_match_failed = matches.truncated;
        }
        failed = renderer.last_match_failed;
        parts = renderer.last_matches[0..renderer.last_matches_len];
        if (!failed and parts.len == 0 and byte_index < renderer.search_empty_pages.len)
            renderer.search_empty_pages[byte_index] |= bit;
    }

    var result: Result = .{ .search = .{} };
    if (scan) |navigation| {
        const match: ?search.Navigation.Match = switch (navigation.advance(parts, doc.pageCount(), failed)) {
            .more => return null,
            .found => |index| .{ .page = page, .part = index, .area = parts[index].area },
            .missing => null,
        };
        result.search.navigation = .{
            .id = navigation.request.id,
            .match = match,
            .wrapped = navigation.wrapped,
            .incomplete = navigation.incomplete,
        };
        if (match == null) return result;
    }
    const copy = renderer.gpa.dupe(document.MatchPart, parts) catch {
        if (result.search.navigation) |*nav| {
            nav.incomplete = true;
            return result;
        }
        return null;
    };
    result.search.page = .{
        .query_id = query.id,
        .generation = query.generation,
        .number = page,
        .parts = copy,
    };
    return result;
}

fn load(renderer: *Renderer) Result {
    const mode: document.Document.OpenMode = if (renderer.doc == null) .initial else .replacement;
    var doc = document.Document.openSnapshot(renderer.io, renderer.gpa, renderer.path, mode) catch |err|
        return .{ .open_failed = err };
    const page_count = doc.pageCount();
    const page_sizes = renderer.gpa.alloc(document.Size, page_count) catch {
        doc.close();
        return .{ .open_failed = error.OutOfMemory };
    };
    const page_offsets = renderer.gpa.alloc(f64, page_count) catch {
        renderer.gpa.free(page_sizes);
        doc.close();
        return .{ .open_failed = error.OutOfMemory };
    };
    var offset: f64 = 0;
    for (page_sizes, page_offsets, 0..) |*size, *page_offset, page| {
        size.* = doc.pageSize(@intCast(page)) catch .{ .width = document.page_size_min, .height = document.page_size_min };
        page_offset.* = offset;
        offset += size.height;
    }
    if (renderer.doc) |*old| old.close();
    renderer.doc = doc;
    renderer.generation += 1;
    return .{ .opened = .{ .generation = renderer.generation, .page_sizes = page_sizes, .page_offsets = page_offsets } };
}

fn readLinks(renderer: *Renderer, request: viewer.LinkRequest) ?Result {
    if (request.generation != renderer.generation) return null;
    const doc = &(renderer.doc orelse return null);
    var arena: std.heap.ArenaAllocator = .init(renderer.gpa);
    var results: std.ArrayList(document.Link) = .empty;
    var incomplete = request.incomplete;
    for (request.regions[0..request.len]) |region| {
        if (renderer.link_id.load(.monotonic) != request.id) {
            arena.deinit();
            return null;
        }
        doc.appendLinks(region.page, region.area, arena.allocator(), &results, viewer.links_max) catch |err| {
            incomplete = true;
            if (err == error.OutOfMemory or err == error.FileTooBig) break;
        };
    }
    std.mem.sort(document.Link, results.items, {}, struct {
        fn lessThan(_: void, a: document.Link, b: document.Link) bool {
            if (a.page != b.page) return a.page < b.page;
            if (a.area.y0 != b.area.y0) return a.area.y0 < b.area.y0;
            return a.area.x0 < b.area.x0;
        }
    }.lessThan);
    return .{ .links = .{
        .view = .{ .id = request.id, .links = results.items, .incomplete = incomplete },
        .arena = arena,
    } };
}

/// Renders and encodes `tile`, or returns null if it belongs to another
/// load of the document than the current one.
fn render(renderer: *Renderer, tile: Tile) ?Result {
    if (tile.generation != renderer.generation) return null;
    const doc = &(renderer.doc orelse return null);

    // Render straight into what will be uploaded.
    const canvas = graphics.Canvas.init(renderer.gpa, renderer.medium, tile.width(), tile.height()) catch
        return .{ .render_failed = tile };
    doc.render(tile.page, .{
        .page_width = tile.page_width,
        .page_height = tile.page_height,
        .x = tile.left(),
        .y = tile.top(),
    }, .{ .width = canvas.width, .height = canvas.height, .pixels = canvas.pixels }) catch {
        canvas.deinit(renderer.gpa);
        return .{ .render_failed = tile };
    };
    if (tile.dark) invert(canvas.pixels);
    const encoded = canvas.finish(renderer.gpa) catch return .{ .render_failed = tile };
    return .{ .tile = .{ .tile = tile, .encoded = encoded } };
}

/// Inverts the colour of RGBA pixels, keeping alpha.
fn invert(pixels: []u8) void {
    std.debug.assert(pixels.len % 4 == 0);
    const words: []align(1) u32 = std.mem.bytesAsSlice(u32, pixels);
    const mask = std.mem.nativeToLittle(u32, 0x00ff_ffff);
    for (words) |*word| word.* ^= mask;
}

// ====================================================================================================
// Tests
// ====================================================================================================

const test_tile: Tile = .{
    .generation = 1,
    .page = 0,
    .page_width = 400,
    .page_height = 200,
    .column = 0,
    .row = 0,
    .dark = true,
};

fn expectCollected(renderer: *Renderer, results: *std.ArrayList(Result)) !void {
    for (results.items) |result| result.deinit(renderer.gpa);
    results.clearRetainingCapacity();
    try renderer.collect(results);
}

test "loads, then renders wanted tiles of the loaded version only" {
    const gpa = std.testing.allocator;
    var renderer: Renderer = undefined;
    renderer.init(std.testing.io, gpa, "src/document/testdata/red-square.pdf", .direct, null);
    defer renderer.deinit();
    var results: std.ArrayList(Result) = .empty;
    defer {
        for (results.items) |result| result.deinit(gpa);
        results.deinit(gpa);
    }

    try std.testing.expect(renderer.step());
    try expectCollected(&renderer, &results);
    try std.testing.expectEqual(1, results.items[0].opened.generation);
    try std.testing.expectEqual(1, results.items[0].opened.page_sizes.len);

    var outdated = test_tile;
    outdated.generation = 0;
    renderer.want(&.{ outdated, test_tile }, 2);
    while (renderer.step()) {}
    try expectCollected(&renderer, &results);
    try std.testing.expectEqual(1, results.items.len);
    try std.testing.expectEqual(test_tile, results.items[0].tile.tile);
    try std.testing.expectEqual(400, results.items[0].tile.encoded.width);
}

test "a finished but uncollected tile is not queued again" {
    const gpa = std.testing.allocator;
    var renderer: Renderer = undefined;
    renderer.init(std.testing.io, gpa, "src/document/testdata/red-square.pdf", .direct, null);
    defer renderer.deinit();
    _ = renderer.step();
    renderer.want(&.{test_tile}, 1);
    _ = renderer.step();
    // The UI hasn't collected the tile yet, so it still wants it.
    renderer.want(&.{test_tile}, 1);
    try std.testing.expect(!renderer.step());
}

test "on its thread, results wake the UI, and deinit stops it while busy" {
    const gpa = std.testing.allocator;
    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(0, std.c.pipe(&fds));
    defer for (fds) |fd| {
        _ = std.c.close(fd);
    };
    var renderer: Renderer = undefined;
    renderer.init(std.testing.io, gpa, "src/document/testdata/red-square.pdf", .direct, fds[1]);
    defer renderer.deinit();
    try renderer.start();

    // The load's result arrives with a wake-up byte.
    var poll_fds = [_]std.posix.pollfd{.{ .fd = fds[0], .events = std.posix.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(1, try std.posix.poll(&poll_fds, 5000));
    var results: std.ArrayList(Result) = .empty;
    defer {
        for (results.items) |result| result.deinit(gpa);
        results.deinit(gpa);
    }
    // The byte is written after the result is added, so it is there.
    try renderer.collect(&results);
    try std.testing.expectEqual(.opened, std.meta.activeTag(results.items[0]));

    // Leave work queued for `deinit` to stop.
    var tiles: [viewer.tiles_max]Tile = undefined;
    for (&tiles, 0..) |*tile, row| {
        tile.* = test_tile;
        tile.page_height = 1024 * viewer.tiles_max;
        tile.row = @intCast(row);
    }
    renderer.want(&tiles, tiles.len);
}

test "invert keeps alpha" {
    var pixels = [_]u8{ 255, 0, 10, 200 };
    invert(&pixels);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 245, 200 }, &pixels);
}

test "collection during a load does not lose its result" {
    const DuringLoad = struct {
        renderer: *Renderer,
        collected: bool = false,
        results: std.ArrayList(Result) = .empty,

        fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            // The first allocation reserves publication space; the next one
            // reads the PDF with the renderer mutex released.
            if (!self.collected and self.renderer.results.capacity > 0) {
                self.collected = true;
                self.renderer.collect(&self.results) catch unreachable;
            }
            return std.testing.allocator.rawAlloc(len, alignment, ra);
        }

        fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
            std.testing.allocator.rawFree(memory, alignment, ra);
        }
    };
    var renderer: Renderer = undefined;
    var context: DuringLoad = .{ .renderer = &renderer };
    const gpa: std.mem.Allocator = .{
        .ptr = &context,
        .vtable = &.{
            .alloc = DuringLoad.alloc,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
            .free = DuringLoad.free,
        },
    };
    renderer.init(std.testing.io, gpa, "src/document/testdata/red-square.pdf", .direct, null);
    defer renderer.deinit();
    defer {
        for (context.results.items) |result| result.deinit(gpa);
        context.results.deinit(gpa);
    }
    try std.testing.expect(renderer.step());
    try std.testing.expect(context.collected);
    try std.testing.expectEqual(0, context.results.items.len);
    try renderer.collect(&context.results);
    try std.testing.expectEqual(1, context.results.items.len);
    try std.testing.expectEqual(1, context.results.items[0].opened.generation);
    try std.testing.expectEqual(1, context.results.items[0].opened.page_sizes.len);
    try std.testing.expect(!renderer.step());
}

test "collection failure preserves the loaded generation for retry" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    var renderer: Renderer = undefined;
    renderer.init(std.testing.io, gpa, "src/document/testdata/red-square.pdf", .direct, null);
    defer renderer.deinit();
    var results: std.ArrayList(Result) = .empty;
    defer {
        for (results.items) |result| result.deinit(gpa);
        results.deinit(gpa);
    }
    try std.testing.expect(renderer.step());
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, renderer.collect(&results));
    try std.testing.expectEqual(0, results.items.len);
    failing.fail_index = std.math.maxInt(usize);
    try renderer.collect(&results);
    try std.testing.expectEqual(1, results.items.len);
    try std.testing.expectEqual(1, results.items[0].opened.generation);
    try std.testing.expectEqual(1, results.items[0].opened.page_sizes.len);
}
