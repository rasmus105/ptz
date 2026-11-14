//! Rendered tiles: waiting to be uploaded to the terminal, or uploaded.
//! Keeps the terminal's image memory within a budget by deleting the least
//! recently used tiles, and never deletes tiles used in the current frame.

// std
const std = @import("std");

// project
const graphics = @import("../graphics/main.zig");
const viewer = @import("../viewer/main.zig");

// aliases
const Cache = @This();
const Tile = viewer.Tile;

// ====================================================================================================
// Constants
// ====================================================================================================

/// Image ids are shared with other programs in the terminal; ptz's start
/// here ("pt") to stay clear of the small ids most programs use.
const image_id_base: graphics.ImageId = 0x7074_0000;

/// Decoded pixel bytes ptz keeps in the terminal. Kitty's default quota is
/// 320 MB per screen; staying below it avoids the terminal silently
/// evicting tiles that are on screen.
pub const uploaded_bytes_max = 256 * 1024 * 1024;

/// Pixel bytes of rendered tiles kept while not wanted, e.g. when scrolling
/// back. Shared memory tiles hold this much memory in the kernel.
pub const pending_bytes_max = 128 * 1024 * 1024;

comptime {
    // A frame's tiles must fit, or eviction would have to delete visible ones.
    std.debug.assert(viewer.tiles_max * viewer.tile_bytes_max <= uploaded_bytes_max);
}

// ====================================================================================================
// Types
// ====================================================================================================

const Entry = struct {
    id: graphics.ImageId,
    state: union(enum) {
        pending: graphics.Encoded,
        uploaded,
        /// Kept so the tile isn't requested again.
        failed,
    },
    /// `clock` when last used.
    last_used: u64,
};

// ====================================================================================================
// Fields
// ====================================================================================================

entries: std.AutoArrayHashMapUnmanaged(Tile, Entry),
/// Names remain owned after eviction until the terminal consumes the upload.
transfers: std.ArrayList(graphics.Transfer),
transfer_bytes: u64,
transfer_budget_bytes: u64,
next_id: graphics.ImageId,
/// Budgets; the constants above except in tests.
uploaded_budget_bytes: u64,
pending_budget_bytes: u64,
uploaded_bytes: u64,
pending_bytes: u64,
/// Advanced once per frame by `evict`.
clock: u64,

// ====================================================================================================
// Public API
// ====================================================================================================

pub fn init(uploaded_budget_bytes: u64, pending_budget_bytes: u64) Cache {
    return .{
        .entries = .empty,
        .transfers = .empty,
        .transfer_bytes = 0,
        .transfer_budget_bytes = uploaded_bytes_max,
        .next_id = image_id_base,
        .uploaded_budget_bytes = uploaded_budget_bytes,
        .pending_budget_bytes = pending_budget_bytes,
        .uploaded_bytes = 0,
        .pending_bytes = 0,
        .clock = 1,
    };
}

pub fn deinit(cache: *Cache, gpa: std.mem.Allocator) void {
    for (cache.entries.values()) |entry| if (entry.state == .pending) entry.state.pending.deinit(gpa);
    cache.entries.deinit(gpa);
    for (cache.transfers.items) |transfer| transfer.deinit();
    cache.transfers.deinit(gpa);
    cache.* = undefined;
}

/// Takes ownership of `encoded`.
pub fn put(cache: *Cache, gpa: std.mem.Allocator, tile: Tile, encoded: graphics.Encoded) std.mem.Allocator.Error!void {
    std.debug.assert(encoded.width == tile.width());
    std.debug.assert(encoded.height == tile.height());
    errdefer encoded.deinit(gpa);
    const slot = try cache.entries.getOrPut(gpa, tile);
    if (slot.found_existing) return encoded.deinit(gpa);
    cache.pending_bytes += bytes(tile);
    slot.value_ptr.* = .{ .id = cache.next_id, .state = .{ .pending = encoded }, .last_used = cache.clock };
    cache.next_id = if (cache.next_id == std.math.maxInt(graphics.ImageId)) image_id_base else cache.next_id + 1;
}

pub fn putFailed(cache: *Cache, gpa: std.mem.Allocator, tile: Tile) std.mem.Allocator.Error!void {
    const slot = try cache.entries.getOrPut(gpa, tile);
    if (!slot.found_existing) slot.value_ptr.* = .{ .id = 0, .state = .failed, .last_used = cache.clock };
}

/// Marks the cached ones of `tiles` as used this frame, and returns the
/// others in `missing`, in order.
pub fn findMissing(cache: *Cache, tiles: []const Tile, missing: []Tile) []Tile {
    std.debug.assert(missing.len >= tiles.len);
    var len: usize = 0;
    for (tiles) |tile| {
        if (cache.entries.getPtr(tile)) |entry| {
            entry.last_used = cache.clock;
        } else {
            missing[len] = tile;
            len += 1;
        }
    }
    return missing[0..len];
}

