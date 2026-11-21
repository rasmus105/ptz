#include "mupdf.h"
#include "mupdf/fitz.h"
#include "mupdf/pdf.h"

#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

/* Keep the supported input set explicit; the TXT handler accepts arbitrary
 * source files, and filename hints can override archive content recognition. */
extern fz_document_handler pdf_document_handler;
extern fz_document_handler xps_document_handler;
extern fz_document_handler svg_document_handler;
extern fz_document_handler cbz_document_handler;
extern fz_document_handler img_document_handler;
extern fz_document_handler epub_document_handler;
extern fz_document_handler fb2_document_handler;
extern fz_document_handler mobi_document_handler;

#define LOADED_PAGES_MAX 4
#define STORE_BYTES_MAX ((size_t)64 * 1024 * 1024)
#define IMAGE_DIMENSION_MAX 100000
#define IMAGE_PIXELS_MAX ((uint64_t)64 * 1024 * 1024)
/* MuPDF's scaler refuses larger extents; its affine fallback converts these
 * coordinates to signed integers and cannot safely represent arbitrary u32s. */
#define PAGE_PIXELS_MAX (1U << 24)

typedef union {
    max_align_t alignment;
    size_t size;
} Allocation;

typedef struct {
    int number;
    uint64_t last_used;
    fz_rect bounds;
    fz_page *page;
    fz_display_list *list;
} LoadedPage;

typedef struct {
    int number;
    uint64_t last_used;
    fz_rect bounds;
    fz_stext_page *text;
} TextPage;

/* MuPDF retains the allocator's user pointer, so this object stays in C-owned
 * storage even when its Zig owner moves between the render thread and UI. */
struct ptz_document {
    fz_context *ctx;
    fz_document *handle;
    size_t allocated;
    size_t budget;
    /* A failed attempt may succeed after MuPDF scavenges its store. Only use
     * this flag when an operation actually reports an allocation error. */
    int exhausted;
    uint64_t errors;
    uint64_t warnings;
    ptz_status reported_status;
    int page_count;
    uint64_t clock;
    LoadedPage pages[LOADED_PAGES_MAX];
    TextPage texts[LOADED_PAGES_MAX];
    bool maybe_raster, raster;
};

static void *document_malloc(void *user, size_t size)
{
    ptz_document *doc = user;
    if (size > SIZE_MAX - sizeof(Allocation) ||
        size + sizeof(Allocation) > doc->budget - doc->allocated) {
        doc->exhausted = 1;
        return NULL;
    }
    size += sizeof(Allocation);
    doc->exhausted = 0;
    Allocation *allocation = malloc(size);
    if (!allocation) return NULL;
    allocation->size = size;
    doc->allocated += size;
    return allocation + 1;
}

static void document_free(void *user, void *pointer)
{
    if (!pointer) return;
    ptz_document *doc = user;
    Allocation *allocation = (Allocation *)pointer - 1;
    doc->allocated -= allocation->size;
    free(allocation);
}

static void *document_realloc(void *user, void *pointer, size_t size)
{
    if (!pointer) return document_malloc(user, size);
    if (size == 0) {
        document_free(user, pointer);
        return NULL;
    }
    ptz_document *doc = user;
    Allocation *allocation = (Allocation *)pointer - 1;
    size_t previous = allocation->size;
    if (size > SIZE_MAX - sizeof(Allocation) ||
        size + sizeof(Allocation) > doc->budget - (doc->allocated - previous)) {
        doc->exhausted = 1;
        return NULL;
    }
    size += sizeof(Allocation);
    doc->exhausted = 0;
    allocation = realloc(allocation, size);
    if (!allocation) return NULL;
    allocation->size = size;
    doc->allocated = doc->allocated - previous + size;
    return allocation + 1;
}

