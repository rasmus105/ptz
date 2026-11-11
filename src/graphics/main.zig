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

/// How image data reaches the terminal.
pub const Medium = enum {
    /// Compressed and base64-encoded inside the escape sequences. Works
    /// everywhere, including over ssh.
    direct,
    /// Raw pixels in a shared memory object that the terminal reads and
    /// deletes. Skips compression, but only works when the terminal runs on
    /// the same machine.
    shared_memory,
};

/// An image ready to transmit: preparing it is the expensive part of an
/// upload, and is safe to do off the UI thread.
pub const Encoded = struct {
    width: u32,
    height: u32,
    data: union(Medium) {
        /// Base64 of the zlib-compressed pixels, owned.
        direct: []const u8,
        /// Name of the shared memory object holding the pixels.
        shared_memory: kitty.SharedMemoryName,
    },

    pub fn init(gpa: std.mem.Allocator, medium: Medium, image: Image) !Encoded {
        return .{ .width = image.width, .height = image.height, .data = switch (medium) {
            .direct => .{ .direct = try kitty.encode(gpa, image) },
            .shared_memory => .{ .shared_memory = try kitty.share(image) },
        } };
    }

    /// Frees an image that won't be transmitted.
    pub fn deinit(encoded: Encoded, gpa: std.mem.Allocator) void {
        switch (encoded.data) {
            .direct => |base64| gpa.free(base64),
            .shared_memory => |name| kitty.unshare(name),
        }
    }

    /// Bytes `transmit` writes to the terminal.
    pub fn transmitLen(encoded: Encoded) usize {
        return switch (encoded.data) {
            .direct => |base64| base64.len,
            .shared_memory => 64,
        };
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

/// The best medium the terminal accepts, by asking it directly, or null if
/// it can't display images.
pub fn detect(input: *std.Io.Reader, output: *std.Io.Writer) terminal.Error!?Medium {
    return kitty.detect(input, output);
}

/// Uploads an image under `id`, replacing any image with that id. Consumes
/// `encoded`, whose data now belongs to the terminal.
pub fn transmit(gpa: std.mem.Allocator, writer: *std.Io.Writer, id: ImageId, encoded: Encoded) std.Io.Writer.Error!void {
    defer if (encoded.data == .direct) gpa.free(encoded.data.direct);
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
