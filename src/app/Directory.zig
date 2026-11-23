//! A snapshot of sibling paths in filename order. The renderer owns it so
//! it can try candidates lazily without blocking the viewer or moving the
//! current document until a candidate opens successfully.

// std
const std = @import("std");

// aliases
const Directory = @This();

// ====================================================================================================
// Fields
// ====================================================================================================

arena: std.heap.ArenaAllocator,
paths: []const []const u8,

// ====================================================================================================
// Public API
// ====================================================================================================

pub fn read(io: std.Io, gpa: std.mem.Allocator, path: []const u8) error{ CannotReadDirectory, OutOfMemory }!Directory {
    const dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return error.CannotReadDirectory;
    defer dir.close(io);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    var paths: std.ArrayList([]const u8) = .empty;
    var entries = dir.iterate();
    while (entries.next(io) catch return error.CannotReadDirectory) |entry| {
        switch (entry.kind) {
            .file, .sym_link, .unknown => {},
            else => continue,
        }
        const candidate = try std.fs.path.join(allocator, &.{ path, entry.name });
        try paths.append(allocator, candidate);
    }
    std.mem.sort([]const u8, paths.items, {}, lessThan);
    return .{ .arena = arena, .paths = paths.items };
}

pub fn deinit(directory: *Directory) void {
    directory.arena.deinit();
}

/// Returns the range on the requested side of the current path. A file
/// opened explicitly may have vanished before the first directory scan.
pub fn neighbors(directory: Directory, io: std.Io, current: []const u8, forward: bool) []const []const u8 {
    const paths = directory.paths;
    const insertion = std.sort.lowerBound([]const u8, paths, current, order);
    var index = insertion;
    var found = index < paths.len and order(paths[index], current) == .eq;
    if (!found) {
        // An explicit path can use a different spelling on a case-insensitive
        // or normalizing filesystem. Compare the entries themselves so links
        // to the same target can still have different positions.
        const options: std.Io.Dir.StatFileOptions = .{ .follow_symlinks = false };
        if (std.Io.Dir.cwd().statFile(io, current, options)) |stat| {
            for (paths, 0..) |candidate, i| {
                if (stat.nlink > 1 and !std.ascii.eqlIgnoreCase(std.fs.path.basename(candidate), std.fs.path.basename(current))) continue;
                const entry = std.Io.Dir.cwd().statFile(io, candidate, options) catch continue;
                if (entry.inode == stat.inode) {
                    index = i;
                    found = true;
                    break;
                }
            }
        } else |_| {}
    }
    return if (forward) paths[index + @intFromBool(found) ..] else paths[0..index];
}

// ====================================================================================================
// Private Functions
// ====================================================================================================

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return order(a, b) == .lt;
}

fn order(a_path: []const u8, b_path: []const u8) std.math.Order {
    const a = std.fs.path.basename(a_path);
    const b = std.fs.path.basename(b_path);
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            const start_a = i;
            const start_b = j;
            while (i < a.len and std.ascii.isDigit(a[i])) i += 1;
            while (j < b.len and std.ascii.isDigit(b[j])) j += 1;
            // Compare magnitudes without converting arbitrarily long runs to integers.
            const digits_a = std.mem.trimStart(u8, a[start_a..i], "0");
            const digits_b = std.mem.trimStart(u8, b[start_b..j], "0");
            if (digits_a.len != digits_b.len) return std.math.order(digits_a.len, digits_b.len);
            const digits_order = std.mem.order(u8, digits_a, digits_b);
            if (digits_order != .eq) return digits_order;
        } else {
            if (a[i] != b[j]) return std.math.order(a[i], b[j]);
            i += 1;
            j += 1;
        }
    }
    if ((i == a.len) != (j == b.len)) return if (i == a.len) .lt else .gt;
    // Equal numbers can have different spellings; keep the order deterministic.
    return std.mem.order(u8, a, b);
}
