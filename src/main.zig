// std
const std = @import("std");

// local
const cli = @import("cli.zig");

// ====================================================================================================
// Public API
// ====================================================================================================

pub fn main(init: std.process.Init) !void {
    const options = try cli.parse(init);

    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("open {s} at page {d} using {t}\n", .{ options.file, options.page, options.protocol });
    try stdout.flush();
}

// ====================================================================================================
// Tests
// ====================================================================================================

test {
    _ = @import("argparse.zig");
    _ = @import("pdf/main.zig");
}