/// Uploads the pending ones of `tiles`, in order, until about
/// `budget_bytes` have been written. Returns whether any are left.
pub fn upload(cache: *Cache, gpa: std.mem.Allocator, writer: *std.Io.Writer, tiles: []const Tile, budget_bytes: usize) (std.mem.Allocator.Error || std.Io.Writer.Error)!bool {
    var index: usize = 0;
    while (index < cache.transfers.items.len) {
        if (cache.transfers.items[index].pending()) {
            index += 1;
        } else {
            cache.transfer_bytes -= cache.transfers.swapRemove(index).bytes;
        }
    }
    var written: usize = 0;
    for (tiles) |tile| {
        const entry = cache.entries.getPtr(tile) orelse continue;
        if (entry.state != .pending) continue;
        const encoded = entry.state.pending;
        // The first upload always goes, so a huge tile can't stall forever.
        if (written > 0 and written + encoded.transmitLen() > budget_bytes) return true;
        written += encoded.transmitLen();
        if (encoded.data == .shared_memory) {
            // A non-consuming terminal must not leave unlimited kernel memory
            // linked outside the cache's image budgets.
            if (bytes(tile) > cache.transfer_budget_bytes -| cache.transfer_bytes) return error.OutOfMemory;
            try cache.transfers.ensureUnusedCapacity(gpa, 1);
        }
        entry.state = .failed;
        cache.pending_bytes -= bytes(tile);
        if (try graphics.transmit(gpa, writer, entry.id, encoded)) |transfer| {
            cache.transfers.appendAssumeCapacity(transfer);
            cache.transfer_bytes += transfer.bytes;
        }
        entry.state = .uploaded;
        cache.uploaded_bytes += bytes(tile);
    }
    return false;
}

/// The uploaded image to show for `tile`: its own, or while that isn't
/// uploaded, one of the same area from another version (an older load of
/// the document, or the other colours).
pub fn shown(cache: *Cache, tile: Tile) ?graphics.ImageId {
    if (cache.entries.getPtr(tile)) |entry| {
        if (entry.state == .uploaded) {
            entry.last_used = cache.clock;
            return entry.id;
        }
    }
    var best: ?*Entry = null;
    var it = cache.entries.iterator();
    while (it.next()) |candidate| {
        if (candidate.value_ptr.state != .uploaded or !tile.sameArea(candidate.key_ptr.*)) continue;
        if (best == null or candidate.value_ptr.last_used > best.?.last_used) best = candidate.value_ptr;
    }
    const entry = best orelse return null;
    entry.last_used = cache.clock;
    return entry.id;
}

/// Ends the frame: forgets failures not seen this frame, so they are tried
/// again when back in view, and drops the least recently used pending and
/// uploaded tiles until each kind fits its budget. Tiles used this frame
/// are kept.
pub fn evict(cache: *Cache, gpa: std.mem.Allocator, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var index: usize = 0;
    while (index < cache.entries.count()) {
        const entry = cache.entries.values()[index];
        if (entry.state == .failed and entry.last_used < cache.clock) {
            cache.entries.swapRemoveAt(index);
        } else index += 1;
    }
    while (cache.pending_bytes > cache.pending_budget_bytes) {
        const evicted = cache.leastRecentlyUsed(.pending) orelse break;
        cache.entries.values()[evicted].state.pending.deinit(gpa);
        cache.pending_bytes -= bytes(cache.entries.keys()[evicted]);
        cache.entries.swapRemoveAt(evicted);
    }
    while (cache.uploaded_bytes > cache.uploaded_budget_bytes) {
        const evicted = cache.leastRecentlyUsed(.uploaded) orelse break;
        try graphics.free(writer, cache.entries.values()[evicted].id);
        cache.uploaded_bytes -= bytes(cache.entries.keys()[evicted]);
        cache.entries.swapRemoveAt(evicted);
    }
    cache.clock += 1;
}

/// Forgets all tiles, deleting uploaded ones from the terminal as far as
/// `writer` still works: this runs while shutting down, when the terminal
/// may be gone.
pub fn clear(cache: *Cache, gpa: std.mem.Allocator, writer: *std.Io.Writer) void {
    for (cache.entries.values()) |entry| switch (entry.state) {
        .pending => |encoded| encoded.deinit(gpa),
        .uploaded => graphics.free(writer, entry.id) catch {},
        .failed => {},
    };
    cache.entries.clearRetainingCapacity();
    for (cache.transfers.items) |transfer| transfer.deinit();
    cache.transfers.clearRetainingCapacity();
    cache.transfer_bytes = 0;
    cache.uploaded_bytes = 0;
    cache.pending_bytes = 0;
}