static void record_warning(void *user, const char *message)
{
    /* The app reports errors after restoring the terminal; engine diagnostics
     * must not interleave with the terminal graphics stream. */
    ptz_document *doc = user;
    /* The pinned decoders report these optional-metadata failures immediately
     * before announcing their fallback. Discount only that paired format error;
     * allocation and system failures must still reach the caller. */
    if (!strcmp(message, "ignoring embedded ICC profile in PNG") ||
        !strcmp(message, "ignoring embedded ICC profile in JPEG") ||
        !strcmp(message, "ignoring embedded ICC profile")) {
        if (doc->errors && doc->reported_status == PTZ_INVALID_FORMAT)
            doc->errors--;
        return;
    }
    /* MuPDF has no warning codes. Keep this allowlist tied to its pinned
     * source: unknown warnings remain fatal during raster validation so repaired
     * or missing pixels cannot replace a good watched snapshot. */
    /* Repetition summaries add no information beyond the original warning. */
    if (!strncmp(message, "... repeated ", 13) ||
        !strncmp(message, "lcms: ", 6) ||
        !strcmp(message, "invalid ICC profile name") ||
        !strcmp(message, "inconsistent number of icc profile chunks in jpeg") ||
        !strcmp(message, "skipping out of range icc profile chunk in jpeg") ||
        !strcmp(message, "embedded ICC profile does not match PNG colorspace") ||
        !strcmp(message, "deprecated JPEG in TIFF compression not fully supported"))
        return;
    doc->warnings++;
}

static void record_error(void *user, const char *message)
{
    ptz_document *doc = user;
    int code = fz_caught(doc->ctx);
    doc->errors++;
    doc->reported_status = PTZ_INVALID_FORMAT;
    if (doc->exhausted || code == FZ_ERROR_LIMIT)
        doc->reported_status = PTZ_FILE_TOO_BIG;
    else if (code == FZ_ERROR_SYSTEM)
        doc->reported_status = fz_caught_errno(doc->ctx) == ENOMEM ? PTZ_OUT_OF_MEMORY : PTZ_UNEXPECTED;
    (void)message;
}

static void reuse_image_decode(void *user, int width, int height, int l2factor, fz_irect *subarea)
{
    ptz_document *doc = user;
    uint64_t scale = (uint64_t)1 << l2factor;
    uint64_t pixels = (((uint64_t)width + scale - 1) >> l2factor) *
                      (((uint64_t)height + scale - 1) >> l2factor);
    /* Each viewer tile otherwise decodes a different source rectangle. Share
     * a whole subsampled image when its RGBA estimate leaves store headroom;
     * larger images retain MuPDF's bounded subarea decoding. */
    size_t budget = STORE_BYTES_MAX * 3 / 4;
    if (budget > doc->budget / 4) budget = doc->budget / 4;
    if (pixels <= budget / 4)
        *subarea = (fz_irect){0, 0, width, height};
}

static int stable_image_scale(void *user, int dst_width, int dst_height, int src_width, int src_height)
{
    /* MuPDF's affine upsampler accumulates fixed-point rounding from each
     * clip origin. Mitchell scaling keeps adjacent tiles in the same phase. */
    (void)user;
    (void)dst_width;
    (void)dst_height;
    (void)src_width;
    (void)src_height;
    return 1;
}

static ptz_status caught_error(ptz_document *doc)
{
    int code = fz_caught(doc->ctx);
    int system_error = code == FZ_ERROR_SYSTEM ? fz_caught_errno(doc->ctx) : 0;
    (void)fz_convert_error(doc->ctx, NULL);
    if (doc->exhausted || code == FZ_ERROR_LIMIT) return PTZ_FILE_TOO_BIG;
    if (code == FZ_ERROR_SYSTEM && system_error == ENOMEM) return PTZ_OUT_OF_MEMORY;
    if (code == FZ_ERROR_SYSTEM) return PTZ_UNEXPECTED;
    return PTZ_INVALID_FORMAT;
}

typedef struct {
    fz_device device;
    int scaled_jpeg;
} ValidationDevice;

/* Raw image handlers can expose several pages and defer pixel decoding. A
 * validation device checks every image through the public device interface,
 * without depending on the handler's private page layout. */
