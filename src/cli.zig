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
    path: []const u8 = ".",
    page: u32 = 1,
    dark: bool = false,
    watch: bool = true,
    protocol: Protocol = .auto,

    pub const positional = .{ .path = "File or directory to open" };
    pub const shorts = .{ .page = 'p', .dark = 'd' };
    pub const help = .{
        .page = "Open at page N",
        .dark = "Start in dark mode (invert colours)",
        .watch = "Don't reload when the file changes",
        .protocol = "Image protocol to use",
    };
};

const Cli = argparse.Cli(Options, .{
    .name = "ptz",
    .summary = "Render documents and images in the terminal",
    .version = build_options.version,
    .examples = &.{ "ptz", "ptz scans/", "ptz -p 3 thesis.pdf" },
});

// ====================================================================================================
// Public API
// ====================================================================================================

pub const parse = Cli.parse;
