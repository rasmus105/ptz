//! Renders tiles on a thread of its own, and owns the document while doing
//! so: every engine call happens here, so the UI never waits on the engine.
//!
//! The UI asks for work with `reload` and `want`, and picks up `Result`s with
//! `collect`; `wake_fd` gets a byte whenever new results are ready. `step`
//! does one unit of work on the calling thread. The thread only loops over
//! it, and tests call it directly to run deterministically.

const Renderer = @This();

// std
const std = @import("std");

// project
const graphics = @import("../graphics/main.zig");
const pdf = @import("../pdf/main.zig");
const viewer = @import("../viewer/main.zig");

// aliases
const Tile = viewer.Tile;

// ====================================================================================================
// Types
// ====================================================================================================

pub const Result = union(enum) {
    /// The document was (re)loaded. Owns the page sizes.
    opened: []pdf.Size,
    open_failed: pdf.Error,
    tile: struct { key: Tile.Key, encoded: graphics.Encoded },
    render_failed: Tile.Key,

    pub fn deinit(result: Result, gpa: std.mem.Allocator) void {
        switch (result) {
            .opened => |page_sizes| gpa.free(page_sizes),
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
wanted: [viewer.wanted_max]Tile,
wanted_len: u32,
results: std.ArrayList(Result),
stopping: bool,

// Only used by whoever runs `step`:
document: ?pdf.Document,
/// Counts successful loads, matching `viewer.State.generation`.
generation: u32,
/// Pixels of the tile being rendered, reused between tiles.
scratch: []u8,

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
        .results = .empty,
        .stopping = false,
        .document = null,
        .generation = 0,
        .scratch = &.{},
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
    renderer.gpa.free(renderer.scratch);
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

/// Replaces the tiles to render, most urgent first.
pub fn want(renderer: *Renderer, tiles: []const Tile) void {
    std.debug.assert(tiles.len <= renderer.wanted.len);
    renderer.mutex.lockUncancelable(renderer.io);
    defer renderer.mutex.unlock(renderer.io);
    @memcpy(renderer.wanted[0..tiles.len], tiles);
    renderer.wanted_len = @intCast(tiles.len);
    renderer.condition.signal(renderer.io);
}

/// Moves finished results into `results`; the caller frees them.
pub fn collect(renderer: *Renderer, results: *std.ArrayList(Result)) std.mem.Allocator.Error!void {
    renderer.mutex.lockUncancelable(renderer.io);
    defer renderer.mutex.unlock(renderer.io);
    try results.appendSlice(renderer.gpa, renderer.results.items);
    renderer.results.clearRetainingCapacity();
}

/// Does one unit of work: a pending reload, else the most urgent tile.
/// Returns false if there was nothing to do.
pub fn step(renderer: *Renderer) bool {
    renderer.mutex.lockUncancelable(renderer.io);
    const reload_requested = renderer.reload_requested;
    var tile: ?Tile = null;
    if (reload_requested) {
        renderer.reload_requested = false;
    } else if (renderer.wanted_len > 0) {
        tile = renderer.wanted[0];
        std.mem.copyForwards(Tile, renderer.wanted[0 .. renderer.wanted_len - 1], renderer.wanted[1..renderer.wanted_len]);
        renderer.wanted_len -= 1;
    }
    renderer.mutex.unlock(renderer.io);

    const result = if (reload_requested)
        renderer.load()
    else if (tile) |t|
        renderer.render(t) orelse return true
    else
        return false;

    renderer.mutex.lockUncancelable(renderer.io);
    renderer.results.append(renderer.gpa, result) catch {
        // Dropping a result only means rendering the tile again later.
        result.deinit(renderer.gpa);
    };
    renderer.mutex.unlock(renderer.io);
    if (renderer.wake_fd) |fd| _ = std.c.write(fd, "t", 1);
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
    var document = pdf.Document.open(renderer.io, renderer.gpa, renderer.path, null) catch |err|
        return .{ .open_failed = err };
    const page_sizes = renderer.gpa.alloc(pdf.Size, document.pageCount()) catch {
        document.close();
        return .{ .open_failed = error.OutOfMemory };
    };
    for (page_sizes, 0..) |*size, page| {
        size.* = document.pageSize(@intCast(page)) catch .{ .width = 1, .height = 1 };
    }
    if (renderer.document) |*old| old.close();
    renderer.document = document;
    renderer.generation += 1;
    return .{ .opened = page_sizes };
}

/// Renders and encodes `tile`, or returns null if it belongs to another
/// version of the document than the loaded one.
fn render(renderer: *Renderer, tile: Tile) ?Result {
    if (tile.key.generation != renderer.generation) return null;
    const document = &(renderer.document orelse return null);

    const len = @as(usize, tile.key.width) * tile.height * 4;
    if (renderer.scratch.len < len) {
        renderer.gpa.free(renderer.scratch);
        renderer.scratch = &.{};
        renderer.scratch = renderer.gpa.alloc(u8, len) catch return .{ .render_failed = tile.key };
    }
    const bitmap: pdf.Bitmap = .{ .width = tile.key.width, .height = tile.height, .pixels = renderer.scratch[0..len] };
    document.render(tile.key.page, .{ .scale = tile.scale, .x = 0, .y = tile.top() }, bitmap) catch
        return .{ .render_failed = tile.key };
    if (tile.key.dark) invert(bitmap.pixels);

    const encoded = graphics.Encoded.init(renderer.gpa, renderer.medium, .{
        .width = bitmap.width,
        .height = bitmap.height,
        .pixels = bitmap.pixels,
    }) catch return .{ .render_failed = tile.key };
    return .{ .tile = .{ .key = tile.key, .encoded = encoded } };
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
    try renderer.collect(&results);
    try std.testing.expectEqual(1, results.items[0].opened.len);

    const tile: Tile = .{
        .key = .{ .generation = 1, .page = 0, .width = 400, .index = 0, .dark = true },
        .scale = 2,
        .height = 200,
    };
    var outdated = tile;
    outdated.key.generation = 0;
    renderer.want(&.{ outdated, tile });
    while (renderer.step()) {}
    try renderer.collect(&results);
    try std.testing.expectEqual(2, results.items.len);
    try std.testing.expectEqual(tile.key, results.items[1].tile.key);
    try std.testing.expectEqual(400, results.items[1].tile.encoded.width);
}

test "invert keeps alpha" {
    var pixels = [_]u8{ 255, 0, 10, 200 };
    invert(&pixels);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 245, 200 }, &pixels);
}
