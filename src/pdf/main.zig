//! ptz's PDF engine interface: open a document, query pages, render them to
//! RGBA pixels.
//!
//! This API is ptz's own and deliberately engine-neutral, so the engine behind
//! it (currently PDFium, via `pdfium.zig`) can be replaced without touching
//! callers. Keep PDFium types and concepts out of the public declarations.
//!
//! All functions are safe to call from any thread. PDFium itself is not
//! thread-safe, so calls are serialized on one process-wide lock; an engine
//! that can render in parallel would drop that lock without API changes.

// std
const std = @import("std");

// local
const pdfium = @import("pdfium.zig");

// ====================================================================================================
// Types
// ====================================================================================================

pub const Error = error{
    FileNotFound,
    InvalidFormat,
    PasswordRequired,
    UnsupportedSecurity,
    PageNotFound,
    Unexpected,
};

/// Page size in points (1/72 inch).
pub const Size = struct {
    width: f32,
    height: f32,
};

/// Caller-owned RGBA pixels, row-major with no padding between rows.
pub const Bitmap = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn alloc(gpa: std.mem.Allocator, width: u32, height: u32) std.mem.Allocator.Error!Bitmap {
        return .{ .width = width, .height = height, .pixels = try gpa.alloc(u8, @as(usize, width) * height * 4) };
    }

    pub fn free(bitmap: Bitmap, gpa: std.mem.Allocator) void {
        gpa.free(bitmap.pixels);
    }
};

pub const Document = struct {
    io: std.Io,
    handle: *pdfium.FPDF_DOCUMENT,

    pub fn open(io: std.Io, path: [:0]const u8, password: ?[:0]const u8) Error!Document {
        engine_lock.lockUncancelable(io);
        defer engine_lock.unlock(io);

        if (!engine_initialized) {
            pdfium.FPDF_InitLibrary();
            engine_initialized = true;
        }
        const handle = pdfium.FPDF_LoadDocument(path, if (password) |p| p.ptr else null) orelse
            return lastError();
        return .{ .io = io, .handle = handle };
    }

    pub fn close(doc: Document) void {
        engine_lock.lockUncancelable(doc.io);
        defer engine_lock.unlock(doc.io);
        pdfium.FPDF_CloseDocument(doc.handle);
    }

    pub fn pageCount(doc: Document) u32 {
        engine_lock.lockUncancelable(doc.io);
        defer engine_lock.unlock(doc.io);
        return @intCast(pdfium.FPDF_GetPageCount(doc.handle));
    }

    pub fn pageSize(doc: Document, page: u32) Error!Size {
        engine_lock.lockUncancelable(doc.io);
        defer engine_lock.unlock(doc.io);

        var size: pdfium.FS_SIZEF = undefined;
        if (pdfium.FPDF_GetPageSizeByIndexF(doc.handle, try pageIndex(doc, page), &size) == 0)
            return error.PageNotFound;
        return .{ .width = size.width, .height = size.height };
    }

    /// Renders `page` scaled to fill `target` exactly, on a white background.
    /// Match the target's aspect ratio to `pageSize` to avoid distortion.
    pub fn render(doc: Document, page: u32, target: Bitmap) Error!void {
        engine_lock.lockUncancelable(doc.io);
        defer engine_lock.unlock(doc.io);

        const handle = pdfium.FPDF_LoadPage(doc.handle, try pageIndex(doc, page)) orelse return lastError();
        defer pdfium.FPDF_ClosePage(handle);

        const width: c_int = @intCast(target.width);
        const height: c_int = @intCast(target.height);
        // Wraps the caller's buffer; destroying it leaves the pixels alone.
        const bitmap = pdfium.FPDFBitmap_CreateEx(width, height, pdfium.FPDFBitmap_BGRA, target.pixels.ptr, width * 4) orelse
            return error.Unexpected;
        defer pdfium.FPDFBitmap_Destroy(bitmap);

        _ = pdfium.FPDFBitmap_FillRect(bitmap, 0, 0, width, height, 0xFFFFFFFF);
        pdfium.FPDF_RenderPageBitmap(bitmap, handle, 0, 0, width, height, 0, pdfium.FPDF_ANNOT | pdfium.FPDF_REVERSE_BYTE_ORDER);
    }
};

// ====================================================================================================
// Fields
// ====================================================================================================

var engine_lock: std.Io.Mutex = .init;
var engine_initialized = false;

// ====================================================================================================
// Private Functions
// ====================================================================================================

/// Validates `page` and converts it to PDFium's index type. Call with the
/// engine lock held.
fn pageIndex(doc: Document, page: u32) Error!c_int {
    if (page >= pdfium.FPDF_GetPageCount(doc.handle)) return error.PageNotFound;
    return @intCast(page);
}

fn lastError() Error {
    return switch (pdfium.FPDF_GetLastError()) {
        .file => error.FileNotFound,
        .format => error.InvalidFormat,
        .password => error.PasswordRequired,
        .security => error.UnsupportedSecurity,
        .page => error.PageNotFound,
        else => error.Unexpected,
    };
}

// ====================================================================================================
// Tests
// ====================================================================================================

test "renders a page in RGBA at the requested scale" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const doc = try Document.open(io, "src/pdf/testdata/red-square.pdf", null);
    defer doc.close();
    try std.testing.expectEqual(1, doc.pageCount());

    // 200x100 pt page with a red 40x40 pt square at (20, 20) from the bottom left.
    const size = try doc.pageSize(0);
    try std.testing.expectEqual(Size{ .width = 200, .height = 100 }, size);

    const bitmap = try Bitmap.alloc(gpa, 400, 200);
    defer bitmap.free(gpa);
    try doc.render(0, bitmap);

    const pixel = struct {
        fn at(b: Bitmap, x: usize, y: usize) [4]u8 {
            return b.pixels[(y * b.width + x) * 4 ..][0..4].*;
        }
    }.at;
    // Square spans x 40..120 and y 80..160 (from the top) at 2x.
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, pixel(bitmap, 80, 120));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, pixel(bitmap, 300, 40));

    try std.testing.expectError(error.PageNotFound, doc.render(1, bitmap));
}

test "open reports why a file cannot be loaded" {
    const io = std.testing.io;
    try std.testing.expectError(error.FileNotFound, Document.open(io, "src/pdf/testdata/missing.pdf", null));
    try std.testing.expectError(error.InvalidFormat, Document.open(io, "build.zig", null));
}
