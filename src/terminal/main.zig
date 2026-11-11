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

/// Switches to the alternate screen and hides the cursor, and back.
pub const fullscreen_enter = "\x1b[?1049h\x1b[?25l";
pub const fullscreen_leave = "\x1b[?25h\x1b[?1049l";

/// Synchronized output (mode 2026): the terminal shows everything between
/// begin and end at once, so redraws don't flicker. Terminals without it
/// ignore it.
pub const sync_begin = "\x1b[?2026h";
pub const sync_end = "\x1b[?2026l";

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
        crash_restore = original;
        return .{ .original = original };
    }

    pub fn restore(mode: RawMode) void {
        posix.tcsetattr(posix.STDIN_FILENO, .NOW, mode.original) catch {};
        crash_restore = null;
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

// ====================================================================================================
// Fields
// ====================================================================================================

/// The settings to restore if the process dies in raw mode.
var crash_restore: ?posix.termios = null;
/// Written to on SIGWINCH; see `notifyOnResize`.
var resize_fd: posix.fd_t = -1;

// ====================================================================================================
// Public API
// ====================================================================================================

/// Puts the terminal back as it was before raw mode and full screen, for
/// paths that skip normal cleanup: panics and `std.process.fatal`.
pub fn restoreAfterCrash() void {
    const original = crash_restore orelse return;
    const reset = sync_end ++ fullscreen_leave;
    _ = std.c.write(posix.STDOUT_FILENO, reset, reset.len);
    posix.tcsetattr(posix.STDIN_FILENO, .NOW, original) catch {};
    crash_restore = null;
}

/// Writes a byte to `fd` whenever the window is resized, so an event loop
/// polling `fd` wakes up.
pub fn notifyOnResize(fd: posix.fd_t) void {
    resize_fd = fd;
    const action: posix.Sigaction = .{
        .handler = .{ .handler = onResize },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(.WINCH, &action, null);
}

/// Window size from the kernel, falling back to asking the terminal for the
/// cell size when the kernel doesn't know it.
pub fn size(input: *std.Io.Reader, output: *std.Io.Writer) Error!Size {
    var ws: posix.winsize = undefined;
    if (std.c.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, &ws) != 0 or ws.col == 0 or ws.row == 0)
        return error.NotATerminal;
    if (ws.xpixel != 0 and ws.ypixel != 0) return .{
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
// Private Functions
// ====================================================================================================

fn onResize(_: posix.SIG) callconv(.c) void {
    _ = std.c.write(resize_fd, "r", 1);
}

// ====================================================================================================
// Tests
// ====================================================================================================

test {
    _ = Key;
}