static void validate_image(fz_context *ctx, fz_device *device, fz_image *image,
                           fz_matrix transform, float alpha, fz_color_params params)
{
    (void)transform;
    (void)alpha;
    (void)params;
    if (image->w > IMAGE_DIMENSION_MAX || image->h > IMAGE_DIMENSION_MAX ||
        (uint64_t)image->w * (uint64_t)image->h > IMAGE_PIXELS_MAX)
        fz_throw(ctx, FZ_ERROR_LIMIT, "image too large");
    /* JPEG reads the full entropy stream at 1/8 IDCT scale. MuPDF needs two
     * pixels of slack when selecting this scale. Replacements still have to
     * pass the full-resolution allocation check. */
    fz_matrix target = fz_scale(fmaxf(1, (image->w >> 3) - 2), fmaxf(1, (image->h >> 3) - 2));
    fz_pixmap *pixmap = fz_get_pixmap_from_image(ctx, image, NULL,
        ((ValidationDevice *)device)->scaled_jpeg ? &target : NULL, NULL, NULL);
    fz_drop_pixmap(ctx, pixmap);
}

static void drop_pages(ptz_document *doc)
{
    for (int i = 0; i < LOADED_PAGES_MAX; i++) {
        fz_drop_stext_page(doc->ctx, doc->texts[i].text);
        doc->texts[i] = (TextPage){0};
        fz_drop_display_list(doc->ctx, doc->pages[i].list);
        fz_drop_page(doc->ctx, doc->pages[i].page);
        doc->pages[i] = (LoadedPage){0};
    }
}

static LoadedPage *load_page(ptz_document *doc, int number)
{
    fz_context *ctx = doc->ctx;
    doc->clock++;
    LoadedPage *oldest = &doc->pages[0];
    for (int i = 0; i < LOADED_PAGES_MAX; i++) {
        LoadedPage *loaded = &doc->pages[i];
        if (loaded->page && loaded->number == number) {
            loaded->last_used = doc->clock;
            return loaded;
        }
        if (loaded->last_used < oldest->last_used) oldest = loaded;
    }

    /* Image handlers can decode the entire page here. Release the victim
     * before loading so a full cache does not require a fifth page's memory. */
    fz_drop_display_list(ctx, oldest->list);
    fz_drop_page(ctx, oldest->page);
    *oldest = (LoadedPage){0};
    fz_page *page = NULL;
    fz_rect bounds = fz_empty_rect;
    uint64_t errors = doc->errors;
    fz_var(page);
    fz_try(ctx) {
        page = fz_load_page(ctx, doc->handle, number);
        bounds = fz_bound_page(ctx, page);
        if (doc->errors != errors)
            fz_throw(ctx, FZ_ERROR_FORMAT, "cannot load page completely");
    }
    fz_catch(ctx) {
        fz_drop_page(ctx, page);
        fz_rethrow(ctx);
    }
    *oldest = (LoadedPage){number, doc->clock, bounds, page, NULL};
    return oldest;
}

void ptz_mupdf_close(ptz_document *doc)
{
    if (!doc) return;
    if (doc->ctx) {
        drop_pages(doc);
        fz_drop_document(doc->ctx, doc->handle);
        fz_drop_context(doc->ctx);
    }
    free(doc);
}