// ====================================================================================================
// Private Functions
// ====================================================================================================

fn bytes(tile: Tile) u64 {
    return @as(u64, tile.width()) * tile.height() * 4;
}

/// The index of the least recently used entry in `state`, not used this
/// frame.
fn leastRecentlyUsed(cache: *const Cache, state: std.meta.Tag(@FieldType(Entry, "state"))) ?usize {
    var oldest: ?usize = null;
    for (cache.entries.values(), 0..) |entry, index| {
        if (entry.state != state or entry.last_used == cache.clock) continue;
        if (oldest == null or entry.last_used < cache.entries.values()[oldest.?].last_used) oldest = index;
    }
    return oldest;
}

// ====================================================================================================
// Tests
// ====================================================================================================

/// A 16x16 tile: 1 KiB of pixels.
fn testTile(page: u32, generation: u32) Tile {
    return .{ .generation = generation, .page = page, .page_width = 16, .page_height = 16, .column = 0, .row = 0, .dark = false };
}

fn testEncoded(gpa: std.mem.Allocator) !graphics.Encoded {
    const canvas: graphics.Canvas = try .init(gpa, .direct, 16, 16);
    @memset(canvas.pixels, 0);
    return canvas.finish(gpa);
}

test "tiles are uploaded once and stand in for other versions of their area" {
    const gpa = std.testing.allocator;
    var cache: Cache = .init(1 << 20, 1 << 20);
    defer cache.deinit(gpa);
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();

    var missing: [2]Tile = undefined;
    try std.testing.expectEqual(2, cache.findMissing(&.{ testTile(0, 1), testTile(1, 1) }, &missing).len);
    try cache.put(gpa, testTile(0, 1), try testEncoded(gpa));
    try std.testing.expectEqual(null, cache.shown(testTile(0, 1)));
    try std.testing.expect(!try cache.upload(gpa, &output.writer, &.{testTile(0, 1)}, 1 << 20));
    const id = cache.shown(testTile(0, 1)).?;
    try std.testing.expectEqual(id, cache.shown(testTile(0, 2)).?);
    try std.testing.expectEqual(null, cache.shown(testTile(1, 1)));

    // Uploading again sends nothing.
    const sent = output.written().len;
    _ = try cache.upload(gpa, &output.writer, &.{testTile(0, 1)}, 1 << 20);
    try std.testing.expectEqual(sent, output.written().len);
}

test "each kind of tile is kept within its budget, least recently used first" {
    const gpa = std.testing.allocator;
    // Room for three uploaded and two pending 1 KiB tiles.
    var cache: Cache = .init(3 * 1024, 2 * 1024);
    defer cache.deinit(gpa);
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();

    for (0..4) |page| {
        const tile = testTile(@intCast(page), 1);
        try cache.put(gpa, tile, try testEncoded(gpa));
        _ = try cache.upload(gpa, &output.writer, &.{tile}, 1 << 20);
        try cache.evict(gpa, &output.writer);
    }
    try std.testing.expectEqual(null, cache.shown(testTile(0, 1)));
    try std.testing.expect(cache.shown(testTile(1, 1)) != null);
    try std.testing.expectEqual(3 * 1024, cache.uploaded_bytes);

    // Put this frame, so kept until the next.
    for (10..13) |page| try cache.put(gpa, testTile(@intCast(page), 1), try testEncoded(gpa));
    try cache.evict(gpa, &output.writer);
    try std.testing.expectEqual(3 * 1024, cache.pending_bytes);
    try cache.evict(gpa, &output.writer);
    try std.testing.expectEqual(2 * 1024, cache.pending_bytes);
}

test "tiles used this frame are kept even over budget" {
    const gpa = std.testing.allocator;
    var cache: Cache = .init(1024, 1024);
    defer cache.deinit(gpa);
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();

    const tiles = [_]Tile{ testTile(0, 1), testTile(1, 1), testTile(2, 1) };
    for (tiles) |tile| try cache.put(gpa, tile, try testEncoded(gpa));
    _ = try cache.upload(gpa, &output.writer, &tiles, 1 << 20);
    try cache.evict(gpa, &output.writer);
    try std.testing.expectEqual(3, cache.entries.count());
}

test "clear forgets everything even when the terminal is gone" {
    const gpa = std.testing.allocator;
    var cache: Cache = .init(1 << 20, 1 << 20);
    defer cache.deinit(gpa);
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    try cache.put(gpa, testTile(0, 1), try testEncoded(gpa));
    _ = try cache.upload(gpa, &output.writer, &.{testTile(0, 1)}, 1 << 20);
    try cache.put(gpa, testTile(1, 1), try testEncoded(gpa));

    var failing: std.Io.Writer = .failing;
    cache.clear(gpa, &failing);
    try std.testing.expectEqual(0, cache.entries.count());
}

