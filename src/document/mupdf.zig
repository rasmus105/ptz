//! Owns the MuPDF handle behind the document API. The C bridge contains all
//! engine exceptions; none may jump past Zig's resource cleanup.

// std
const std = @import("std");

// local
const document = @import("main.zig");

// ====================================================================================================
// Types
// ====================================================================================================

const Handle = opaque {};

/// Mirrors the private bridge's status codes in mupdf.h.
const Status = enum(c_int) {
    ok,
    invalid_format,
    password_required,
    file_too_big,
    out_of_memory,
    page_not_found,
    unexpected,
    _,
};

pub const Document = struct {
    io: std.Io,
    handle: *Handle,
    page_count: u32,

    // Independent contexts still share engine internals. Serializing creation,
    // use and destruction preserves the public document's any-thread contract.
    var engine_lock: std.Io.Mutex = .init;

    pub fn open(io: std.Io, bytes: []const u8) document.Error!Document {
        engine_lock.lockUncancelable(io);
        defer engine_lock.unlock(io);
        var handle: ?*Handle = null;
        var count: u32 = undefined;
        try check(ptz_mupdf_open(bytes.ptr, bytes.len, 512 * 1024 * 1024, &handle, &count));
        return .{ .io = io, .handle = handle.?, .page_count = count };
    }

    pub fn close(doc: *Document) void {
        const io = doc.io;
        engine_lock.lockUncancelable(io);
        defer engine_lock.unlock(io);
        ptz_mupdf_close(doc.handle);
        doc.* = undefined;
    }

    pub fn pageCount(doc: *const Document) u32 {
        return doc.page_count;
    }

    pub fn pageSize(doc: *const Document, page: u32) document.Error!document.Size {
        engine_lock.lockUncancelable(doc.io);
        defer engine_lock.unlock(doc.io);
        var width: f32 = undefined;
        var height: f32 = undefined;
        try check(ptz_mupdf_page_size(doc.handle, page, &width, &height));
        // Native image sizes honor DPI. Scale tiny pages together so clamping
        // a sub-point dimension does not distort a narrow image's proportions.
        const smallest = @min(@abs(width), @abs(height));
        const scale = if (smallest > 0 and smallest < document.page_size_min)
            document.page_size_min / smallest
        else
            1;
        return .{ .width = clampSize(width * scale), .height = clampSize(height * scale) };
    }

    pub fn render(doc: *Document, page: u32, view: document.View, target: document.Bitmap) document.Error!void {
        engine_lock.lockUncancelable(doc.io);
        defer engine_lock.unlock(doc.io);
        try check(ptz_mupdf_render(doc.handle, page, view.page_width, view.page_height, view.x, view.y, target.width, target.height, target.pixels.ptr));
    }
};

// ====================================================================================================
// Private Functions
// ====================================================================================================

fn clampSize(points: f32) f32 {
    if (std.math.isNan(points)) return document.page_size_min;
    return std.math.clamp(@abs(points), document.page_size_min, document.page_size_max);
}

fn check(status: Status) document.Error!void {
    return switch (status) {
        .ok => {},
        .invalid_format => error.InvalidFormat,
        .password_required => error.PasswordRequired,
        .file_too_big => error.FileTooBig,
        .out_of_memory => error.OutOfMemory,
        .page_not_found => error.PageNotFound,
        else => error.Unexpected,
    };
}

extern fn ptz_mupdf_open(bytes: [*]const u8, length: usize, budget: usize, result: *?*Handle, page_count: *u32) Status;
extern fn ptz_mupdf_close(doc: *Handle) void;
extern fn ptz_mupdf_page_size(doc: *Handle, page: u32, width: *f32, height: *f32) Status;
extern fn ptz_mupdf_render(doc: *Handle, page: u32, page_width: u32, page_height: u32, x: u32, y: u32, width: u32, height: u32, pixels: [*]u8) Status;

// ====================================================================================================
// Tests
// ====================================================================================================

test "decoder allocations obey a total budget and failures leave the engine usable" {
    const io = std.testing.io;
    Document.engine_lock.lockUncancelable(io);
    defer Document.engine_lock.unlock(io);
    const bytes = @embedFile("testdata/budget.png");
    var handle: ?*Handle = null;
    var count: u32 = undefined;
    const small = @embedFile("testdata/rgba.png");
    try check(ptz_mupdf_open(small.ptr, small.len, 1024 * 1024, &handle, &count));
    ptz_mupdf_close(handle.?);
    const limited = ptz_mupdf_open(bytes.ptr, bytes.len, 1024 * 1024, &handle, &count);
    if (handle) |doc| ptz_mupdf_close(doc);
    try std.testing.expectError(error.FileTooBig, check(limited));
    try std.testing.expectEqual(null, handle);

    try check(ptz_mupdf_open(bytes.ptr, bytes.len, 16 * 1024 * 1024, &handle, &count));
    defer ptz_mupdf_close(handle.?);
    var pixels: [4]u8 = undefined;
    try check(ptz_mupdf_render(handle.?, 0, 1, 1, 0, 0, 1, 1, &pixels));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, pixels);
}

test "multipage images remain viewable when decoded pages exceed the cache budget" {
    const io = std.testing.io;
    Document.engine_lock.lockUncancelable(io);
    defer Document.engine_lock.unlock(io);
    // Six compressed 512x512 RGB pages fit individually, but their decoded
    // pixels together exceed this budget even without the engine's overhead.
    const bytes = @embedFile("testdata/cache.tiff");
    var handle: ?*Handle = null;
    var count: u32 = undefined;
    try check(ptz_mupdf_open(bytes.ptr, bytes.len, 3 * 1024 * 1024, &handle, &count));
    defer ptz_mupdf_close(handle.?);
    try std.testing.expectEqual(@as(u32, 6), count);
    const colors = [_][4]u8{
        .{ 255, 0, 0, 255 },   .{ 0, 255, 0, 255 },   .{ 0, 0, 255, 255 },
        .{ 255, 255, 0, 255 }, .{ 0, 255, 255, 255 }, .{ 255, 0, 255, 255 },
    };
    for ([_]u32{ 0, 1, 2, 3, 4, 5, 0, 5, 4, 3, 2, 1, 0 }) |page| {
        var width: f32 = undefined;
        var height: f32 = undefined;
        try check(ptz_mupdf_page_size(handle.?, page, &width, &height));
        var pixels: [4]u8 = undefined;
        try check(ptz_mupdf_render(handle.?, page, 1, 1, 0, 0, 1, 1, &pixels));
        try std.testing.expectEqual(colors[page], pixels);
    }
}
