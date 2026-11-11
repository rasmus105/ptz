// std
const std = @import("std");

// project
const app = @import("app/main.zig");
const graphics = @import("graphics/main.zig");
const terminal = @import("terminal/main.zig");

// local
const cli = @import("cli.zig");

// ====================================================================================================
// Constants
// ====================================================================================================

/// Restores the terminal before reporting a panic, so the message isn't lost
/// on the alternate screen and the shell isn't left in raw mode.
pub const panic = std.debug.FullPanic(panicRestoringTerminal);

// ====================================================================================================
// Public API
// ====================================================================================================

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const options = try cli.parse(init);

    // Large enough that a typical tile upload goes out in a few writes.
    var stdout_buffer: [256 * 1024]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const raw = terminal.RawMode.enter() catch std.process.fatal("input is not a terminal", .{});
    defer raw.restore();

    var input_buffer: [1024]u8 = undefined;
    var input: terminal.Input = .init(&input_buffer, 1000);
    const size = terminal.size(&input.interface, stdout) catch |err| switch (err) {
        error.NotATerminal => fail("output is not a terminal", .{}),
        else => fail("cannot determine the terminal size: {t}", .{err}),
    };
    // Forcing the protocol skips detection, so also the faster medium.
    const detected = if (options.protocol == .auto) graphics.detect(&input.interface, stdout) catch |err| switch (err) {
        error.NoReply => null,
        else => fail("cannot query the terminal: {t}", .{err}),
    } else .direct;
    const medium = detected orelse fail(
        "terminal does not support the kitty graphics protocol (use --protocol kitty to try anyway)",
        .{},
    );

    app.run(io, init.gpa, .{
        .path = options.file,
        .page = options.page,
        .dark = options.dark,
        .watch = options.watch,
        .medium = medium,
    }, size, stdout) catch |err| switch (err) {
        error.FileNotFound => fail("cannot open '{s}': file not found", .{options.file}),
        error.AccessDenied => fail("cannot open '{s}': permission denied", .{options.file}),
        error.FileTooBig => fail("cannot open '{s}': file too big", .{options.file}),
        error.InvalidFormat => fail("cannot open '{s}': not a PDF file, or corrupted", .{options.file}),
        error.PasswordRequired => fail("cannot open '{s}': password protected", .{options.file}),
        error.UnsupportedSecurity => fail("cannot open '{s}': unsupported encryption", .{options.file}),
        else => return err,
    };
}

// ====================================================================================================
// Private Functions
// ====================================================================================================

/// `std.process.fatal`, after leaving raw mode, which `fatal` would skip.
fn fail(comptime format: []const u8, args: anytype) noreturn {
    terminal.restoreAfterCrash();
    std.process.fatal(format, args);
}

fn panicRestoringTerminal(message: []const u8, first_trace_address: ?usize) noreturn {
    terminal.restoreAfterCrash();
    std.debug.defaultPanic(message, first_trace_address);
}

// ====================================================================================================
// Tests
// ====================================================================================================

test {
    _ = @import("argparse.zig");
    _ = app;
    _ = graphics;
    _ = @import("pdf/main.zig");
    _ = terminal;
    _ = @import("viewer/main.zig");
}
