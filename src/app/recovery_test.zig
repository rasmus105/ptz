// std
const std = @import("std");

// project
const document = @import("../document/main.zig");
const emulator = @import("../emulator/main.zig");
const graphics = @import("../graphics/main.zig");
const terminal = @import("../terminal/main.zig");
const viewer = @import("../viewer/main.zig");

// local
const app = @import("main.zig");
const Cache = @import("Cache.zig");

// ====================================================================================================
// Constants
// ====================================================================================================

const small_tile: viewer.Tile = .{
    .generation = 1,
    .page = 0,
    .page_width = 16,
    .page_height = 16,
    .column = 0,
    .row = 0,
    .dark = false,
};
const input_size: terminal.Size = .{ .cols = 40, .rows = 11, .cell_width = 10, .cell_height = 20 };
const input_pages = [_]document.Size{.{ .width = 200, .height = 2000 }};
const input_offsets = [_]f64{0};

// ====================================================================================================
// Tests
// ====================================================================================================

fn encoded(tile: viewer.Tile, medium: graphics.Medium) !graphics.Encoded {
    const canvas = try graphics.Canvas.init(std.testing.allocator, medium, tile.width(), tile.height());
    @memset(canvas.pixels, 255);
    return canvas.finish(std.testing.allocator);
}

fn initInputApp(instance: *app.App) void {
    instance.init(std.testing.io, std.testing.allocator, .{
        .path = "unused.pdf",
        .page = 1,
        .dark = false,
        .watch = false,
        .medium = .direct,
    }, input_size, null);
    _ = instance.state.update(.{ .document = .{
        .generation = 1,
        .page_sizes = &input_pages,
        .page_offsets = &input_offsets,
    } });
}

/// Include terminal feedback in completion, as the real event loop does.
fn settle(instance: *app.App, target: *emulator.Emulator) !usize {
    var replies: usize = 0;
    for (0..32) |_| {
        try instance.settle(&target.output);
        var buffer: [app.input_len_max]u8 = undefined;
        while (true) {
            const len = try target.input.readSliceShort(&buffer);
            if (len == 0) break;
            replies += 1;
            try std.testing.expect(!instance.input(buffer[0..len]));
        }
        if (!instance.dirty) return replies;
    }
    return error.RecoveryDidNotConverge;
}

/// Exercise cache ownership against a terminal that can independently lose
/// images. Solid tiles make the pixel oracle independent of the document engine.
fn drawTiles(cache: *Cache, target: *emulator.Emulator, tiles: []const viewer.Tile) !usize {
    const gpa = std.testing.allocator;
    cache.beginFrame(tiles);
    var missing: [viewer.tiles_max]viewer.Tile = undefined;
    for (cache.findMissing(tiles, &missing)) |tile| try cache.put(gpa, tile, try encoded(tile, .direct));
    try std.testing.expect(!try cache.upload(gpa, &target.output, tiles, 4096));
    try graphics.clearPlacements(&target.output);
    for (tiles, 0..) |tile, index| {
        const image = cache.shown(tile) orelse continue;
        try graphics.place(&target.output, .{
            .image = image,
            .source = .{ .x = 0, .y = 0, .width = tile.width(), .height = tile.height() },
            .col = @intCast(index),
            .row = 0,
            .x_offset = 0,
            .y_offset = 0,
        });
    }
    try cache.evict(gpa, &target.output);
    try target.output.flush();
    var replies: usize = 0;
    var buffer: [app.input_len_max]u8 = undefined;
    while (true) {
        const len = try target.input.readSliceShort(&buffer);
        if (len == 0) break;
        var rest = buffer[0..len];
        while (rest.len > 0) {
            const decoded = terminal.Key.decode(rest) orelse return error.IncompleteReply;
            const reply = graphics.Reply.parse(rest[0..decoded.len]) orelse return error.UnexpectedReply;
            _ = cache.reject(reply);
            replies += 1;
            rest = rest[decoded.len..];
        }
    }
    return replies;
}

