//! The controlling terminal: raw mode, its size, and escape-sequence queries.
//!
//! Functions that talk to the terminal take its input and output as streams
//! rather than using stdin and stdout directly, so tests can substitute a
//! terminal emulator. `Input` is the stream for the real terminal's stdin.
//!
//! Terminals answer queries on their input, and stay silent for queries they
//! don't understand. Every query is therefore followed by a DA1 request,
//! which all terminals answer, and replies arrive in order: once the DA1
//! reply is in, any reply to the actual query has arrived before it.

// std
const std = @import("std");

// local
pub const Key = @import("key.zig").Key;

// aliases
const posix = std.posix;

// ====================================================================================================
// Constants
// ====================================================================================================

const da1_request = "\x1b[c";

/// Switches to the alternate screen, hides the cursor and turns off line
/// wrapping, so text reaching the last column of the last row can never
/// scroll the screen; and back.
pub const fullscreen_enter = "\x1b[?1049h\x1b[?25l\x1b[?7l";
pub const fullscreen_leave = "\x1b[?7h\x1b[?25h\x1b[?1049l";

/// Synchronized output (mode 2026): the terminal shows everything between
/// begin and end at once, so redraws don't flicker. Terminals without it
/// ignore it.
pub const sync_begin = "\x1b[?2026h";
pub const sync_end = "\x1b[?2026l";

pub const clear_screen = "\x1b[2J";
pub const style_reverse = "\x1b[7m";
pub const style_reset = "\x1b[0m";

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

/// Puts stdin in raw mode until `restore`, so key presses and query replies
/// arrive byte by byte without being echoed, and Ctrl-C, Ctrl-Z and Ctrl-S
/// arrive as keys instead of signals or flow control.
pub const RawMode = struct {
    original: posix.termios,

    /// The settings to restore if the process dies in raw mode.
    var crash_restore: ?posix.termios = null;

    pub fn enter() Error!RawMode {
        const original = posix.tcgetattr(posix.STDIN_FILENO) catch return error.NotATerminal;
        var raw = original;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.cc[@backingInt(posix.V.MIN)] = 0;
        raw.cc[@backingInt(posix.V.TIME)] = 0;
        posix.tcsetattr(posix.STDIN_FILENO, .NOW, raw) catch return error.NotATerminal;
        RawMode.crash_restore = original;
        return .{ .original = original };
    }

    pub fn restore(mode: RawMode) void {
        posix.tcsetattr(posix.STDIN_FILENO, .NOW, mode.original) catch {};
        RawMode.crash_restore = null;
    }
};

