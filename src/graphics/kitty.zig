//! Kitty graphics protocol: https://sw.kovidgoyal.net/kitty/graphics-protocol/
//!
//! Every command carries `q=2`, which stops the terminal from replying:
//! nothing reads replies while viewing, and they would otherwise arrive as
//! typed input. The exception is the support query, which needs its reply.

// std
const std = @import("std");

// project
const terminal = @import("../terminal/main.zig");

// local
const graphics = @import("main.zig");
const shm = @import("shm.zig");

// ====================================================================================================
// Constants
// ====================================================================================================

/// The protocol caps each escape sequence's base64 payload at 4096 bytes.
const chunk_len = 4096;

/// Asks the terminal to check a 1x1 RGB image (`a=q`) without storing or
/// displaying it. Kitty-capable terminals reply `OK` for image id 31.
const direct_query = "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\";

// ====================================================================================================
// Public API
// ====================================================================================================

/// Queries direct transmission and shared memory in one round trip; a
/// terminal on another machine can't open the shared memory object.
pub fn detect(input: *std.Io.Reader, output: *std.Io.Writer) terminal.Error!?graphics.Medium {
    const probe = shm.Object.create(4) catch {
        const reply = try terminal.query(input, output, direct_query);
        return if (std.mem.indexOf(u8, reply, "\x1b_Gi=31;OK") != null) .direct else null;
    };
    probe.memory[0..4].* = .{ 0, 0, 0, 255 };
    probe.unmap();
    // Terminals delete the object once read, but not when they fail to.
    defer probe.name.unlink();

    var encoded_name: [std.base64.standard.Encoder.calcSize(@sizeOf(shm.Name))]u8 = undefined;
    output.print("\x1b_Gi=32,s=1,v=1,a=q,t=s,f=32;{s}\x1b\\", .{
        std.base64.standard.Encoder.encode(&encoded_name, probe.name.slice()),
    }) catch return error.Unexpected;
    const reply = try terminal.query(input, output, direct_query);
    if (std.mem.indexOf(u8, reply, "\x1b_Gi=32;OK") != null) return .shared_memory;
    if (std.mem.indexOf(u8, reply, "\x1b_Gi=31;OK") != null) return .direct;
    return null;
}

/// Compresses (zlib) and base64-encodes RGBA pixels. Pages are mostly
/// uniform background, so compression shrinks what the terminal has to
/// receive and decode many times over, which dominates display time.
pub fn encode(gpa: std.mem.Allocator, pixels: []const u8) ![]u8 {
    var compressed: std.Io.Writer.Allocating = try .initCapacity(gpa, pixels.len / 16 + 64);
    defer compressed.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var zlib: std.compress.flate.Compress = try .init(&compressed.writer, &window, .zlib, .fastest);
    try zlib.writer.writeAll(pixels);
    try zlib.finish();

    const encoder = std.base64.standard.Encoder;
    const base64 = try gpa.alloc(u8, encoder.calcSize(compressed.written().len));
    _ = encoder.encode(base64, compressed.written());
    return base64;
}

/// Sends an image for later placement (`a=t`). Direct data is split into
/// chunks where all but the last carry `m=1`.
pub fn transmit(writer: *std.Io.Writer, id: graphics.ImageId, encoded: graphics.Encoded) std.Io.Writer.Error!void {
    const base64 = switch (encoded.data) {
        .direct => |base64| base64,
        .shared_memory => |*name| {
            var encoded_name: [std.base64.standard.Encoder.calcSize(@sizeOf(shm.Name))]u8 = undefined;
            try writer.print("\x1b_Ga=t,t=s,f=32,i={d},s={d},v={d},S={d},q=2;{s}\x1b\\", .{
                id,
                encoded.width,
                encoded.height,
                @as(u64, encoded.width) * encoded.height * 4,
                std.base64.standard.Encoder.encode(&encoded_name, name.slice()),
            });
            return;
        },
    };
    std.debug.assert(base64.len > 0);
    var rest = base64;
    var first = true;
    while (rest.len > 0) {
        const chunk = rest[0..@min(chunk_len, rest.len)];
        rest = rest[chunk.len..];
        const more = @intFromBool(rest.len > 0);
        if (first) {
            try writer.print(
                "\x1b_Ga=t,f=32,o=z,i={d},s={d},v={d},q=2,m={d};",
                .{ id, encoded.width, encoded.height, more },
            );
        } else {
            try writer.print("\x1b_Gm={d};", .{more});
        }
        try writer.writeAll(chunk);
        try writer.writeAll("\x1b\\");
        first = false;
    }
}

/// Shows part of a transmitted image with its top left corner at a cell plus
/// a pixel offset. `C=1` keeps the cursor still.
pub fn place(writer: *std.Io.Writer, placement: graphics.Placement) std.Io.Writer.Error!void {
    const source = placement.source;
    try terminal.moveCursor(writer, placement.row, placement.col);
    try writer.print(
        "\x1b_Ga=p,i={d},p=1,x={d},y={d},w={d},h={d},X={d},Y={d},C=1,q=2\x1b\\",
        .{ placement.image, source.x, source.y, source.width, source.height, placement.x_offset, placement.y_offset },
    );
}

