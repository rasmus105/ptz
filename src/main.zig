// std
const std = @import("std");

// local
const cli = @import("cli.zig");
const graphics = @import("graphics/main.zig");
const pdf = @import("pdf/main.zig");
const terminal = @import("terminal/main.zig");
const viewer = @import("viewer/main.zig");

// ====================================================================================================
// Public API
// ====================================================================================================

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const options = try cli.parse(init);
    const fatal = std.process.fatal;

    const path = try init.arena.allocator().dupeSentinel(u8, options.file, 0);
    const doc = pdf.Document.open(io, path, null) catch |err| fatal("cannot open '{s}': {s}", .{
        options.file,
        switch (err) {
            error.FileNotFound => "file not found",
            error.InvalidFormat => "not a PDF file, or corrupted",
            error.PasswordRequired => "password protected",
            error.UnsupportedSecurity => "unsupported encryption",
            error.PageNotFound, error.Unexpected => "unexpected error",
        },
    });
    defer doc.close();

    const page_count = doc.pageCount();
    if (options.page == 0 or options.page > page_count)
        fatal("page {d} is out of range, '{s}' has {d} pages", .{ options.page, options.file, page_count });
    const page = options.page - 1;

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    var input_buffer: [1024]u8 = undefined;
    var input: terminal.Input = .init(&input_buffer, 1000);

    // Results are checked after leaving raw mode, since `fatal` exits
    // without running defers.
    const raw = terminal.RawMode.enter() catch fatal("input is not a terminal", .{});
    const size_result = terminal.size(&input.interface, stdout);
    const supported_result = if (options.protocol == .auto) graphics.supported(&input.interface, stdout) else true;
    raw.restore();

    const size = size_result catch |err| switch (err) {
        error.NotATerminal => fatal("output is not a terminal", .{}),
        else => fatal("cannot determine the terminal size: {t}", .{err}),
    };
    const supported = supported_result catch |err| switch (err) {
        error.NoReply => false,
        else => fatal("cannot query the terminal: {t}", .{err}),
    };
    if (!supported) fatal(
        "terminal does not support the kitty graphics protocol (use --protocol kitty to try anyway)",
        .{},
    );

    try viewer.showPage(gpa, stdout, doc, page, size);
}

// ====================================================================================================
// Tests
// ====================================================================================================

test {
    _ = @import("argparse.zig");
    _ = graphics;
    _ = pdf;
    _ = terminal;
    _ = viewer;
}
