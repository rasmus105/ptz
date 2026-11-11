//! Hand-written declarations for the subset of PDFium's C API that ptz uses,
//! mirroring `public/fpdfview.h`. Declared by hand rather than translated
//! from the headers because the surface is small and this lets the types
//! state nullability and opaqueness precisely. Only `main.zig` in this
//! directory should use these.
//!
//! None of these functions are thread-safe; callers must serialize all calls.

// ====================================================================================================
// Constants
// ====================================================================================================

pub const FPDFBitmap_BGRA = 4;

/// Render flags for `FPDF_RenderPageBitmap`.
pub const FPDF_ANNOT = 0x01;
/// With a BGRA bitmap, writes bytes in RGBA order instead.
pub const FPDF_REVERSE_BYTE_ORDER = 0x10;

// ====================================================================================================
// Types
// ====================================================================================================

pub const FPDF_DOCUMENT = opaque {};
pub const FPDF_PAGE = opaque {};
pub const FPDF_BITMAP = opaque {};

pub const FPDF_BOOL = c_int;

pub const FS_SIZEF = extern struct {
    width: f32,
    height: f32,
};

/// Values of `FPDF_ERR_*`.
pub const Err = enum(c_ulong) {
    success = 0,
    unknown = 1,
    file = 2,
    format = 3,
    password = 4,
    security = 5,
    page = 6,
    _,
};

// ====================================================================================================
// Public API
// ====================================================================================================

pub extern fn FPDF_InitLibrary() void;
pub extern fn FPDF_GetLastError() Err;

pub extern fn FPDF_LoadMemDocument64(data_buf: *const anyopaque, size: usize, password: ?[*:0]const u8) ?*FPDF_DOCUMENT;
pub extern fn FPDF_CloseDocument(document: *FPDF_DOCUMENT) void;
pub extern fn FPDF_GetPageCount(document: *FPDF_DOCUMENT) c_int;
pub extern fn FPDF_GetPageSizeByIndexF(document: *FPDF_DOCUMENT, page_index: c_int, size: *FS_SIZEF) FPDF_BOOL;

pub extern fn FPDF_LoadPage(document: *FPDF_DOCUMENT, page_index: c_int) ?*FPDF_PAGE;
pub extern fn FPDF_ClosePage(page: *FPDF_PAGE) void;
pub extern fn FPDF_RenderPageBitmap(
    bitmap: *FPDF_BITMAP,
    page: *FPDF_PAGE,
    start_x: c_int,
    start_y: c_int,
    size_x: c_int,
    size_y: c_int,
    rotate: c_int,
    flags: c_int,
) void;

pub extern fn FPDFBitmap_CreateEx(width: c_int, height: c_int, format: c_int, first_scan: ?*anyopaque, stride: c_int) ?*FPDF_BITMAP;
pub extern fn FPDFBitmap_FillRect(bitmap: *FPDF_BITMAP, left: c_int, top: c_int, width: c_int, height: c_int, color: c_ulong) FPDF_BOOL;
pub extern fn FPDFBitmap_Destroy(bitmap: *FPDF_BITMAP) void;