ptz_status ptz_mupdf_open(const unsigned char *bytes, size_t length, size_t budget, int replacement,
                          ptz_document **result, uint32_t *page_count)
{
    *result = NULL;
    ptz_document *doc = calloc(1, sizeof(*doc));
    if (!doc) return PTZ_OUT_OF_MEMORY;
    doc->budget = budget;
    fz_alloc_context allocator = {doc, document_malloc, document_realloc, document_free};
    fz_context *ctx = fz_new_context(&allocator, NULL, STORE_BYTES_MAX);
    if (!ctx) {
        ptz_status status = doc->exhausted ? PTZ_FILE_TOO_BIG : PTZ_OUT_OF_MEMORY;
        free(doc);
        return status;
    }
    doc->ctx = ctx;
    fz_set_error_callback(ctx, record_error, doc);
    fz_set_warning_callback(ctx, record_warning, doc);
    fz_tune_image_decode(ctx, reuse_image_decode, doc);
    fz_tune_image_scale(ctx, stable_image_scale, NULL);
    fz_tune_image_rendering(ctx, FZ_IMAGE_RENDERING_BALANCE);

    /* A producer may create an empty file before writing its first document. */
    if (length == 0) {
        *result = doc;
        *page_count = 0;
        return PTZ_OK;
    }

    fz_stream *stream = NULL;
    fz_device *validator = NULL;
    ptz_status status = PTZ_OK;
    fz_var(stream);
    fz_var(validator);
    fz_var(status);
    fz_try(ctx) {
        fz_register_document_handler(ctx, &pdf_document_handler);
        fz_register_document_handler(ctx, &xps_document_handler);
        fz_register_document_handler(ctx, &svg_document_handler);
        fz_register_document_handler(ctx, &cbz_document_handler);
        fz_register_document_handler(ctx, &img_document_handler);
        fz_register_document_handler(ctx, &epub_document_handler);
        fz_register_document_handler(ctx, &fb2_document_handler);
        fz_register_document_handler(ctx, &mobi_document_handler);

        unsigned char signature[8] = {0};
        if (length >= sizeof(signature)) memcpy(signature, bytes, sizeof(signature));
        int format = length >= sizeof(signature) ? fz_recognize_image_format(ctx, signature) : FZ_IMAGE_UNKNOWN;

        /* UTF-8 BOM is valid XML, but the native SVG recognizer skips only
         * whitespace. The stream remains an immutable slice of our snapshot. */
        if (length >= 3 && !memcmp(bytes, "\xef\xbb\xbf", 3)) {
            size_t start = 3;
            while (start < length && (bytes[start] == ' ' || bytes[start] == '\t' ||
                                      bytes[start] == '\r' || bytes[start] == '\n'))
                start++;
            if (start < length && bytes[start] == '<') {
                bytes += 3;
                length -= 3;
            }
        }
        stream = fz_open_memory(ctx, bytes, length);
        doc->handle = fz_open_document_with_stream(ctx, "", stream);
        if (fz_needs_password(ctx, doc->handle)) {
            status = PTZ_PASSWORD_REQUIRED;
        } else {
            if (fz_is_document_reflowable(ctx, doc->handle))
                fz_layout_document(ctx, doc->handle, 450, 600, 12);
            doc->page_count = fz_count_pages(ctx, doc->handle);
            if (doc->page_count < 0) fz_throw(ctx, FZ_ERROR_FORMAT, "negative page count");
            /* Native image documents defer validation until a page is loaded.
             * Validate before a reload is allowed to replace a good snapshot. */
            if (format != FZ_IMAGE_UNKNOWN) {
                doc->maybe_raster = true;
                int scaled_jpeg = !replacement && format == FZ_IMAGE_JPEG;
                validator = fz_new_device_of_size(ctx, sizeof(ValidationDevice));
                ((ValidationDevice *)validator)->scaled_jpeg = scaled_jpeg;
                validator->fill_image = validate_image;
                for (int page = 0; page < doc->page_count; page++) {
                    LoadedPage *loaded = load_page(doc, page);
                    fz_cookie cookie = {0};
                    fz_run_page(ctx, loaded->page, validator, fz_identity, &cookie);
                    if (cookie.errors || cookie.incomplete)
                        fz_throw(ctx, FZ_ERROR_FORMAT, "cannot decode image completely");
                    /* A JPEG's first tiles can reuse its validated image. Keep
                     * multipage validation bounded to a single decoded page. */
                    if (!scaled_jpeg) drop_pages(doc);
                }
                fz_close_device(ctx, validator);
                /* PNG and JPEG decoders can repair truncated pixels with only
                 * a warning; those must not replace a good watched snapshot. */
                if (doc->errors) status = doc->reported_status;
                else if (doc->warnings) status = PTZ_INVALID_FORMAT;
            }
        }
    }
    fz_always(ctx) {
        fz_drop_device(ctx, validator);
        fz_drop_stream(ctx, stream);
    }
    fz_catch(ctx) {
        status = caught_error(doc);
    }
    if (status != PTZ_OK) {
        ptz_mupdf_close(doc);
        return status;
    }
    *result = doc;
    *page_count = (uint32_t)doc->page_count;
    return PTZ_OK;
}

