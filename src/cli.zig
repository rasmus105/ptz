//! ptz's command-line interface.

// packages
const build_options = @import("build_options");

// local
const argparse = @import("argparse.zig");

// ====================================================================================================
// Types
// ====================================================================================================

pub const Protocol = enum { auto, kitty };

pub const Options = struct {
    file: []const u8,
    page: u32 = 1,
    protocol: Protocol = .auto,

    pub const positional = .{ .file = "PDF file to open" };
    pub const shorts = .{ .page = 'p' };
    pub const help = .{
        .page = "Open at page N",
        .protocol = "Image protocol to use",
    };
};

const Cli = argparse.Cli(Options, .{
    .name = "ptz",
    .summary = "Render PDFs in the terminal",
    .version = build_options.version,
    .examples = &.{ "ptz paper.pdf", "ptz -p 3 thesis.pdf" },
});

// ====================================================================================================
// Public API
// ====================================================================================================

pub const parse = Cli.parse;
