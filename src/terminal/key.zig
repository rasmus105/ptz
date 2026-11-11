//! Key presses decoded from the terminal's input bytes.

// std
const std = @import("std");

// ====================================================================================================
// Types
// ====================================================================================================

pub const Key = union(enum) {
    /// A printable character, including space.
    char: u21,
    /// Ctrl plus a lowercase letter, e.g. `'d'` for Ctrl-D.
    ctrl: u8,
    enter,
    tab,
    backspace,
    escape,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    /// A sequence ptz doesn't use, such as F-keys or a stray query reply.
    unknown,

    pub const Decoded = struct {
        key: Key,
        /// Bytes consumed, at least one.
        len: u32,
    };

    /// Decodes the first key in `bytes`, which must not be empty. Terminals
    /// write a key's whole sequence at once, so a lone ESC at the end of
    /// `bytes` is the Escape key rather than the start of a sequence.
    pub fn decode(bytes: []const u8) Decoded {
        std.debug.assert(bytes.len > 0);
        const byte = bytes[0];
        switch (byte) {
            0x1b => return decodeEscape(bytes),
            '\r', '\n' => return .{ .key = .enter, .len = 1 },
            '\t' => return .{ .key = .tab, .len = 1 },
            0x7f, 0x08 => return .{ .key = .backspace, .len = 1 },
            0x01...0x07, 0x0b, 0x0c, 0x0e...0x1a => return .{ .key = .{ .ctrl = 'a' + byte - 1 }, .len = 1 },
            0x00, 0x1c...0x1f => return .{ .key = .unknown, .len = 1 },
            else => {},
        }
        const len = std.unicode.utf8ByteSequenceLength(byte) catch return .{ .key = .unknown, .len = 1 };
        if (len > bytes.len) return .{ .key = .unknown, .len = @intCast(bytes.len) };
        const char = std.unicode.utf8Decode(bytes[0..len]) catch return .{ .key = .unknown, .len = len };
        return .{ .key = .{ .char = char }, .len = len };
    }

    fn decodeEscape(bytes: []const u8) Decoded {
        std.debug.assert(bytes[0] == 0x1b);
        if (bytes.len == 1) return .{ .key = .escape, .len = 1 };
        // SS3 sequences (`ESC O A`) are what arrow keys send in application mode.
        if (bytes[1] == 'O' and bytes.len >= 3) return .{ .key = finalKey(bytes[2], 0), .len = 3 };
        if (bytes[1] != '[') return .{ .key = .escape, .len = 1 };

        // CSI: parameters and intermediates, then a final byte in 0x40...0x7e.
        var end: u32 = 2;
        while (end < bytes.len) : (end += 1) {
            if (bytes[end] >= 0x40 and bytes[end] <= 0x7e) break;
        } else return .{ .key = .unknown, .len = @intCast(bytes.len) };
        const params = bytes[2..end];
        const first = std.fmt.parseInt(u8, params[0 .. std.mem.indexOfScalar(u8, params, ';') orelse params.len], 10) catch 0;
        return .{ .key = finalKey(bytes[end], first), .len = end + 1 };
    }

    /// Maps a CSI or SS3 final byte, with the first parameter for `~` keys.
    fn finalKey(final: u8, param: u8) Key {
        return switch (final) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            '~' => switch (param) {
                1, 7 => .home,
                4, 8 => .end,
                5 => .page_up,
                6 => .page_down,
                else => .unknown,
            },
            else => .unknown,
        };
    }
};

// ====================================================================================================
// Tests
// ====================================================================================================

fn expectKeys(input: []const u8, expected: []const Key) !void {
    var rest = input;
    for (expected) |key| {
        const decoded = Key.decode(rest);
        try std.testing.expectEqual(key, decoded.key);
        rest = rest[decoded.len..];
    }
    try std.testing.expectEqual(0, rest.len);
}

test "plain, control and multi-byte keys" {
    try expectKeys("j\x04\x15:é\r\x7f", &.{
        .{ .char = 'j' }, .{ .ctrl = 'd' }, .{ .ctrl = 'u' }, .{ .char = ':' },
        .{ .char = 'é' },
        .enter,           .backspace,
    });
}

test "escape sequences for navigation keys" {
    try expectKeys("\x1b[A\x1bOB\x1b[1;5C\x1b[5~\x1b[6~\x1b[H\x1b[4~", &.{
        .up, .down, .right, .page_up, .page_down, .home, .end,
    });
}

test "lone escape and unrecognized sequences" {
    try expectKeys("\x1b", &.{.escape});
    try expectKeys("\x1bx", &.{ .escape, .{ .char = 'x' } });
    // A query reply and an F-key are skipped as single units.
    try expectKeys("\x1b[?62;22c\x1b[15~q", &.{ .unknown, .unknown, .{ .char = 'q' } });
    try expectKeys("\x1b[1;2", &.{.unknown});
}
