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

const Link = extern struct {
    area: document.Rect,
    uri: ?[*:0]const u8,
    page: i32,
    x: f32,
    y: f32,
};

const LinkCollector = struct {
    page: u32,
    gpa: std.mem.Allocator,
    links: *std.ArrayList(document.Link),
    limit: usize,
    failure: ?document.Error = null,

    fn append(context: *anyopaque, entry: *const Link) callconv(.c) c_int {
        const collector: *LinkCollector = @ptrCast(@alignCast(context));
        const gpa = collector.gpa;
        var target: document.Link.Target = if (entry.uri) |uri| blk: {
            const text = std.mem.span(uri);
            if (text.len > 4096) return 0;
            // Only hand web URLs to the OS opener. An unambiguous authority
            // and printable ASCII also keep the confirmation honest.
            for (text) |byte| {
                if (byte < 0x21 or byte > 0x7e or byte == '\\') return 0;
            }
            const parsed = std.Uri.parse(text) catch return 0;
            if ((!std.ascii.eqlIgnoreCase(parsed.scheme, "http") and
                !std.ascii.eqlIgnoreCase(parsed.scheme, "https")) or
                parsed.host == null or parsed.host.?.percent_encoded.len == 0 or
                std.mem.findScalar(u8, parsed.host.?.percent_encoded, '%') != null or
                parsed.user != null or parsed.password != null)
                return 0;
            break :blk .{ .url = .{
                .uri = text,
                .authority_end = std.mem.findAnyPos(u8, text, parsed.scheme.len + 3, "/?#") orelse text.len,
            } };
        } else .{ .position = .{
            .page = @intCast(entry.page),
            .x = if (std.math.isFinite(entry.x)) entry.x else null,
            .y = if (std.math.isFinite(entry.y)) entry.y else null,
        } };
        if (collector.links.items.len >= collector.limit) {
            collector.failure = error.FileTooBig;
            return 1;
        }
        if (target == .url) {
            target.url.uri = gpa.dupe(u8, target.url.uri) catch {
                collector.failure = error.OutOfMemory;
                return 1;
            };
        }
        collector.links.append(gpa, .{ .page = collector.page, .area = entry.area, .target = target }) catch {
            if (target == .url) gpa.free(target.url.uri);
            collector.failure = error.OutOfMemory;
            return 1;
        };
        return 0;
    }
};

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

    pub fn open(io: std.Io, bytes: []const u8, mode: document.Document.OpenMode) document.Error!Document {
        engine_lock.lockUncancelable(io);
        defer engine_lock.unlock(io);
        var handle: ?*Handle = null;
        var count: u32 = undefined;
        try check(ptz_mupdf_open(bytes.ptr, bytes.len, 512 * 1024 * 1024, @intFromBool(mode == .replacement), &handle, &count));
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

    pub fn appendLinks(doc: *const Document, page: u32, region: document.Rect, gpa: std.mem.Allocator, links: *std.ArrayList(document.Link), limit: usize) document.Error!void {
        engine_lock.lockUncancelable(doc.io);
        defer engine_lock.unlock(doc.io);
        var collector: LinkCollector = .{ .page = page, .gpa = gpa, .links = links, .limit = limit };
        try check(ptz_mupdf_links(doc.handle, page, &region, LinkCollector.append, &collector));
        if (collector.failure) |err| return err;
    }

    pub fn searchPage(doc: *const Document, page: u32, query: [:0]const u8, parts: []document.MatchPart) document.Error!document.PageMatches {
        if (page >= doc.page_count) return error.PageNotFound;
        if (query.len == 0 or std.mem.findScalar(u8, query, 0) != null) return .{ .parts = parts[0..0], .truncated = false };
        engine_lock.lockUncancelable(doc.io);
        defer engine_lock.unlock(doc.io);
        var count: usize = undefined;
        var truncated: bool = undefined;
        try check(ptz_mupdf_search(doc.handle, page, query.ptr, parts.ptr, parts.len, &count, &truncated));
        return .{ .parts = parts[0..count], .truncated = truncated };
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

extern fn ptz_mupdf_open(bytes: [*]const u8, length: usize, budget: usize, replacement: c_int, result: *?*Handle, page_count: *u32) Status;
extern fn ptz_mupdf_close(doc: *Handle) void;
extern fn ptz_mupdf_page_size(doc: *Handle, page: u32, width: *f32, height: *f32) Status;
extern fn ptz_mupdf_links(doc: *Handle, page: u32, region: *const document.Rect, callback: *const fn (*anyopaque, *const Link) callconv(.c) c_int, context: *anyopaque) Status;
extern fn ptz_mupdf_search(doc: *Handle, page: u32, query: [*:0]const u8, parts: [*]document.MatchPart, capacity: usize, count: *usize, truncated: *bool) Status;
extern fn ptz_mupdf_render(doc: *Handle, page: u32, page_width: u32, page_height: u32, x: u32, y: u32, width: u32, height: u32, pixels: [*]u8) Status;

// ====================================================================================================
// Tests
// ====================================================================================================

test "JPEG opens reject truncated scan data even at reduced validation resolution" {
    const jpeg = @embedFile("testdata/red-square.jpg");
    const truncated = jpeg[0 .. jpeg.len - 80];
    for ([_]document.Document.OpenMode{ .initial, .replacement }) |mode| {
        try std.testing.expectError(error.InvalidFormat, Document.open(std.testing.io, truncated, mode));
    }
}

test "decoder allocations obey a total budget and failures leave the engine usable" {
    const io = std.testing.io;
    Document.engine_lock.lockUncancelable(io);
    defer Document.engine_lock.unlock(io);
    const bytes = @embedFile("testdata/budget.png");
    var handle: ?*Handle = null;
    var count: u32 = undefined;
    const small = @embedFile("testdata/rgba.png");
    try check(ptz_mupdf_open(small.ptr, small.len, 1024 * 1024, 0, &handle, &count));
    ptz_mupdf_close(handle.?);
    const limited = ptz_mupdf_open(bytes.ptr, bytes.len, 1024 * 1024, 0, &handle, &count);
    if (handle) |doc| ptz_mupdf_close(doc);
    try std.testing.expectError(error.FileTooBig, check(limited));
    try std.testing.expectEqual(null, handle);

    try check(ptz_mupdf_open(bytes.ptr, bytes.len, 16 * 1024 * 1024, 0, &handle, &count));
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
    try check(ptz_mupdf_open(bytes.ptr, bytes.len, 3 * 1024 * 1024, 0, &handle, &count));
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