/// Removes every placement but keeps the images for placing again.
pub fn clearPlacements(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("\x1b_Ga=d,d=a,q=2\x1b\\");
}

/// Deletes an image and frees its memory in the terminal.
pub fn free(writer: *std.Io.Writer, id: graphics.ImageId) std.Io.Writer.Error!void {
    try writer.print("\x1b_Ga=d,d=I,i={d},q=2\x1b\\", .{id});
}

// ====================================================================================================
// Tests
// ====================================================================================================

/// Decodes `transmit` output like a terminal would: checks the chunk framing
/// and returns the first sequence's keys and the decompressed pixels.
fn expectTransmission(gpa: std.mem.Allocator, output: []const u8, chunks: usize) !struct { []const u8, []u8 } {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    var keys: []const u8 = "";
    var sequences = std.mem.splitSequence(u8, output, "\x1b\\");
    for (0..chunks) |i| {
        const sequence = sequences.next().?;
        try std.testing.expect(std.mem.startsWith(u8, sequence, "\x1b_G"));
        const semicolon = std.mem.indexOfScalar(u8, sequence, ';').?;
        const sequence_keys = sequence[3..semicolon];
        try std.testing.expect(std.mem.endsWith(u8, sequence_keys, if (i + 1 < chunks) "m=1" else "m=0"));
        if (i == 0) keys = sequence_keys;

        const encoded = sequence[semicolon + 1 ..];
        const decoded = try payload.addManyAsSlice(gpa, try std.base64.standard.Decoder.calcSizeForSlice(encoded));
        try std.base64.standard.Decoder.decode(decoded, encoded);
    }
    try std.testing.expectEqualStrings("", sequences.rest());

    var input: std.Io.Reader = .fixed(payload.items);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var zlib: std.compress.flate.Decompress = .init(&input, .zlib, &window);
    return .{ keys, try zlib.reader.allocRemaining(gpa, .unlimited) };
}

fn testEncoded(gpa: std.mem.Allocator, medium: graphics.Medium, width: u32, pixels: []const u8) !graphics.Encoded {
    const canvas: graphics.Canvas = try .init(gpa, medium, width, @intCast(pixels.len / 4 / width));
    @memcpy(canvas.pixels, pixels);
    return canvas.finish(gpa);
}

fn expectRoundTrip(width: u32, pixels: []const u8, chunks_min: usize, expected_keys: ?[]const u8) !void {
    const gpa = std.testing.allocator;
    const encoded = try testEncoded(gpa, .direct, width, pixels);
    defer encoded.deinit(gpa);
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    try transmit(&output.writer, 7, encoded);

    const chunks = std.mem.count(u8, output.written(), "\x1b\\");
    try std.testing.expect(chunks >= chunks_min);
    const keys, const received = try expectTransmission(gpa, output.written(), chunks);
    defer gpa.free(received);
    if (expected_keys) |expected| try std.testing.expectEqualStrings(expected, keys);
    try std.testing.expectEqualSlices(u8, pixels, received);
}

test "small image is sent as a single escape sequence" {
    const pixels = [_]u8{ 0xff, 0x00, 0x00, 0xff };
    try expectRoundTrip(1, &pixels, 1, "a=t,f=32,o=z,i=7,s=1,v=1,q=2,m=0");
}

test "large image is split into chunks that reassemble to the pixels" {
    // Random pixels barely compress, so they need several chunks.
    var pixels: [4 * chunk_len]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(0);
    prng.random().bytes(&pixels);
    try expectRoundTrip(chunk_len, &pixels, 4, null);
}

test "shared memory is detected and carries the pixels" {
    const gpa = std.testing.allocator;
    const Emulator = @import("../emulator/main.zig").Emulator;
    const emulator: *Emulator = try .create(std.testing.io, gpa, .{ .cols = 10, .rows = 4, .cell_width = 10, .cell_height = 20 });
    defer emulator.destroy();
    try std.testing.expectEqual(.shared_memory, try detect(&emulator.input, &emulator.output));

    const pixels = [_]u8{ 255, 0, 0, 255, 0, 0, 255, 255 };
    const encoded = try testEncoded(gpa, .shared_memory, 2, &pixels);
    try transmit(&emulator.output, 7, encoded);
    try place(&emulator.output, .{ .image = 7, .source = .{ .x = 0, .y = 0, .width = 2, .height = 1 }, .col = 1, .row = 2, .x_offset = 3, .y_offset = 4 });
    try emulator.output.flush();
    const screen = try emulator.screenshot(gpa);
    defer gpa.free(screen.pixels);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, screen.pixel(13, 44));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, screen.pixel(14, 44));
    // The terminal deleted the object after reading it.
    try std.testing.expect(std.c.shm_unlink(encoded.data.shared_memory.slice()) != 0);
}