test "returning to the first page restores pixels after the terminal evicts its images" {
    const gpa = std.testing.allocator;
    const size: terminal.Size = .{ .cols = 80, .rows = 25, .cell_width = 10, .cell_height = 20 };
    const target = try emulator.Emulator.create(std.testing.io, gpa, size);
    defer target.destroy();
    target.terminal.setKittyGraphicsSizeLimit(gpa, 7 * 1000 * 1000);
    const instance = try gpa.create(app.App);
    defer gpa.destroy(instance);
    instance.init(std.testing.io, gpa, .{
        .path = "src/document/testdata/flow.epub",
        .page = 1,
        .dark = false,
        .watch = false,
        .medium = .shared_memory,
    }, size, null);
    defer instance.deinit();
    _ = try settle(instance, target);
    const original = try target.screenshot(gpa);
    defer gpa.free(original.pixels);
    var uncovered: usize = 0;
    for (0..800 * 480) |pixel| {
        if (original.pixels[pixel * 4 + 3] == 0) uncovered += 1;
    }
    try std.testing.expectEqual(0, uncovered);

    for ([_][]const u8{ "4G", "8G" }) |keys| {
        try std.testing.expect(!instance.input(keys));
        _ = try settle(instance, target);
    }
    try std.testing.expect(!instance.input("gg"));
    try std.testing.expect(try settle(instance, target) > 0);
    const restored = try target.screenshot(gpa);
    defer gpa.free(restored.pixels);
    try std.testing.expectEqualSlices(u8, original.pixels, restored.pixels);
}

test "fragmented missing-image replies never become keys and preserve neighboring keys" {
    const gpa = std.testing.allocator;
    const reference = try gpa.create(app.App);
    defer gpa.destroy(reference);
    initInputApp(reference);
    defer reference.deinit();
    try std.testing.expect(!reference.input("jj"));

    var packet_buffer: [128]u8 = undefined;
    // Use the transmitted id rather than encoding its range in the response.
    var split: usize = 0;
    while (true) : (split += 1) {
        const instance = try gpa.create(app.App);
        defer gpa.destroy(instance);
        initInputApp(instance);
        defer instance.deinit();
        var output: std.Io.Writer.Allocating = .init(gpa);
        defer output.deinit();
        instance.cache.beginFrame(&.{small_tile});
        try instance.cache.put(gpa, small_tile, try encoded(small_tile, .direct));
        _ = try instance.cache.upload(gpa, &output.writer, &.{small_tile}, 4096);
        const id = instance.cache.shown(small_tile).?;
        const packet = try std.fmt.bufPrint(&packet_buffer, "j\x1b_Gi={d},p=1;ENOENT: image qijG was evicted\x1b\\j", .{id});
        if (split > packet.len) break;
        try std.testing.expect(!instance.input(packet[0..split]));
        try std.testing.expect(!instance.input(packet[split..]));
        try std.testing.expectEqual(reference.state.anchor, instance.state.anchor);
        try std.testing.expectEqual(reference.state.dark, instance.state.dark);
        try std.testing.expectEqual(reference.state.zoom, instance.state.zoom);
        try std.testing.expectEqual(reference.state.command_open, instance.state.command_open);
        try std.testing.expectEqual(null, instance.cache.shown(small_tile));
        try std.testing.expect(instance.input("q"));
    }
}

test "oversized control strings discard command-like tails through split terminators" {
    const gpa = std.testing.allocator;
    const reference = try gpa.create(app.App);
    defer gpa.destroy(reference);
    initInputApp(reference);
    defer reference.deinit();
    try std.testing.expect(!reference.input("jj"));

    for ([_][]const u8{ "\x1b_G", "\x1b]", "\x1bP" }) |prefix| {
        for ([_]bool{ false, true }) |split_st| {
            const instance = try gpa.create(app.App);
            defer gpa.destroy(instance);
            initInputApp(instance);
            defer instance.deinit();
            try std.testing.expect(!instance.input("j"));
            var first: [app.input_len_max]u8 = undefined;
            @memset(&first, 'q');
            @memcpy(first[0..prefix.len], prefix);
            try std.testing.expect(!instance.input(&first));
            var continuation: [app.input_len_max]u8 = undefined;
            for (&continuation, 0..) |*byte, index| byte.* = "qijG:"[index % 5];
            if (split_st) continuation[continuation.len - 1] = 0x1b;
            try std.testing.expect(!instance.input(&continuation));
            try std.testing.expect(!instance.input(if (split_st) "\\j" else "\x07j"));
            try std.testing.expectEqual(reference.state.anchor, instance.state.anchor);
            try std.testing.expectEqual(reference.state.dark, instance.state.dark);
            try std.testing.expectEqual(reference.state.zoom, instance.state.zoom);
            try std.testing.expectEqual(reference.state.command_open, instance.state.command_open);
            try std.testing.expect(instance.input("q"));
        }
    }
}

