//! Displays images in the terminal.
//!
//! The interface is protocol-neutral so other image protocols can be added
//! later; for now it always uses Kitty's graphics protocol (`kitty.zig`).

// std
const std = @import("std");

// project
const terminal = @import("../terminal/main.zig");

// local
const kitty = @import("kitty.zig");

// ====================================================================================================
// Types
// ====================================================================================================

pub const Image = struct {
    width: u32,
    height: u32,
    /// RGBA, row-major with no padding between rows.
    pixels: []const u8,
};

// ====================================================================================================
// Public API
// ====================================================================================================

/// Whether the terminal can display images, by asking it directly.
pub fn supported(io: std.Io) terminal.Error!bool {
    return kitty.supported(io);
}

/// Draws `image` at the cursor at its native pixel size. The terminal moves
/// the cursor past the image afterwards.
pub fn draw(writer: *std.Io.Writer, image: Image) std.Io.Writer.Error!void {
    try kitty.draw(writer, image);
}

// ====================================================================================================
// Tests
// ====================================================================================================

test {
    _ = kitty;
}
