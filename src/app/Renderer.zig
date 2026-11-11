//! Renders tiles on a thread of its own, and owns the document while doing
//! so: every engine call happens here, so the UI never waits on the engine.
//!
//! The UI asks for work with `reload` and `want`, and picks up `Result`s with
//! `collect`; `wake_fd` gets a byte whenever new results are ready. `step`
//! does one unit of work on the calling thread. The thread only loops over
//! it, and tests call it directly to run deterministically.

// std
const std = @import("std");

// project
const graphics = @import("../graphics/main.zig");
const pdf = @import("../pdf/main.zig");
const viewer = @import("../viewer/main.zig");

// aliases
const Renderer = @This();
const Tile = viewer.Tile;

// ====================================================================================================
// Types
// ====================================================================================================

pub const Result = union(enum) {
    /// The document was (re)loaded; owns the slices. See `viewer.Document`.
    opened: struct { generation: u32, page_sizes: []pdf.Size, page_offsets: []f64 },
    open_failed: pdf.Error,
    tile: struct { tile: Tile, encoded: graphics.Encoded },
    render_failed: Tile,

    pub fn deinit(result: Result, gpa: std.mem.Allocator) void {
        switch (result) {
            .opened => |opened| {
                gpa.free(opened.page_sizes);
                gpa.free(opened.page_offsets);
            },
            .tile => |tile| tile.encoded.deinit(gpa),
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

mutex: std.Io.Mutex,
condition: std.Io.Condition,
// Guarded by `mutex`:
reload_requested: bool,
/// Tiles to render, most urgent first. Replaced as a whole by `want`.
wanted: [viewer.tiles_max]Tile,
wanted_len: u32,
/// The tile being rendered, which `want` must not queue again.
rendering: ?Tile,
results: std.ArrayList(Result),
stopping: bool,

// Only used by whoever runs `step`:
document: ?pdf.Document,
/// Counts successful loads; tiles of any other generation are skipped.
generation: u32,

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
        .mutex = .init,
        .condition = .init,
        .reload_requested = true,
        .wanted = undefined,
        .wanted_len = 0,
        .rendering = null,
        .results = .empty,
        .stopping = false,
        .document = null,
        .generation = 0,
    };
}

pub fn deinit(renderer: *Renderer) void {
    if (renderer.thread) |thread| {
        renderer.mutex.lockUncancelable(renderer.io);
        renderer.stopping = true;
        renderer.condition.signal(renderer.io);
        renderer.mutex.unlock(renderer.io);
        thread.join();
    }
    if (renderer.document) |*document| document.close();
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

/// Replaces the tiles to render, most urgent first. Tiles being rendered or
/// waiting to be collected are left out, so they aren't rendered twice.
pub fn want(renderer: *Renderer, tiles: []const Tile) void {
    std.debug.assert(tiles.len <= renderer.wanted.len);
    renderer.mutex.lockUncancelable(renderer.io);
    defer renderer.mutex.unlock(renderer.io);
    renderer.wanted_len = 0;
    next: for (tiles) |tile| {
        if (renderer.rendering != null and std.meta.eql(renderer.rendering.?, tile)) continue;
        for (renderer.results.items) |result| switch (result) {
            .tile => |done| if (std.meta.eql(done.tile, tile)) continue :next,
            .render_failed => |failed| if (std.meta.eql(failed, tile)) continue :next,
            .opened, .open_failed => {},
        };
        renderer.wanted[renderer.wanted_len] = tile;
        renderer.wanted_len += 1;
    }
    renderer.condition.signal(renderer.io);
}

/// Swaps finished results into `results`, which must be empty and use the
/// renderer's allocator. The caller frees them.
pub fn collect(renderer: *Renderer, results: *std.ArrayList(Result)) void {
    std.debug.assert(results.items.len == 0);
    renderer.mutex.lockUncancelable(renderer.io);
    defer renderer.mutex.unlock(renderer.io);
    std.mem.swap(std.ArrayList(Result), results, &renderer.results);
}

/// Does one unit of work: a pending reload, else the most urgent tile.
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
    if (!reload_requested and renderer.wanted_len > 0) {
        renderer.rendering = renderer.wanted[0];
        std.mem.copyForwards(Tile, renderer.wanted[0 .. renderer.wanted_len - 1], renderer.wanted[1..renderer.wanted_len]);
        renderer.wanted_len -= 1;
    }
    const tile = renderer.rendering;
    renderer.mutex.unlock(renderer.io);

    const result = if (reload_requested)
        renderer.load()
    else if (tile) |t|
        renderer.render(t)
    else
        return false;

    renderer.mutex.lockUncancelable(renderer.io);
    renderer.rendering = null;
    if (result) |r| renderer.results.appendAssumeCapacity(r);
    renderer.mutex.unlock(renderer.io);
    if (result != null) if (renderer.wake_fd) |fd| {
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
        while (!renderer.stopping and !renderer.reload_requested and renderer.wanted_len == 0) {
            renderer.condition.waitUncancelable(renderer.io, &renderer.mutex);
        }
        const stopping = renderer.stopping;
        renderer.mutex.unlock(renderer.io);
        if (stopping) return;
        _ = renderer.step();
    }
}

fn load(renderer: *Renderer) Result {
    var document = pdf.Document.open(renderer.io, renderer.gpa, renderer.path) catch |err|
        return .{ .open_failed = err };
    const page_count = document.pageCount();
    const page_sizes = renderer.gpa.alloc(pdf.Size, page_count) catch {
        document.close();
        return .{ .open_failed = error.OutOfMemory };
    };
    const page_offsets = renderer.gpa.alloc(f64, page_count) catch {
        renderer.gpa.free(page_sizes);
        document.close();
        return .{ .open_failed = error.OutOfMemory };
    };
    var offset: f64 = 0;
    for (page_sizes, page_offsets, 0..) |*size, *page_offset, page| {
        size.* = document.pageSize(@intCast(page)) catch .{ .width = pdf.page_size_min, .height = pdf.page_size_min };
        page_offset.* = offset;
        offset += size.height;
    }
    if (renderer.document) |*old| old.close();
    renderer.document = document;
    renderer.generation += 1;
    return .{ .opened = .{ .generation = renderer.generation, .page_sizes = page_sizes, .page_offsets = page_offsets } };
}

/// Renders and encodes `tile`, or returns null if it belongs to another
/// load of the document than the current one.
fn render(renderer: *Renderer, tile: Tile) ?Result {
    if (tile.generation != renderer.generation) return null;
    const document = &(renderer.document orelse return null);

    // Render straight into what will be uploaded.
    const canvas = graphics.Canvas.init(renderer.gpa, renderer.medium, tile.width(), tile.height()) catch
        return .{ .render_failed = tile };
    document.render(tile.page, .{
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
    renderer.collect(results);
}

test "loads, then renders wanted tiles of the loaded version only" {
    const gpa = std.testing.allocator;
    var renderer: Renderer = undefined;
    renderer.init(std.testing.io, gpa, "src/pdf/testdata/red-square.pdf", .direct, null);
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
    renderer.want(&.{ outdated, test_tile });
    while (renderer.step()) {}
    try expectCollected(&renderer, &results);
    try std.testing.expectEqual(1, results.items.len);
    try std.testing.expectEqual(test_tile, results.items[0].tile.tile);
    try std.testing.expectEqual(400, results.items[0].tile.encoded.width);
}

test "a finished but uncollected tile is not queued again" {
    const gpa = std.testing.allocator;
    var renderer: Renderer = undefined;
    renderer.init(std.testing.io, gpa, "src/pdf/testdata/red-square.pdf", .direct, null);
    defer renderer.deinit();
    _ = renderer.step();
    renderer.want(&.{test_tile});
    _ = renderer.step();
    // The UI hasn't collected the tile yet, so it still wants it.
    renderer.want(&.{test_tile});
    try std.testing.expect(!renderer.step());
}

test "invert keeps alpha" {
    var pixels = [_]u8{ 255, 0, 10, 200 };
    invert(&pixels);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 245, 200 }, &pixels);
}