/// Stdin as a stream. Reads report end of stream after `timeout_ms` without
/// input, which is how queries notice a terminal that never replies.
pub const Input = struct {
    interface: std.Io.Reader,
    timeout_ms: i32,

    pub fn init(buffer: []u8, timeout_ms: i32) Input {
        return .{
            .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
            .timeout_ms = timeout_ms,
        };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const input: *Input = @alignCast(@fieldParentPtr("interface", r));
        var fds = [_]posix.pollfd{.{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&fds, input.timeout_ms) catch return error.ReadFailed;
        if (ready == 0) return error.EndOfStream;
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n = posix.read(posix.STDIN_FILENO, dest) catch return error.ReadFailed;
        if (n == 0) return error.EndOfStream;
        w.advance(n);
        return n;
    }
};

/// Signal handling for `notifySignals`.
const Signals = struct {
    var fd: std.atomic.Value(posix.fd_t) = .init(-1);
    var pending: std.atomic.Value(u8) = .init(0);

    fn handle(signal: posix.SIG) callconv(.c) void {
        // The interrupted code may be about to read errno.
        const saved = std.c._errno().*;
        defer std.c._errno().* = saved;
        _ = pending.fetchOr(if (signal == .WINCH) 1 else 2, .monotonic);
        _ = std.c.write(fd.load(.monotonic), "s", 1);
    }
};

// ====================================================================================================
// Public API
// ====================================================================================================

/// Puts the terminal back as it was before raw mode and full screen, for
/// paths that skip normal cleanup: panics and `std.process.fatal`.
pub fn restoreAfterCrash() void {
    const original = RawMode.crash_restore orelse return;
    const reset = sync_end ++ style_reset ++ fullscreen_leave;
    _ = std.c.write(posix.STDOUT_FILENO, reset, reset.len);
    posix.tcsetattr(posix.STDIN_FILENO, .NOW, original) catch {};
    RawMode.crash_restore = null;
}

/// Wakes an event loop on resize or termination (SIGTERM, SIGHUP, SIGINT).
/// The write end must be nonblocking; `takeSignals` preserves events even
/// when a full pipe coalesces notifications. Null restores default handling.
pub fn notifySignals(fd: ?posix.fd_t) void {
    Signals.pending.store(0, .monotonic);
    Signals.fd.store(fd orelse -1, .monotonic);
    const action: posix.Sigaction = .{
        .handler = .{ .handler = if (fd == null) posix.SIG.DFL else Signals.handle },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESTART,
    };
    for ([_]posix.SIG{ .WINCH, .TERM, .HUP, .INT }) |signal| posix.sigaction(signal, &action, null);
}

/// Takes signal events independently of the wake bytes, which may coalesce.
pub fn takeSignals() struct { resized: bool, quit: bool } {
    const pending = Signals.pending.swap(0, .monotonic);
    return .{ .resized = pending & 1 != 0, .quit = pending & 2 != 0 };
}

/// Cells `text` takes on screen: two for East Asian wide characters and
/// most emoji, none for combining marks, one otherwise, including for bytes
/// that aren't valid UTF-8.
pub fn textWidth(text: []const u8) usize {
    var width: usize = 0;
    var rest = text;
    while (rest.len > 0) {
        const len = charLen(rest);
        const char = std.unicode.utf8Decode(rest[0..len]) catch 0xfffd;
        width += switch (char) {
            0x0300...0x036f, 0x200b...0x200f, 0xfe00...0xfe0f => 0,
            0x1100...0x115f, 0x2e80...0xa4cf, 0xac00...0xd7a3, 0xf900...0xfaff, 0xfe30...0xfe4f, 0xff00...0xff60, 0xffe0...0xffe6, 0x1f300...0x1f64f, 0x1f900...0x1f9ff, 0x20000...0x3fffd => 2,
            else => 1,
        };
        rest = rest[len..];
    }
    return width;
}

/// Writes display text without interpreting filename or input bytes as
/// terminal commands. Invalid UTF-8 and control characters occupy one cell.
pub fn writeText(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    var rest = text;
    while (rest.len > 0) {
        const len = charLen(rest);
        const char = std.unicode.utf8Decode(rest[0..len]) catch 0;
        if ((len == 1 and rest[0] >= 0x80) or char < 0x20 or (char >= 0x7f and char <= 0x9f)) {
            try writer.writeByte('?');
        } else {
            try writer.writeAll(rest[0..len]);
        }
        rest = rest[len..];
    }
}

/// Bytes of the first character in `text`: its UTF-8 sequence, or one for
/// a byte that doesn't start a valid one.
pub fn charLen(text: []const u8) usize {
    std.debug.assert(text.len > 0);
    const len = std.unicode.utf8ByteSequenceLength(text[0]) catch return 1;
    if (len > text.len) return 1;
    _ = std.unicode.utf8Decode(text[0..len]) catch return 1;
    return len;
}

/// Moves the cursor to a cell, counting from 0.
pub fn moveCursor(writer: *std.Io.Writer, row: u32, col: u32) std.Io.Writer.Error!void {
    try writer.print("\x1b[{d};{d}H", .{ row + 1, col + 1 });
}

/// Window size from the kernel, falling back to asking the terminal for the
/// cell size when the kernel doesn't know it.
pub fn size(input: *std.Io.Reader, output: *std.Io.Writer) Error!Size {
    var ws: posix.winsize = undefined;
    if (std.c.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, &ws) != 0 or ws.col == 0 or ws.row == 0)
        return error.NotATerminal;
    if (ws.xpixel >= ws.col and ws.ypixel >= ws.row) return .{
        .cols = ws.col,
        .rows = ws.row,
        .cell_width = ws.xpixel / ws.col,
        .cell_height = ws.ypixel / ws.row,
    };

    // The reply is `ESC [ 6 ; height ; width t`.
    const reply = try query(input, output, "\x1b[16t");
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
/// which is absent if the terminal does not support the request. The result
/// is valid until `input` is read again.
pub fn query(input: *std.Io.Reader, output: *std.Io.Writer, comptime request: []const u8) Error![]const u8 {
    output.writeAll(request ++ da1_request) catch return error.Unexpected;
    output.flush() catch return error.Unexpected;

    while (true) {
        const received = input.buffered();
        // DA1 reply: `ESC [ ? <digits and semicolons> c`.
        if (std.mem.lastIndexOf(u8, received, "\x1b[?")) |start| {
            const params = received[start + 3 ..];
            if (std.mem.indexOfNone(u8, params, "0123456789;")) |i| {
                if (params[i] == 'c') {
                    const reply = received[0 .. start + 3 + i + 1];
                    input.toss(reply.len);
                    return reply;
                }
            }
        }
        if (received.len == input.buffer.len) return error.ReplyTooLong;
        input.fillMore() catch |err| return switch (err) {
            error.EndOfStream => error.NoReply,
            error.ReadFailed => error.Unexpected,
        };
    }
}

// ====================================================================================================
// Tests
// ====================================================================================================

test {
    _ = Key;
}

test "a full wake pipe preserves signals without blocking or changing errno" {
    var fds: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(0, std.c.pipe(&fds));
    defer for (fds) |fd| {
        _ = std.c.close(fd);
    };
    const flags: c_int = @bitCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
    try std.testing.expectEqual(0, std.c.fcntl(fds[1], posix.F.SETFL, flags));
    notifySignals(fds[1]);
    defer notifySignals(null);
    var bytes: [4096]u8 = undefined;
    @memset(&bytes, 't');
    while (std.c.write(fds[1], &bytes, bytes.len) > 0) {}
    while (std.c.write(fds[1], &bytes, 1) > 0) {}
    const saved = std.c._errno().*;
    Signals.handle(.WINCH);
    Signals.handle(.TERM);
    try std.testing.expectEqual(saved, std.c._errno().*);
    const events = takeSignals();
    try std.testing.expect(events.resized);
    try std.testing.expect(events.quit);
    const cleared = takeSignals();
    try std.testing.expect(!cleared.resized and !cleared.quit);
}