ptz_status ptz_mupdf_page_size(ptz_document *doc, uint32_t page, float *width, float *height)
{
    if (page >= (uint32_t)doc->page_count) return PTZ_PAGE_NOT_FOUND;
    for (int attempt = 0; ; attempt++) {
        doc->exhausted = 0;
        uint64_t errors = doc->errors;
        ptz_status status = PTZ_OK;
        fz_try(doc->ctx) {
            fz_rect bounds;
            pdf_document *pdf = pdf_specifics(doc->ctx, doc->handle);
            if (pdf) {
                /* Layout needs the transformed crop box. Loading a PDF page
                 * would also initialize its links and annotations. */
                pdf_obj *obj = pdf_lookup_page_obj(doc->ctx, pdf, (int)page);
                fz_matrix matrix;
                pdf_page_obj_transform_box(doc->ctx, obj, &bounds, &matrix, FZ_CROP_BOX);
                bounds = fz_transform_rect(bounds, matrix);
            } else {
                bounds = load_page(doc, (int)page)->bounds;
            }
            *width = bounds.x1 - bounds.x0;
            *height = bounds.y1 - bounds.y0;
        }
        fz_catch(doc->ctx) {
            status = caught_error(doc);
        }
        if (doc->errors != errors && (status == PTZ_OK || status == PTZ_INVALID_FORMAT))
            status = doc->reported_status;
        if (attempt || (status != PTZ_FILE_TOO_BIG && status != PTZ_OUT_OF_MEMORY))
            return status;
        drop_pages(doc);
        fz_empty_store(doc->ctx);
    }
}

ptz_status ptz_mupdf_links(ptz_document *doc, uint32_t page, const ptz_rect *region,
                           ptz_link_callback callback, void *user)
{
    if (page >= (uint32_t)doc->page_count) return PTZ_PAGE_NOT_FOUND;
    fz_context *ctx = doc->ctx;
    fz_link *links = NULL;
    ptz_status status = PTZ_OK;
    doc->exhausted = 0;
    fz_var(links);
    fz_try(ctx) {
        LoadedPage *loaded = load_page(doc, (int)page);
        fz_rect bounds = loaded->bounds;
        float width = bounds.x1 - bounds.x0;
        float height = bounds.y1 - bounds.y0;
        if (!(width > 0) || !(height > 0) || !isfinite(width) || !isfinite(height))
            fz_throw(ctx, FZ_ERROR_FORMAT, "invalid link bounds");
        links = fz_load_links(ctx, loaded->page);
        pdf_document *pdf = pdf_specifics(ctx, doc->handle);
        for (fz_link *link = links; link; link = link->next) {
            fz_rect rect = link->rect;
            if (!link->uri || !link->uri[0] ||
                !isfinite(rect.x0) || !isfinite(rect.x1) ||
                !isfinite(rect.y0) || !isfinite(rect.y1))
                continue;
            ptz_link entry = {
                .area = {
                    fmaxf(region->x0, (rect.x0 - bounds.x0) / width),
                    fmaxf(region->y0, (rect.y0 - bounds.y0) / height),
                    fminf(region->x1, (rect.x1 - bounds.x0) / width),
                    fminf(region->y1, (rect.y1 - bounds.y0) / height),
                },
                .uri = link->uri,
                .page = -1,
                .x = NAN,
                .y = NAN,
            };
            if (entry.area.x0 >= entry.area.x1 || entry.area.y0 >= entry.area.y1)
                continue;
            if (!fz_is_external_link(ctx, link->uri)) {
                int target = -1;
                fz_var(target);
                fz_try(ctx) {
                    fz_link_dest dest = fz_resolve_link_dest(ctx, doc->handle, link->uri);
                    if (dest.loc.page >= 0 && dest.loc.chapter >= 0 &&
                        dest.loc.chapter < fz_count_chapters(ctx, doc->handle) &&
                        dest.loc.page < fz_count_chapter_pages(ctx, doc->handle, dest.loc.chapter)) {
                        target = fz_page_number_from_location(ctx, doc->handle, dest.loc);
                        if (target >= 0 && target < doc->page_count &&
                            (isfinite(dest.x) || isfinite(dest.y))) {
                            fz_rect target_bounds;
                            if (target == (int)page) {
                                target_bounds = bounds;
                            } else if (pdf) {
                                // A table of contents can target hundreds of pages.
                                // Get their geometry without loading their annotations.
                                fz_matrix matrix;
                                pdf_obj *obj = pdf_lookup_page_obj(ctx, pdf, target);
                                pdf_page_obj_transform_box(ctx, obj, &target_bounds, &matrix, FZ_CROP_BOX);
                                target_bounds = fz_transform_rect(target_bounds, matrix);
                            } else {
                                target_bounds = load_page(doc, target)->bounds;
                            }
                            float w = target_bounds.x1 - target_bounds.x0;
                            float h = target_bounds.y1 - target_bounds.y0;
                            if (w > 0 && isfinite(w)) entry.x = (dest.x - target_bounds.x0) / w;
                            if (h > 0 && isfinite(h)) entry.y = (dest.y - target_bounds.y0) / h;
                        }
                    }
                }
                fz_catch(ctx) {
                    if (fz_caught(ctx) == FZ_ERROR_SYSTEM || fz_caught(ctx) == FZ_ERROR_LIMIT)
                        fz_rethrow(ctx);
                    continue;
                }
                if (target < 0 || target >= doc->page_count) continue;
                entry.page = target;
                entry.uri = NULL;
            }
            if (callback(user, &entry)) break;
        }
    }
    fz_always(ctx) {
        fz_drop_link(ctx, links);
    }
    fz_catch(ctx) {
        status = caught_error(doc);
    }
    return status;
}

