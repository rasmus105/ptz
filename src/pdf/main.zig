//! ptz's PDF engine interface: open a document, query pages, render them to
//! RGBA pixels.
//!
//! This API is ptz's own and deliberately engine-neutral, so the engine behind
//! it (currently PDFium, via `pdfium.zig`) can be replaced without touching
//! callers. Keep PDFium types and concepts out of the public declarations.
//!
//! A `Document` is safe to use from any thread. PDFium itself is not
//! thread-safe, so calls are serialized on one process-wide lock; an engine
//! that can render in parallel would drop that lock without API changes.

// std
const std = @import("std");

// local
const pdfium = @import("pdfium.zig");

// ====================================================================================================
// Constants
// ====================================================================================================

/// Larger files are refused rather than read into memory.
const file_size_max = 1024 * 1024 * 1024;

/// Page sizes are clamped to this range of points, so a malformed or hostile
/// document can't make callers compute with zero, negative, huge or NaN
/// sizes. 100000 pt is about 35 m.
pub const page_size_min = 1;
pub const page_size_max = 100_000;

/// Pages kept parsed between renders. Rendering a page in several tiles
/// would otherwise parse it once per tile.
const loaded_pages_max = 4;

// ====================================================================================================
// Types
// ====================================================================================================

pub const Error = error{
    FileNotFound,
    IsDir,
    AccessDenied,
    FileTooBig,
    InvalidFormat,
    PasswordRequired,
    UnsupportedSecurity,
    PageNotFound,
    OutOfMemory,
    Unexpected,
};

/// Page size in points (1/72 inch), within [`page_size_min`, `page_size_max`].
pub const Size = struct {
    width: f32,
    height: f32,
};

/// RGBA pixels, row-major with no padding between rows.
pub const Bitmap = struct {
    width: u32,
    height: u32,
    pixels: []u8,
};

/// Which part of a page to render: the page is scaled to `page_width` by
/// `page_height` pixels, and the bitmap receives the pixels starting at
/// (`x`, `y`). Rendering a page in tiles keeps each bitmap small at high zoom.
pub const View = struct {
    page_width: u32,
    page_height: u32,
    x: u32,
    y: u32,
};

pub const Document = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    handle: *pdfium.FPDF_DOCUMENT,
    /// The whole file. The document is read from memory so that a file being
    /// rewritten while open can't change what it reads.
    bytes: []const u8,
    loaded_pages: [loaded_pages_max]LoadedPage,
    /// Incremented on each page load, to evict the least recently used page.
    load_clock: u64,

    var engine_lock: std.Io.Mutex = .init;
    var engine_initialized = false;

    const LoadedPage = struct {
        index: u32,
        handle: ?*pdfium.FPDF_PAGE,
        last_used: u64,
    };

    pub fn open(io: std.Io, gpa: std.mem.Allocator, path: []const u8) Error!Document {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(file_size_max)) catch |err| return switch (err) {
            error.FileNotFound => error.FileNotFound,
            error.IsDir => error.IsDir,
            error.AccessDenied, error.PermissionDenied => error.AccessDenied,
            error.StreamTooLong => error.FileTooBig,
            error.OutOfMemory => error.OutOfMemory,
            else => error.Unexpected,
        };
        errdefer gpa.free(bytes);

        engine_lock.lockUncancelable(io);
        defer engine_lock.unlock(io);
        if (!engine_initialized) {
            pdfium.FPDF_InitLibrary();
            engine_initialized = true;
        }
        const handle = pdfium.FPDF_LoadMemDocument64(bytes.ptr, bytes.len, null) orelse return lastError();
        return .{
            .io = io,
            .gpa = gpa,
            .handle = handle,
            .bytes = bytes,
            .loaded_pages = @splat(.{ .index = 0, .handle = null, .last_used = 0 }),
            .load_clock = 0,
        };
    }

    pub fn close(doc: *Document) void {
        engine_lock.lockUncancelable(doc.io);
        for (doc.loaded_pages) |page| if (page.handle) |handle| pdfium.FPDF_ClosePage(handle);
        pdfium.FPDF_CloseDocument(doc.handle);
        engine_lock.unlock(doc.io);
        doc.gpa.free(doc.bytes);
        doc.* = undefined;
    }

    pub fn pageCount(doc: *const Document) u32 {
        engine_lock.lockUncancelable(doc.io);
        defer engine_lock.unlock(doc.io);
        return @intCast(pdfium.FPDF_GetPageCount(doc.handle));
    }

    pub fn pageSize(doc: *const Document, page: u32) Error!Size {
        engine_lock.lockUncancelable(doc.io);
        defer engine_lock.unlock(doc.io);

        var size: pdfium.FS_SIZEF = undefined;
        if (pdfium.FPDF_GetPageSizeByIndexF(doc.handle, try pageIndex(doc, page), &size) == 0)
            return error.PageNotFound;
        return .{ .width = clampSize(size.width), .height = clampSize(size.height) };
    }

    /// Renders the part of `page` that `view` selects into `target`, on a
    /// white background. Pixels outside the page stay white.
    pub fn render(doc: *Document, page: u32, view: View, target: Bitmap) Error!void {
        std.debug.assert(view.page_width > 0);
        std.debug.assert(view.page_height > 0);
        std.debug.assert(target.pixels.len == @as(usize, target.width) * target.height * 4);
        engine_lock.lockUncancelable(doc.io);
        defer engine_lock.unlock(doc.io);

        const handle = try doc.loadPage(page);
        const width: c_int = @intCast(target.width);
        const height: c_int = @intCast(target.height);
        // Wraps the caller's buffer; destroying it leaves the pixels alone.
        const bitmap = pdfium.FPDFBitmap_CreateEx(width, height, pdfium.FPDFBitmap_BGRA, target.pixels.ptr, width * 4) orelse
            return error.Unexpected;
        defer pdfium.FPDFBitmap_Destroy(bitmap);
        _ = pdfium.FPDFBitmap_FillRect(bitmap, 0, 0, width, height, 0xFFFFFFFF);

        // PDFium draws the whole page at the given size and position, clipped
        // to the bitmap, so a negative position selects a tile.
        pdfium.FPDF_RenderPageBitmap(
            bitmap,
            handle,
            -@as(c_int, @intCast(view.x)),
            -@as(c_int, @intCast(view.y)),
            @intCast(view.page_width),
            @intCast(view.page_height),
            0,
            pdfium.FPDF_ANNOT | pdfium.FPDF_REVERSE_BYTE_ORDER,
        );
    }

    /// Returns `page` parsed, from the cache or by loading it. Call with the
    /// engine lock held.
    fn loadPage(doc: *Document, page: u32) Error!*pdfium.FPDF_PAGE {
        doc.load_clock += 1;
        for (&doc.loaded_pages) |*loaded| {
            if (loaded.handle != null and loaded.index == page) {
                loaded.last_used = doc.load_clock;
                return loaded.handle.?;
            }
        }
        const handle = pdfium.FPDF_LoadPage(doc.handle, try pageIndex(doc, page)) orelse return lastError();
        var oldest = &doc.loaded_pages[0];
        for (doc.loaded_pages[1..]) |*loaded| {
            if (loaded.last_used < oldest.last_used) oldest = loaded;
        }
        if (oldest.handle) |evicted| pdfium.FPDF_ClosePage(evicted);
        oldest.* = .{ .index = page, .handle = handle, .last_used = doc.load_clock };
        return handle;
    }
};

