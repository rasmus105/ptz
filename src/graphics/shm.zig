//! POSIX shared memory objects for handing pixels to the terminal: ptz
//! creates and fills an object, and the terminal opens it by name, reads it
//! and unlinks it.

// std
const std = @import("std");

// aliases
const posix = std.posix;

// ====================================================================================================
// Constants
// ====================================================================================================

/// macOS limits names to 31 bytes.
const name_len_max = 31;

// ====================================================================================================
// Types
// ====================================================================================================

/// An object's name, e.g. `/ptz-123-4`.
pub const Name = struct {
    buffer: [name_len_max + 1]u8,
    len: u8,

    /// Makes names unique within the process.
    var counter: std.atomic.Value(u32) = .init(0);

    pub fn slice(name: *const Name) [:0]const u8 {
        return name.buffer[0..name.len :0];
    }

    pub fn unlink(name: *const Name) void {
        _ = std.c.shm_unlink(name.slice());
    }
};

/// A new object, mapped for writing until `unmap`.
pub const Object = struct {
    name: Name,
    memory: []align(std.heap.page_size_min) u8,

    pub fn create(len: usize) error{SharedMemoryUnavailable}!Object {
        std.debug.assert(len > 0);
        var name: Name = undefined;
        const printed = std.fmt.bufPrintSentinel(&name.buffer, "/ptz-{d}-{d}", .{
            std.c.getpid(),
            Name.counter.fetchAdd(1, .monotonic),
        }, 0) catch unreachable;
        name.len = @intCast(printed.len);

        const flags: std.c.O = .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true };
        const flags_int: c_int = @bitCast(@as(u32, @bitCast(flags)));
        var fd = std.c.shm_open(name.slice(), flags_int, @as(c_uint, 0o600));
        if (fd < 0 and std.c._errno().* == @backingInt(posix.E.EXIST)) {
            // Left behind by an earlier process with the same pid.
            name.unlink();
            fd = std.c.shm_open(name.slice(), flags_int, @as(c_uint, 0o600));
        }
        if (fd < 0) return error.SharedMemoryUnavailable;
        defer _ = std.c.close(fd);
        errdefer name.unlink();

        if (std.c.ftruncate(fd, @intCast(len)) != 0) return error.SharedMemoryUnavailable;
        const memory = posix.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0) catch
            return error.SharedMemoryUnavailable;
        return .{ .name = name, .memory = memory };
    }

    /// Ends writing. The object stays until its name is unlinked.
    pub fn unmap(object: Object) void {
        posix.munmap(object.memory);
    }
};

// ====================================================================================================
// Tests
// ====================================================================================================

test "an object left behind under the same name is replaced" {
    const first: Object = try .create(4);
    first.unmap();
    // Simulate a stale object by making the next name collide with it.
    Name.counter.store(Name.counter.load(.monotonic) - 1, .monotonic);
    const second: Object = try .create(8);
    defer second.name.unlink();
    defer second.unmap();
    try std.testing.expectEqualStrings(first.name.slice(), second.name.slice());
    try std.testing.expectEqual(8, second.memory.len);
}