/* Keep the scan independent of the render LRU: searching a distant page
 * should not push the viewport's expensive display lists out of the cache. */
static TextPage *load_text(ptz_document *doc, int number)
{
    fz_context *ctx = doc->ctx;
    doc->clock++;
    TextPage *oldest = &doc->texts[0];
    LoadedPage *rendered = NULL;
    for (int i = 0; i < LOADED_PAGES_MAX; i++) {
        TextPage *entry = &doc->texts[i];
        if (entry->text && entry->number == number) {
            entry->last_used = doc->clock;
            return entry;
        }
        if (entry->last_used < oldest->last_used) oldest = entry;
        if (doc->pages[i].page && doc->pages[i].number == number)
            rendered = &doc->pages[i];
    }
    fz_drop_stext_page(ctx, oldest->text);
    *oldest = (TextPage){0};
    fz_page *temporary = NULL;
    uint64_t errors = doc->errors;
    fz_device *device = NULL;
    fz_var(temporary);
    fz_var(device);
    fz_try(ctx) {
        fz_stext_options options = { .flags = FZ_STEXT_DEHYPHENATE };
        fz_cookie cookie = {0};
        if (!rendered) temporary = fz_load_page(ctx, doc->handle, number);
        oldest->bounds = rendered ? rendered->bounds : fz_bound_page(ctx, temporary);
        if (rendered && rendered->list) {
            oldest->text = fz_new_stext_page_from_display_list(ctx, rendered->list, &options);
        } else {
            /* Match the render list, including visible annotations and widgets. */
            oldest->text = fz_new_stext_page(ctx, oldest->bounds);
            device = fz_new_stext_device(ctx, oldest->text, &options);
            fz_run_page(ctx, rendered ? rendered->page : temporary, device, fz_identity, &cookie);
            fz_close_device(ctx, device);
        }
        if (cookie.errors || cookie.incomplete || doc->errors != errors)
            fz_throw(ctx, FZ_ERROR_FORMAT, "cannot extract page text completely");
    }
    fz_always(ctx) {
        fz_drop_device(ctx, device);
        fz_drop_page(ctx, temporary);
    }
    fz_catch(ctx) {
        fz_drop_stext_page(ctx, oldest->text);
        *oldest = (TextPage){0};
        fz_rethrow(ctx);
    }
    oldest->number = number;
    oldest->last_used = doc->clock;
    return oldest;
}

/* The callback search API in MuPDF 1.28.6 ignores early termination.
 * Iterate directly to stop as soon as a whole occurrence will not fit. */