test "failed shared-memory output releases objects even after buffering" {
    const gpa = std.testing.allocator;
    for ([_]bool{ false, true }) |buffered| {
        var cache: Cache = .init(1024, 1024);
        defer cache.deinit(gpa);
        const canvas = try graphics.Canvas.init(gpa, .shared_memory, 16, 16);
        @memset(canvas.pixels, 255);
        const encoded = try canvas.finish(gpa);
        const name = encoded.data.shared_memory;
        defer name.unlink();
        try cache.put(gpa, testTile(0, 1), encoded);

        var buffer: [1024]u8 = undefined;
        var output: std.Io.Writer = .failing;
        if (buffered) output.buffer = &buffer;
        if (buffered) {
            try std.testing.expect(!try cache.upload(gpa, &output, &.{testTile(0, 1)}, 1024));
            try std.testing.expect(name.exists());
            try std.testing.expectError(error.WriteFailed, output.flush());
        } else {
            try std.testing.expectError(error.WriteFailed, cache.upload(gpa, &output, &.{testTile(0, 1)}, 1024));
        }
        cache.clear(gpa, &output);
        try std.testing.expect(!name.exists());
    }
}

test "eviction preserves a shared-memory upload until the terminal reads it" {
    const gpa = std.testing.allocator;
    var cache: Cache = .init(0, 0);
    defer cache.deinit(gpa);
    const canvas = try graphics.Canvas.init(gpa, .shared_memory, 16, 16);
    @memset(canvas.pixels, 255);
    const encoded = try canvas.finish(gpa);
    const name = encoded.data.shared_memory;
    defer name.unlink();
    const tile = testTile(0, 1);
    try cache.put(gpa, tile, encoded);
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    try std.testing.expect(!try cache.upload(gpa, &output.writer, &.{tile}, 1024));
    const transmitted_len = output.written().len;
    const id = cache.shown(tile).?;
    try cache.evict(gpa, &output.writer);
    try cache.evict(gpa, &output.writer);
    try std.testing.expectEqual(null, cache.shown(tile));
    try std.testing.expect(name.exists());

    const Emulator = @import("../emulator/main.zig").Emulator;
    const emulator: *Emulator = try .create(std.testing.io, gpa, .{ .cols = 2, .rows = 2, .cell_width = 16, .cell_height = 16 });
    defer emulator.destroy();
    try emulator.output.writeAll(output.written()[0..transmitted_len]);
    try graphics.place(&emulator.output, .{
        .image = id,
        .source = .{ .x = 0, .y = 0, .width = 16, .height = 16 },
        .col = 0,
        .row = 0,
        .x_offset = 0,
        .y_offset = 0,
    });
    try emulator.output.flush();
    const screen = try emulator.screenshot(gpa);
    defer gpa.free(screen.pixels);
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, screen.pixel(8, 8));
    try std.testing.expect(!name.exists());
    try std.testing.expect(!try cache.upload(gpa, &output.writer, &.{}, 1024));
}

test "a non-consuming terminal cannot retain unbounded shared memory" {
    const gpa = std.testing.allocator;
    var cache: Cache = .init(1024, 2048);
    defer cache.deinit(gpa);
    cache.transfer_budget_bytes = 1024;
    const first = try graphics.Canvas.init(gpa, .shared_memory, 16, 16);
    const first_encoded = try first.finish(gpa);
    defer first_encoded.data.shared_memory.unlink();
    const second = try graphics.Canvas.init(gpa, .shared_memory, 16, 16);
    const second_encoded = try second.finish(gpa);
    defer second_encoded.data.shared_memory.unlink();
    try cache.put(gpa, testTile(0, 1), first_encoded);
    try cache.put(gpa, testTile(1, 1), second_encoded);
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    try std.testing.expect(!try cache.upload(gpa, &output.writer, &.{testTile(0, 1)}, 1024));
    const transmitted_len = output.written().len;
    try std.testing.expectError(error.OutOfMemory, cache.upload(gpa, &output.writer, &.{testTile(1, 1)}, 1024));
    try std.testing.expectEqual(transmitted_len, output.written().len);
    try std.testing.expect(first_encoded.data.shared_memory.exists());
    try std.testing.expect(second_encoded.data.shared_memory.exists());
    // The terminal releases this name after consuming its pixels.
    first_encoded.data.shared_memory.unlink();
    try std.testing.expect(!try cache.upload(gpa, &output.writer, &.{testTile(1, 1)}, 1024));
    try std.testing.expect(output.written().len > transmitted_len);
    cache.clear(gpa, &output.writer);
    try std.testing.expect(!first_encoded.data.shared_memory.exists());
    try std.testing.expect(!second_encoded.data.shared_memory.exists());
}
