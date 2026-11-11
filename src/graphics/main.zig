//! Displays images in the terminal.
//!
//! The interface is protocol-neutral so other image protocols can be added
//! later; for now it always uses Kitty's graphics protocol (`kitty.zig`).

// std
const std = @import("std");

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