static bool search_text(fz_context *ctx, TextPage *page, const char *query,
                        ptz_match_part *parts, size_t capacity, size_t *count)
{
    fz_rect bounds = page->bounds;
    float w = bounds.x1 - bounds.x0, h = bounds.y1 - bounds.y0;
    if (!isfinite(w) || !isfinite(h) || !(w > 0 && h > 0))
        fz_throw(ctx, FZ_ERROR_FORMAT, "invalid search bounds");
    fz_search *search = fz_new_search(ctx, query, FZ_SEARCH_IGNORE_CASE);
    bool full = false;
    *count = 0;
    fz_try(ctx) {
        fz_feed_search(ctx, search, fz_keep_stext_page(ctx, page->text), 0);
        while (!full) {
            fz_search_result result = fz_search_forwards(ctx, search);
            if (result.reason == FZ_SEARCH_COMPLETE) break;
            if (result.reason == FZ_SEARCH_MORE_INPUT) {
                fz_feed_search(ctx, search, NULL, result.u.seq_needed);
                continue;
            }
            fz_search_match *match = result.u.match;
            size_t start = *count;
            for (int i = 0; i < match->num_quads; i++) {
                fz_rect r = fz_intersect_rect(fz_rect_from_quad(match->quads[i].quad), bounds);
                if (!(r.x0 < r.x1 && r.y0 < r.y1)) continue;
                if (*count == capacity) {
                    *count = start;
                    full = true;
                    break;
                }
                parts[*count] = (ptz_match_part){
                    {(r.x0 - bounds.x0) / w, (r.y0 - bounds.y0) / h,
                     (r.x1 - bounds.x0) / w, (r.y1 - bounds.y0) / h},
                    *count == start
                };
                (*count)++;
            }
        }
    }
    fz_always(ctx) {
        fz_drop_search(ctx, search);
    }
    fz_catch(ctx) {
        fz_rethrow(ctx);
    }
    return full;
}

ptz_status ptz_mupdf_search(ptz_document *doc, uint32_t page, const char *query,
                            ptz_match_part *parts, size_t capacity, size_t *count, bool *truncated)
{
    if (page >= (uint32_t)doc->page_count) return PTZ_PAGE_NOT_FOUND;
    fz_context *ctx = doc->ctx;
    for (int attempt = 0; ; attempt++) {
        doc->exhausted = 0;
        uint64_t errors = doc->errors;
        ptz_status status = PTZ_OK;
        fz_try(ctx) {
            if (doc->maybe_raster) {
                /* A recognizable image prefix alone need not identify the
                 * selected handler. Confirm it once, on the first search. */
                char format[16];
                if (fz_lookup_metadata(ctx, doc->handle, FZ_META_FORMAT, format, sizeof(format)) > 0)
                    doc->raster = !strcmp(format, "Image") || !strcmp(format, "PNM") ||
                        !strcmp(format, "TIFF") || !strcmp(format, "BMP") || !strcmp(format, "JBIG2");
                doc->maybe_raster = false;
            }
            if (doc->raster) {
                *count = 0;
                *truncated = false;
            } else {
                TextPage *loaded = load_text(doc, (int)page);
                *truncated = search_text(ctx, loaded, query, parts, capacity, count);
            }
        }
        fz_catch(ctx) {
            status = caught_error(doc);
        }
        if (doc->errors != errors && (status == PTZ_OK || status == PTZ_INVALID_FORMAT))
            status = doc->reported_status;
        if (attempt || (status != PTZ_FILE_TOO_BIG && status != PTZ_OUT_OF_MEMORY))
            return status;
        drop_pages(doc);
        fz_empty_store(ctx);
    }
}

