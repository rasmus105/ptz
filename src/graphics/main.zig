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
const shm = @import("shm.zig");

// ====================================================================================================
// Types
// ====================================================================================================

/// Identifies an uploaded image. Chosen by the caller and shared with every
/// other program in the terminal, so pick them from a range unlikely to be
/// used elsewhere.
pub const ImageId = u32;

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

/// Pixels being prepared for upload: render RGBA into `pixels`, then
/// `finish`. With shared memory, `pixels` is the shared memory itself, so
/// filling it costs no copy. Safe to use off the UI thread.
pub const Canvas = struct {
    width: u32,
    height: u32,
    pixels: []u8,
    target: union(Medium) {
        /// `pixels` is allocated and gets compressed by `finish`.
        direct,
        shared_memory: shm.Object,
    },

    pub fn init(gpa: std.mem.Allocator, medium: Medium, width: u32, height: u32) !Canvas {
        std.debug.assert(width > 0 and height > 0);
        const len = @as(usize, width) * height * 4;
        return switch (medium) {
            .direct => .{ .width = width, .height = height, .pixels = try gpa.alloc(u8, len), .target = .direct },
            .shared_memory => blk: {
                const object = try shm.Object.create(len);
                break :blk .{ .width = width, .height = height, .pixels = object.memory, .target = .{ .shared_memory = object } };
            },
        };
    }

    /// Abandons the canvas.
    pub fn deinit(canvas: Canvas, gpa: std.mem.Allocator) void {
        switch (canvas.target) {
            .direct => gpa.free(canvas.pixels),
            .shared_memory => |object| {
                object.unmap();
                object.name.unlink();
            },
        }
    }

    /// Consumes the canvas, also on error.
    pub fn finish(canvas: Canvas, gpa: std.mem.Allocator) !Encoded {
        const data: Encoded.Data = switch (canvas.target) {
            .direct => blk: {
                defer gpa.free(canvas.pixels);
                break :blk .{ .direct = try kitty.encode(gpa, canvas.pixels) };
            },
            .shared_memory => |object| blk: {
                object.unmap();
                break :blk .{ .shared_memory = object.name };
            },
        };
        return .{ .width = canvas.width, .height = canvas.height, .data = data };
    }
};

/// An image ready to transmit.
pub const Encoded = struct {
    width: u32,
    height: u32,
    data: Data,

    pub const Data = union(Medium) {
        /// Base64 of the zlib-compressed pixels, owned.
        direct: []const u8,
        /// The shared memory object holding the pixels.
        shared_memory: shm.Name,
    };

    /// Frees an image that won't be transmitted.
    pub fn deinit(encoded: Encoded, gpa: std.mem.Allocator) void {
        switch (encoded.data) {
            .direct => |base64| gpa.free(base64),
            .shared_memory => |name| name.unlink(),
        }
    }

    /// Image data `transmit` writes to the terminal, in bytes; shared
    /// memory needs only a short command.
    pub fn transmitLen(encoded: Encoded) usize {
        return switch (encoded.data) {
            .direct => |base64| base64.len,
            .shared_memory => 0,
        };
    }
};

/// Cleanup ownership for a shared-memory upload until the terminal unlinks it.
/// A successful write or flush only queues bytes; the terminal may not have
/// opened the object yet, so callers retain this across image eviction.
pub const Transfer = struct {
    name: shm.Name,
    bytes: u64,

    pub fn pending(transfer: Transfer) bool {
        return transfer.name.exists();
    }

    pub fn deinit(transfer: Transfer) void {
        transfer.name.unlink();
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
/// `encoded`, also on error. Retain the returned cleanup token until the
/// terminal unlinks its object, or until output is abandoned.
pub fn transmit(gpa: std.mem.Allocator, writer: *std.Io.Writer, id: ImageId, encoded: Encoded) std.Io.Writer.Error!?Transfer {
    defer if (encoded.data == .direct) gpa.free(encoded.data.direct);
    errdefer if (encoded.data == .shared_memory) encoded.data.shared_memory.unlink();
    try kitty.transmit(writer, id, encoded);
    return switch (encoded.data) {
        .direct => null,
        .shared_memory => |name| .{ .name = name, .bytes = @as(u64, encoded.width) * encoded.height * 4 },
    };
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
    _ = shm;
}
