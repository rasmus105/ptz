#ifndef PTZ_MUPDF_H
#define PTZ_MUPDF_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct ptz_document ptz_document;

typedef enum {
    PTZ_OK,
    PTZ_INVALID_FORMAT,
    PTZ_PASSWORD_REQUIRED,
    PTZ_FILE_TOO_BIG,
    PTZ_OUT_OF_MEMORY,
    PTZ_PAGE_NOT_FOUND,
    PTZ_UNEXPECTED
} ptz_status;

typedef struct {
    float x0, y0, x1, y1;
} ptz_rect;

typedef struct {
    ptz_rect area;
    const char *uri;
    int32_t page;
    float x, y;
} ptz_link;

typedef struct {
    ptz_rect area;
    bool first;
} ptz_match_part;

/* Strings are borrowed during the callback. A nonzero return stops the walk. */
typedef int (*ptz_link_callback)(void *user, const ptz_link *link);

/* The caller retains bytes until close. All calls must be serialized. */
ptz_status ptz_mupdf_open(const unsigned char *bytes, size_t length, size_t budget,
                          ptz_document **result, uint32_t *page_count);
void ptz_mupdf_close(ptz_document *doc);
ptz_status ptz_mupdf_page_size(ptz_document *doc, uint32_t page, float *width, float *height);
ptz_status ptz_mupdf_links(ptz_document *doc, uint32_t page, const ptz_rect *region,
                           ptz_link_callback callback, void *user);
ptz_status ptz_mupdf_search(ptz_document *doc, uint32_t page, const char *query,
                            ptz_match_part *parts, size_t capacity, size_t *count, bool *truncated);
ptz_status ptz_mupdf_render(ptz_document *doc, uint32_t page, uint32_t page_width,
                            uint32_t page_height, uint32_t x, uint32_t y,
                            uint32_t width, uint32_t height, unsigned char *pixels);

#endif