ptz_status ptz_mupdf_render(ptz_document *doc, uint32_t page, uint32_t page_width,
                            uint32_t page_height, uint32_t x, uint32_t y,
                            uint32_t width, uint32_t height, unsigned char *pixels)
{
    if (page >= (uint32_t)doc->page_count) return PTZ_PAGE_NOT_FOUND;
    if (!page_width || !page_height || page_width > PAGE_PIXELS_MAX ||
        page_height > PAGE_PIXELS_MAX || width > INT_MAX / 4 || height > INT_MAX)
        return PTZ_FILE_TOO_BIG;
    if (!width || !height || x >= page_width || y >= page_height) {
        memset(pixels, 255, (size_t)width * height * 4);
        return PTZ_OK;
    }
    if (x > INT_MAX - width || y > INT_MAX - height) return PTZ_FILE_TOO_BIG;

    for (int attempt = 0; ; attempt++) {
        doc->exhausted = 0;
        uint64_t errors = doc->errors;
        memset(pixels, 255, (size_t)width * height * 4);
        fz_context *ctx = doc->ctx;
        fz_pixmap *pixmap = NULL;
        fz_device *device = NULL;
        fz_display_list *list = NULL;
        ptz_status status = PTZ_OK;
        fz_var(pixmap);
        fz_var(device);
        fz_var(list);
        fz_try(ctx) {
            LoadedPage *loaded = load_page(doc, (int)page);
            if (!loaded->list) {
                list = fz_new_display_list(ctx, loaded->bounds);
                device = fz_new_list_device(ctx, list);
                fz_cookie cookie = {0};
                fz_run_page(ctx, loaded->page, device, fz_identity, &cookie);
                fz_close_device(ctx, device);
                if (cookie.errors || cookie.incomplete || doc->errors != errors)
                    fz_throw(ctx, FZ_ERROR_FORMAT, "cannot interpret page completely");
                fz_drop_device(ctx, device);
                device = NULL;
                loaded->list = list;
                list = NULL;
            }
            fz_rect bounds = loaded->bounds;
            float w = bounds.x1 - bounds.x0;
            float h = bounds.y1 - bounds.y0;
            if (!isfinite(w) || !isfinite(h) || !isfinite(bounds.x0) ||
                !isfinite(bounds.y0) || w <= 0 || h <= 0)
                fz_throw(ctx, FZ_ERROR_FORMAT, "invalid page bounds");

            float sx = (float)page_width / w;
            float sy = (float)page_height / h;
            fz_matrix transform = {sx, 0, 0, sy, -bounds.x0 * sx, -bounds.y0 * sy};
            if (!isfinite(sx) || !isfinite(sy) || !isfinite(transform.e) || !isfinite(transform.f))
                fz_throw(ctx, FZ_ERROR_FORMAT, "invalid page transform");
            /* Keep the transform independent of the tile origin so floating-point
             * rounding and image interpolation agree across adjacent tiles. */
            fz_irect clip = {(int)x, (int)y,
                            (int)(x + (width < page_width - x ? width : page_width - x)),
                            (int)(y + (height < page_height - y ? height : page_height - y))};
            fz_irect bitmap = {(int)x, (int)y, (int)(x + width), (int)(y + height)};
            pixmap = fz_new_pixmap_with_bbox_and_data(ctx, fz_device_rgb(ctx), bitmap, NULL, 1, pixels);
            device = fz_new_draw_device_with_bbox(ctx, fz_identity, pixmap, &clip);
            fz_cookie cookie = {0};
            fz_run_display_list(ctx, loaded->list, device, transform, fz_rect_from_irect(clip), &cookie);
            fz_close_device(ctx, device);
            if (cookie.errors || cookie.incomplete || doc->errors != errors)
                fz_throw(ctx, FZ_ERROR_FORMAT, "cannot render page completely");
        }
        fz_always(ctx) {
            fz_drop_device(ctx, device);
            fz_drop_display_list(ctx, list);
            fz_drop_pixmap(ctx, pixmap);
        }
        fz_catch(ctx) {
            status = caught_error(doc);
        }
        if (doc->errors != errors && (status == PTZ_OK || status == PTZ_INVALID_FORMAT))
            status = doc->reported_status;
        if (attempt || (status != PTZ_FILE_TOO_BIG && status != PTZ_OUT_OF_MEMORY))
            return status;
        /* Release active devices and temporary lists before dropping cached pages.
         * Retrying once lets one large page use the budget without old pages. */
        drop_pages(doc);
        fz_empty_store(ctx);
    }
}