test "late and unknown image failures leave replacement pixels intact" {
    const gpa = std.testing.allocator;
    const target = try emulator.Emulator.create(std.testing.io, gpa, .{ .cols = 2, .rows = 2, .cell_width = 16, .cell_height = 16 });
    defer target.destroy();
    var cache: Cache = .init(4096, 4096);
    defer cache.deinit(gpa);
    _ = try drawTiles(&cache, target, &.{small_tile});
    const lost = cache.shown(small_tile).?;
    try graphics.free(&target.output, lost);
    try target.output.flush();
    try std.testing.expect(try drawTiles(&cache, target, &.{small_tile}) > 0);
    _ = try drawTiles(&cache, target, &.{small_tile});
    const replacement = cache.shown(small_tile).?;
    try std.testing.expect(lost != replacement);

    for ([_]graphics.ImageId{ lost, std.math.maxInt(graphics.ImageId) }) |id| {
        _ = cache.reject(.{ .image = id, .placement = 1, .status = .not_found });
        try std.testing.expectEqual(replacement, cache.shown(small_tile).?);
    }
    _ = try drawTiles(&cache, target, &.{small_tile});
    const screen = try target.screenshot(gpa);
    defer gpa.free(screen.pixels);
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, screen.pixel(8, 8));
}

test "a terminal quota smaller than the view stops retrying until the visible tiles change" {
    const gpa = std.testing.allocator;
    const target = try emulator.Emulator.create(std.testing.io, gpa, .{ .cols = 2, .rows = 2, .cell_width = 16, .cell_height = 16 });
    defer target.destroy();
    // One tile fits, but the two-tile view cannot stay resident at once.
    target.terminal.setKittyGraphicsSizeLimit(gpa, 16 * 16 * 4);
    var cache: Cache = .init(4096, 4096);
    defer cache.deinit(gpa);
    var other = small_tile;
    other.page = 1;
    const tiles = [_]viewer.Tile{ small_tile, other };
    var failures: usize = 0;
    for (0..16) |_| {
        const replies = try drawTiles(&cache, target, &tiles);
        failures += replies;
        if (replies == 0) break;
    } else return error.RecoveryDidNotStop;
    try std.testing.expect(failures > 0);
    var missing: [2]viewer.Tile = undefined;
    for (0..4) |_| {
        try std.testing.expectEqual(0, try drawTiles(&cache, target, &tiles));
        try std.testing.expectEqual(0, cache.findMissing(&tiles, &missing).len);
    }
    const incomplete = try target.screenshot(gpa);
    defer gpa.free(incomplete.pixels);
    var covered: usize = 0;
    for (0..32 * 16) |pixel| {
        if (incomplete.pixels[pixel * 4 + 3] != 0) covered += 1;
    }
    try std.testing.expectEqual(16 * 16, covered);

    const unavailable = if (cache.shown(small_tile) == null) small_tile else other;
    cache.beginFrame(&.{unavailable});
    try std.testing.expectEqual(1, cache.findMissing(&.{unavailable}, &missing).len);
    try std.testing.expectEqual(0, try drawTiles(&cache, target, &.{unavailable}));
    const repaired = try target.screenshot(gpa);
    defer gpa.free(repaired.pixels);
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, repaired.pixel(8, 8));
}

test "a rejected shared-memory transfer is released even after its cache entry is evicted" {
    const gpa = std.testing.allocator;
    var cache: Cache = .init(0, 0);
    defer cache.deinit(gpa);
    const image = try encoded(small_tile, .shared_memory);
    const name = image.data.shared_memory;
    defer name.unlink();
    try cache.put(gpa, small_tile, image);
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    _ = try cache.upload(gpa, &output.writer, &.{small_tile}, 4096);
    const id = cache.shown(small_tile).?;
    try cache.evict(gpa, &output.writer);
    try cache.evict(gpa, &output.writer);
    try std.testing.expectEqual(null, cache.shown(small_tile));
    try std.testing.expect(name.exists());
    _ = cache.reject(.{ .image = id, .placement = null, .status = .rejected });
    try std.testing.expect(!name.exists());
}
