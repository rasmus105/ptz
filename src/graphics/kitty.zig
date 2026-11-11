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

/// Transmits and displays `image` in one go (`a=T`) as raw RGBA (`f=32`),
/// split into chunks where all but the last carry `m=1`. `q=2` stops the
/// terminal from replying, since nothing reads replies at this point and
/// they would otherwise show up as typed input.
pub fn draw(writer: *std.Io.Writer, image: graphics.Image) std.Io.Writer.Error!void {
    var encoded: [std.base64.standard.Encoder.calcSize(chunk_len)]u8 = undefined;
    var rest = image.pixels;
    var first = true;
    while (true) {
        const chunk = rest[0..@min(chunk_len, rest.len)];
        rest = rest[chunk.len..];
        const more = @intFromBool(rest.len > 0);
        if (first) {
            try writer.print("\x1b_Ga=T,f=32,s={d},v={d},q=2,m={d};", .{ image.width, image.height, more });
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

test "small image is sent as a single escape sequence" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try draw(&writer, .{ .width = 1, .height = 1, .pixels = &.{ 0xff, 0x00, 0x00, 0xff } });
    try std.testing.expectEqualStrings("\x1b_Ga=T,f=32,s=1,v=1,q=2,m=0;/wAA/w==\x1b\\", writer.buffered());
}

test "large image is split into chunks that reassemble to the pixels" {
    const gpa = std.testing.allocator;
    // One pixel more than fits in a chunk.
    var pixels: [chunk_len + 4]u8 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @truncate(i);

    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    try draw(&output.writer, .{ .width = pixels.len / 4, .height = 1, .pixels = &pixels });

    var sequences = std.mem.splitSequence(u8, output.written(), "\x1b\\");
    const first = sequences.next().?;
    const second = sequences.next().?;
    try std.testing.expectEqualStrings("", sequences.rest());
    try std.testing.expect(std.mem.startsWith(u8, first, "\x1b_Ga=T,f=32,s=769,v=1,q=2,m=1;"));
    try std.testing.expect(std.mem.startsWith(u8, second, "\x1b_Gm=0;"));

    var decoded: [pixels.len]u8 = undefined;
    const payload1 = first[std.mem.indexOfScalar(u8, first, ';').? + 1 ..];
    const payload2 = second[std.mem.indexOfScalar(u8, second, ';').? + 1 ..];
    try std.base64.standard.Decoder.decode(decoded[0..chunk_len], payload1);
    try std.base64.standard.Decoder.decode(decoded[chunk_len..], payload2);
    try std.testing.expectEqualSlices(u8, &pixels, &decoded);
}