// ====================================================================================================
// Private Functions
// ====================================================================================================

/// Validates `page` and converts it to PDFium's index type. Call with the
/// engine lock held.
fn pageIndex(doc: *const Document, page: u32) Error!c_int {
    if (page >= pdfium.FPDF_GetPageCount(doc.handle)) return error.PageNotFound;
    return @intCast(page);
}

fn clampSize(points: f32) f32 {
    if (std.math.isNan(points)) return page_size_min;
    return std.math.clamp(@abs(points), page_size_min, page_size_max);
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

fn testBitmap(gpa: std.mem.Allocator, width: u32, height: u32) !Bitmap {
    return .{ .width = width, .height = height, .pixels = try gpa.alloc(u8, @as(usize, width) * height * 4) };
}

fn pixel(bitmap: Bitmap, x: usize, y: usize) [4]u8 {
    return bitmap.pixels[(y * bitmap.width + x) * 4 ..][0..4].*;
}

test "renders a page in RGBA at the requested size" {
    const gpa = std.testing.allocator;
    var doc = try Document.open(std.testing.io, gpa, "src/pdf/testdata/red-square.pdf");
    defer doc.close();
    try std.testing.expectEqual(1, doc.pageCount());

    // 200x100 pt page with a red 40x40 pt square at (20, 20) from the bottom left.
    try std.testing.expectEqual(Size{ .width = 200, .height = 100 }, try doc.pageSize(0));

    const bitmap = try testBitmap(gpa, 400, 200);
    defer gpa.free(bitmap.pixels);
    const view: View = .{ .page_width = 400, .page_height = 200, .x = 0, .y = 0 };
    try doc.render(0, view, bitmap);
    // Square spans x 40..120 and y 80..160 (from the top) at 2x.
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, pixel(bitmap, 80, 120));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, pixel(bitmap, 300, 40));

    try std.testing.expectError(error.PageNotFound, doc.render(1, view, bitmap));
}

test "a tile matches the same region of the whole page" {
    const gpa = std.testing.allocator;
    var doc = try Document.open(std.testing.io, gpa, "src/pdf/testdata/red-square.pdf");
    defer doc.close();

    const whole = try testBitmap(gpa, 400, 200);
    defer gpa.free(whole.pixels);
    try doc.render(0, .{ .page_width = 400, .page_height = 200, .x = 0, .y = 0 }, whole);
    // A tile straddling the square's top left corner at (40, 80).
    const tile = try testBitmap(gpa, 64, 48);
    defer gpa.free(tile.pixels);
    try doc.render(0, .{ .page_width = 400, .page_height = 200, .x = 20, .y = 60 }, tile);

    for (0..tile.height) |y| {
        try std.testing.expectEqualSlices(
            u8,
            whole.pixels[((y + 60) * whole.width + 20) * 4 ..][0 .. tile.width * 4],
            tile.pixels[y * tile.width * 4 ..][0 .. tile.width * 4],
        );
    }
}

test "page sizes are clamped to a sane range" {
    const gpa = std.testing.allocator;
    var doc = try Document.open(std.testing.io, gpa, "src/pdf/testdata/odd-sizes.pdf");
    defer doc.close();
    for (0..doc.pageCount()) |page| {
        const size = try doc.pageSize(@intCast(page));
        for ([_]f32{ size.width, size.height }) |points| {
            try std.testing.expect(points >= page_size_min and points <= page_size_max);
        }
    }
}

test "open reports why a file cannot be loaded" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.FileNotFound, Document.open(std.testing.io, gpa, "src/pdf/testdata/missing.pdf"));
    try std.testing.expectError(error.InvalidFormat, Document.open(std.testing.io, gpa, "build.zig"));
}
