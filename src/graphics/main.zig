//! Displays images in the terminal.
//!
//! Images are uploaded once and then placed, in whole or in part, as often
//! as needed: redrawing a screen of already uploaded images sends a few
//! bytes per image rather than its pixels. Preparing an upload (`Encoded`)
//! is the expensive part and is safe to do off the UI thread.
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

/// Identifies an uploaded image. Chosen by the caller and shared with every
/// other program in the terminal, so pick them from a range unlikely to be
/// used elsewhere.
pub const ImageId = u32;

pub const Image = struct {
    width: u32,
    height: u32,
    /// RGBA, row-major with no padding between rows.
    pixels: []const u8,
};

/// An image ready to transmit.
pub const Encoded = struct {
    width: u32,
    height: u32,
    /// Protocol-specific payload, owned.
    base64: []const u8,

    pub fn init(gpa: std.mem.Allocator, image: Image) !Encoded {
        return .{ .width = image.width, .height = image.height, .base64 = try kitty.encode(gpa, image) };
    }

    pub fn deinit(encoded: Encoded, gpa: std.mem.Allocator) void {
        gpa.free(encoded.base64);
    }
};

/// Pixel rectangle within an image.
pub const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub const Placement = struct {
    image: ImageId,
    /// Part of the image to show.
    source: Rect,
    /// Cell of the top left corner, counting from 0.
    col: u16,
    row: u16,
    /// Pixel offset of the top left corner within that cell.
    x_offset: u16,
    y_offset: u16,
};

// ====================================================================================================
// Public API
// ====================================================================================================

/// Whether the terminal can display images, by asking it directly.
pub fn supported(input: *std.Io.Reader, output: *std.Io.Writer) terminal.Error!bool {
    return kitty.supported(input, output);
}

/// Uploads an image under `id`, replacing any image with that id.
pub fn transmit(writer: *std.Io.Writer, id: ImageId, encoded: Encoded) std.Io.Writer.Error!void {
    try kitty.transmit(writer, id, encoded);
}

/// Shows part of an uploaded image. The cursor ends up at the placement's
/// cell.
pub fn place(writer: *std.Io.Writer, placement: Placement) std.Io.Writer.Error!void {
    try kitty.place(writer, placement);
}

/// Removes every placed image from the screen; uploads are kept.
pub fn clearPlacements(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try kitty.clearPlacements(writer);
}

/// Deletes an upload, freeing the terminal's memory for it.
pub fn free(writer: *std.Io.Writer, id: ImageId) std.Io.Writer.Error!void {
    try kitty.free(writer, id);
}

// ====================================================================================================
// Tests
// ====================================================================================================

test {
    _ = kitty;
}
