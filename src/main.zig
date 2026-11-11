// std
const std = @import("std");

// local
const cli = @import("cli.zig");
const graphics = @import("graphics/main.zig");
const pdf = @import("pdf/main.zig");
const terminal = @import("terminal/main.zig");

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
        options.file, switch (err) {
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

    const term = terminal.size(io) catch |err| switch (err) {
        error.NotATerminal => fatal("output is not a terminal", .{}),
        else => fatal("cannot determine the terminal size: {t}", .{err}),
    };
    if (options.protocol == .auto) {
        const supported = graphics.supported(io) catch |err| switch (err) {
            error.NoReply => false,
            else => fatal("cannot query the terminal: {t}", .{err}),
        };
        if (!supported) fatal(
            "terminal does not support the kitty graphics protocol (use --protocol kitty to try anyway)",
            .{},
        );
    }

    // Fit the page to the window, leaving the last row for the prompt.
    const page_size = try doc.pageSize(page);
    const max_width: f32 = @floatFromInt(@as(u32, term.cols) * term.cell_width);
    const max_height: f32 = @floatFromInt(@as(u32, term.rows -| 1) * term.cell_height);
    const scale = @min(max_width / page_size.width, max_height / page_size.height);
    const bitmap = try pdf.Bitmap.alloc(
        gpa,
        @max(1, @as(u32, @intFromFloat(page_size.width * scale))),
        @max(1, @as(u32, @intFromFloat(page_size.height * scale))),
    );
    defer bitmap.free(gpa);
    try doc.render(page, bitmap);

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try graphics.draw(stdout, .{ .width = bitmap.width, .height = bitmap.height, .pixels = bitmap.pixels });
    try stdout.writeAll("\n");
    try stdout.flush();
}

// ====================================================================================================
// Tests
// ====================================================================================================

test {
    _ = @import("argparse.zig");
    _ = graphics;
    _ = pdf;
    _ = terminal;
}
