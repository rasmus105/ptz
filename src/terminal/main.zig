//! The controlling terminal: its size and escape-sequence queries.
//!
//! Terminals answer queries on stdin, and stay silent for queries they don't
//! understand. Every query is therefore followed by a DA1 request, which all
//! terminals answer, and replies arrive in order: once the DA1 reply is in,
//! any reply to the actual query has arrived before it.

// std
const std = @import("std");

// aliases
const posix = std.posix;

// ====================================================================================================
// Constants
// ====================================================================================================

const da1_request = "\x1b[c";

/// Only reached by terminals that answer nothing at all, since DA1 replies
/// normally arrive within milliseconds.
const reply_timeout_ms = 1000;

// ====================================================================================================
// Types
// ====================================================================================================

pub const Error = error{
    NotATerminal,
    NoReply,
    ReplyTooLong,
    UnknownCellSize,
    Unexpected,
};

pub const Size = struct {
    cols: u16,
    rows: u16,
    /// Pixel size of one cell.
    cell_width: u16,
    cell_height: u16,
};

// ====================================================================================================
// Public API
// ====================================================================================================

pub fn size(io: std.Io) Error!Size {
    var ws: posix.winsize = undefined;
    if (std.c.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, &ws) != 0 or ws.col == 0 or ws.row == 0)
        return error.NotATerminal;
    if (ws.xpixel != 0 and ws.ypixel != 0) return .{
        .cols = ws.col,
        .rows = ws.row,
        .cell_width = ws.xpixel / ws.col,
        .cell_height = ws.ypixel / ws.row,
    };

    // Some terminals leave the pixel fields zero; ask for the cell size
    // instead. The reply is `ESC [ 6 ; height ; width t`.
    var buffer: [256]u8 = undefined;
    const reply = try query(io, "\x1b[16t", &buffer);
    const start = std.mem.indexOf(u8, reply, "\x1b[6;") orelse return error.UnknownCellSize;
    const end = std.mem.indexOfScalarPos(u8, reply, start, 't') orelse return error.UnknownCellSize;
    var fields = std.mem.splitScalar(u8, reply[start + 4 .. end], ';');
    const height = std.fmt.parseInt(u16, fields.next() orelse "", 10) catch return error.UnknownCellSize;
    const width = std.fmt.parseInt(u16, fields.next() orelse "", 10) catch return error.UnknownCellSize;
    if (width == 0 or height == 0) return error.UnknownCellSize;
    return .{ .cols = ws.col, .rows = ws.row, .cell_width = width, .cell_height = height };
}

/// Sends `request` and returns everything the terminal replied, up to and
/// including the DA1 reply. Callers search the result for their own reply,
/// which is absent if the terminal does not support the request.
pub fn query(io: std.Io, comptime request: []const u8, buffer: []u8) Error![]const u8 {
    const original = posix.tcgetattr(posix.STDIN_FILENO) catch return error.NotATerminal;
    // Raw enough to read replies byte by byte without echoing them.
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    posix.tcsetattr(posix.STDIN_FILENO, .NOW, raw) catch return error.NotATerminal;
    defer posix.tcsetattr(posix.STDIN_FILENO, .NOW, original) catch {};

    std.Io.File.stdout().writeStreamingAll(io, request ++ da1_request) catch return error.Unexpected;

    var len: usize = 0;
    while (true) {
        // DA1 reply: `ESC [ ? <digits and semicolons> c`.
        if (std.mem.lastIndexOf(u8, buffer[0..len], "\x1b[?")) |start| {
            const params = buffer[start + 3 .. len];
            if (std.mem.indexOfNone(u8, params, "0123456789;")) |i| {
                if (params[i] == 'c') return buffer[0..len];
            }
        }
        if (len == buffer.len) return error.ReplyTooLong;

        var fds = [_]posix.pollfd{.{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&fds, reply_timeout_ms) catch return error.Unexpected;
        if (ready == 0) return error.NoReply;
        len += posix.read(posix.STDIN_FILENO, buffer[len..]) catch return error.Unexpected;
    }
}
