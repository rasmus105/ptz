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

// ====================================================================================================
// Constants
// ====================================================================================================

/// The protocol caps each escape sequence's base64 payload at 4096 bytes.
const chunk_len = 4096;

/// Asks the terminal to check a 1x1 RGB image (`a=q`) without storing or
/// displaying it. Kitty-capable terminals reply `OK` for image id 31.
const support_query = "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\";

// ====================================================================================================
// Public API
// ====================================================================================================

pub fn supported(input: *std.Io.Reader, output: *std.Io.Writer) terminal.Error!bool {
    const reply = try terminal.query(input, output, support_query);
    return std.mem.indexOf(u8, reply, "\x1b_Gi=31;OK") != null;
}

/// Compresses (zlib) and base64-encodes RGBA pixels. Pages are mostly
/// uniform background, so compression shrinks what the terminal has to
/// receive and decode many times over, which dominates display time.
pub fn encode(gpa: std.mem.Allocator, image: graphics.Image) ![]u8 {
    std.debug.assert(image.pixels.len == @as(usize, image.width) * image.height * 4);
    var compressed: std.Io.Writer.Allocating = try .initCapacity(gpa, image.pixels.len / 16 + 64);
    defer compressed.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var zlib: std.compress.flate.Compress = try .init(&compressed.writer, &window, .zlib, .fastest);
    try zlib.writer.writeAll(image.pixels);
    try zlib.finish();

    const encoder = std.base64.standard.Encoder;
    const base64 = try gpa.alloc(u8, encoder.calcSize(compressed.written().len));
    _ = encoder.encode(base64, compressed.written());
    return base64;
}

/// Sends an image prepared by `encode` for later placement (`a=t`), split
/// into chunks where all but the last carry `m=1`.
pub fn transmit(writer: *std.Io.Writer, id: graphics.ImageId, encoded: graphics.Encoded) std.Io.Writer.Error!void {
    std.debug.assert(encoded.base64.len > 0);
    var rest = encoded.base64;
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
    try writer.print("\x1b[{d};{d}H", .{ @as(u32, placement.row) + 1, @as(u32, placement.col) + 1 });
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

fn expectRoundTrip(image: graphics.Image, chunks_min: usize, expected_keys: ?[]const u8) !void {
    const gpa = std.testing.allocator;
    const encoded: graphics.Encoded = try .init(gpa, image);
    defer encoded.deinit(gpa);
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    try transmit(&output.writer, 7, encoded);

    const chunks = std.mem.count(u8, output.written(), "\x1b\\");
    try std.testing.expect(chunks >= chunks_min);
    const keys, const received = try expectTransmission(gpa, output.written(), chunks);
    defer gpa.free(received);
    if (expected_keys) |expected| try std.testing.expectEqualStrings(expected, keys);
    try std.testing.expectEqualSlices(u8, image.pixels, received);
}

test "small image is sent as a single escape sequence" {
    const pixels = [_]u8{ 0xff, 0x00, 0x00, 0xff };
    try expectRoundTrip(.{ .width = 1, .height = 1, .pixels = &pixels }, 1, "a=t,f=32,o=z,i=7,s=1,v=1,q=2,m=0");
}

test "large image is split into chunks that reassemble to the pixels" {
    // Random pixels barely compress, so they need several chunks.
    var pixels: [4 * chunk_len]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(0);
    prng.random().bytes(&pixels);
    try expectRoundTrip(.{ .width = chunk_len, .height = 1, .pixels = &pixels }, 4, null);
}

test "kitty graphics support is detected" {
    const gpa = std.testing.allocator;
    const Emulator = @import("../emulator/main.zig").Emulator;
    const emulator: *Emulator = try .create(std.testing.io, gpa, .{ .cols = 80, .rows = 24, .cell_width = 10, .cell_height = 20 });
    defer emulator.destroy();
    try std.testing.expect(try supported(&emulator.input, &emulator.output));
}
