//! PDFium backend. All engine calls share one lock because PDFium is not thread-safe.

// std
const std = @import("std");

// local
const document = @import("main.zig");
const pdfium = @import("pdfium.zig");

// aliases
const Error = document.Error;
const Size = document.Size;
const Bitmap = document.Bitmap;
const View = document.View;

// ====================================================================================================
// Constants
// ====================================================================================================

/// Pages kept parsed between renders. Rendering a page in several tiles
/// would otherwise parse it once per tile.
const loaded_pages_max = 4;

// ====================================================================================================
// Types
// ====================================================================================================

pub const Document = struct {
    io: std.Io,
    handle: *pdfium.FPDF_DOCUMENT,
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

    pub fn open(io: std.Io, bytes: []const u8) Error!Document {
        engine_lock.lockUncancelable(io);
        defer engine_lock.unlock(io);
        if (!engine_initialized) {
            pdfium.FPDF_InitLibrary();
            engine_initialized = true;
        }
        // A newly created file can be opened before its producer writes a PDF.
        const handle = (if (bytes.len == 0)
            pdfium.FPDF_CreateNewDocument()
        else
            pdfium.FPDF_LoadMemDocument64(bytes.ptr, bytes.len, null)) orelse return lastError();
        return .{
            .io = io,
            .handle = handle,
            .loaded_pages = @splat(.{ .index = 0, .handle = null, .last_used = 0 }),
            .load_clock = 0,
        };
    }

    pub fn close(doc: *Document) void {
        engine_lock.lockUncancelable(doc.io);
        for (doc.loaded_pages) |page| if (page.handle) |handle| pdfium.FPDF_ClosePage(handle);
        pdfium.FPDF_CloseDocument(doc.handle);
        engine_lock.unlock(doc.io);
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
    if (std.math.isNan(points)) return document.page_size_min;
    return std.math.clamp(@abs(points), document.page_size_min, document.page_size_max);
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
