//! Kitty graphics protocol: https://sw.kovidgoyal.net/kitty/graphics-protocol/

// std
const std = @import("std");

// project
const terminal = @import("../terminal/main.zig");

// local
const graphics = @import("main.zig");

// ====================================================================================================
// Constants
// ====================================================================================================

/// The protocol caps each escape sequence's base64 payload at 4096 bytes;
/// 3072 raw bytes encode to exactly that.
const chunk_len = 3072;

/// Asks the terminal to check a 1x1 RGB image (`a=q`) without storing or
/// displaying it. Kitty-capable terminals reply `OK` for image id 31.
const support_query = "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\";

// ====================================================================================================
// Public API
// ====================================================================================================

pub fn supported(io: std.Io) terminal.Error!bool {
    var buffer: [256]u8 = undefined;
    const reply = try terminal.query(io, support_query, &buffer);
    return std.mem.indexOf(u8, reply, "\x1b_Gi=31;OK") != null;
}

/// Transmits and displays `image` in one go (`a=T`) as zlib-compressed
/// (`o=z`) RGBA (`f=32`), split into chunks where all but the last carry
/// `m=1`. Pages are mostly uniform background, so compression shrinks what
/// the terminal has to receive and decode many times over, which dominates
/// display time. `q=2` stops the terminal from replying, since nothing reads
/// replies at this point and they would otherwise show up as typed input.
pub fn draw(gpa: std.mem.Allocator, writer: *std.Io.Writer, image: graphics.Image) !void {
    var compressed: std.Io.Writer.Allocating = try .initCapacity(gpa, image.pixels.len / 16 + 64);
    defer compressed.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var zlib: std.compress.flate.Compress = try .init(&compressed.writer, &window, .zlib, .fastest);
    try zlib.writer.writeAll(image.pixels);
    try zlib.finish();

    var encoded: [std.base64.standard.Encoder.calcSize(chunk_len)]u8 = undefined;
    var rest = compressed.written();
    var first = true;
    while (true) {
        const chunk = rest[0..@min(chunk_len, rest.len)];
        rest = rest[chunk.len..];
        const more = @intFromBool(rest.len > 0);
        if (first) {
            try writer.print("\x1b_Ga=T,f=32,o=z,s={d},v={d},q=2,m={d};", .{ image.width, image.height, more });
        } else {
            try writer.print("\x1b_Gm={d};", .{more});
        }
        try writer.writeAll(std.base64.standard.Encoder.encode(&encoded, chunk));
        try writer.writeAll("\x1b\\");
        first = false;
        if (rest.len == 0) break;
    }
}

// ====================================================================================================
// Tests
// ====================================================================================================

/// Decodes `draw` output like a terminal would: checks the chunk framing and
/// returns the first sequence's keys and the decompressed pixels.
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

test "small image is sent as a single escape sequence" {
    const gpa = std.testing.allocator;
    const pixels = [_]u8{ 0xff, 0x00, 0x00, 0xff };
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    try draw(gpa, &output.writer, .{ .width = 1, .height = 1, .pixels = &pixels });

    const keys, const received = try expectTransmission(gpa, output.written(), 1);
    defer gpa.free(received);
    try std.testing.expectEqualStrings("a=T,f=32,o=z,s=1,v=1,q=2,m=0", keys);
    try std.testing.expectEqualSlices(u8, &pixels, received);
}

test "large image is split into chunks that reassemble to the pixels" {
    const gpa = std.testing.allocator;
    // Random pixels barely compress, so they need several chunks.
    var pixels: [4 * chunk_len]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(0);
    prng.random().bytes(&pixels);

    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    try draw(gpa, &output.writer, .{ .width = chunk_len, .height = 1, .pixels = &pixels });

    const sequences = std.mem.count(u8, output.written(), "\x1b\\");
    try std.testing.expect(sequences >= 4);
    _, const received = try expectTransmission(gpa, output.written(), sequences);
    defer gpa.free(received);
    try std.testing.expectEqualSlices(u8, &pixels, received);
}
