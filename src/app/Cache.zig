//! Rendered tiles, by key: each is ready to upload or already uploaded to
//! the terminal. Keeps the terminal's image memory within a budget by
//! deleting the least recently used tiles that are not in use.

const Cache = @This();

// std
const std = @import("std");

// project
const graphics = @import("../graphics/main.zig");
const viewer = @import("../viewer/main.zig");

// aliases
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

// ====================================================================================================
// Types
// ====================================================================================================

pub const Entry = struct {
    id: graphics.ImageId,
    /// Present until uploaded.
    encoded: ?graphics.Encoded,
    /// Rendering failed; kept so the tile isn't requested again.
    failed: bool,
    pixel_bytes: u64,
    /// `clock` when last used; entries used this frame are never evicted.
    last_used: u64,
};

// ====================================================================================================
// Fields
// ====================================================================================================

entries: std.AutoArrayHashMapUnmanaged(Tile.Key, Entry),
next_id: graphics.ImageId,
uploaded_bytes: u64,
/// Advanced once per frame.
clock: u64,

// ====================================================================================================
// Public API
// ====================================================================================================

pub const empty: Cache = .{ .entries = .empty, .next_id = image_id_base, .uploaded_bytes = 0, .clock = 1 };

pub fn deinit(cache: *Cache, gpa: std.mem.Allocator) void {
    for (cache.entries.values()) |entry| if (entry.encoded) |encoded| encoded.deinit(gpa);
    cache.entries.deinit(gpa);
    cache.* = undefined;
}

/// Takes ownership of `encoded`.
pub fn put(cache: *Cache, gpa: std.mem.Allocator, key: Tile.Key, encoded: graphics.Encoded) std.mem.Allocator.Error!void {
    errdefer encoded.deinit(gpa);
    const slot = try cache.entries.getOrPut(gpa, key);
    if (slot.found_existing) return encoded.deinit(gpa);
    slot.value_ptr.* = .{
        .id = cache.nextId(),
        .encoded = encoded,
        .failed = false,
        .pixel_bytes = @as(u64, encoded.width) * encoded.height * 4,
        .last_used = 0,
    };
}

pub fn putFailed(cache: *Cache, gpa: std.mem.Allocator, key: Tile.Key) std.mem.Allocator.Error!void {
    const slot = try cache.entries.getOrPut(gpa, key);
    if (slot.found_existing) return;
    slot.value_ptr.* = .{ .id = 0, .encoded = null, .failed = true, .pixel_bytes = 0, .last_used = 0 };
}

/// Marks the entry for `key`, if any, as used this frame.
pub fn use(cache: *Cache, key: Tile.Key) ?*Entry {
    const entry = cache.entries.getPtr(key) orelse return null;
    entry.last_used = cache.clock;
    return entry;
}

/// An uploaded tile with the same pixel layout as `key` from another
/// version (an older load, or the other colour scheme), to show while
/// `key` renders.
pub fn useStale(cache: *Cache, key: Tile.Key) ?*Entry {
    var best: ?*Entry = null;
    var it = cache.entries.iterator();
    while (it.next()) |candidate| {
        const other = candidate.key_ptr;
        const entry = candidate.value_ptr;
        if (other.page != key.page or other.width != key.width or other.index != key.index) continue;
        if (entry.encoded != null or entry.failed) continue;
        if (best == null or entry.last_used > best.?.last_used) best = entry;
    }
    if (best) |entry| entry.last_used = cache.clock;
    return best;
}

pub fn upload(cache: *Cache, gpa: std.mem.Allocator, writer: *std.Io.Writer, entry: *Entry) std.Io.Writer.Error!void {
    const encoded = entry.encoded.?;
    entry.encoded = null;
    try graphics.transmit(gpa, writer, entry.id, encoded);
    cache.uploaded_bytes += entry.pixel_bytes;
}

/// Deletes least recently used tiles not used this frame until the uploads
/// fit the budget, then starts the next frame.
pub fn evict(cache: *Cache, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    while (cache.uploaded_bytes > uploaded_bytes_max) {
        var oldest: ?usize = null;
        for (cache.entries.values(), 0..) |entry, index| {
            if (entry.encoded != null or entry.failed or entry.last_used == cache.clock) continue;
            if (oldest == null or entry.last_used < cache.entries.values()[oldest.?].last_used) oldest = index;
        }
        const index = oldest orelse break;
        const entry = cache.entries.values()[index];
        try graphics.free(writer, entry.id);
        cache.uploaded_bytes -= entry.pixel_bytes;
        cache.entries.swapRemoveAt(index);
    }
    cache.clock += 1;
}

/// Deletes every uploaded tile from the terminal.
pub fn freeAll(cache: *Cache, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    for (cache.entries.values()) |entry| {
        if (entry.encoded == null and !entry.failed) try graphics.free(writer, entry.id);
    }
    cache.uploaded_bytes = 0;
}

// ====================================================================================================
// Private Functions
// ====================================================================================================

fn nextId(cache: *Cache) graphics.ImageId {
    defer cache.next_id = if (cache.next_id == std.math.maxInt(graphics.ImageId)) image_id_base else cache.next_id + 1;
    return cache.next_id;
}
