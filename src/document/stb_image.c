#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

/* Limit all decoder allocations, including PNG inflation and conversion
 * buffers. Zig copies the result before freeing it, so no C allocation
 * survives into the next decode or crosses threads. */
#define PIXEL_BYTES_MAX ((size_t)256 * 1024 * 1024)
#define DIMENSION_MAX 100000

static _Thread_local size_t limit;
static _Thread_local size_t allocated;
static _Thread_local int exhausted;

typedef union {
    max_align_t alignment;
    size_t size;
} Allocation;

static void *image_malloc(size_t size) {
    if (size > limit - allocated) {
        exhausted = 1;
        return NULL;
    }
    Allocation *allocation = malloc(sizeof(Allocation) + size);
    if (!allocation) {
        exhausted = 1;
        return NULL;
    }
    allocation->size = size;
    allocated += size;
    return allocation + 1;
}

static void image_free(void *pointer) {
    if (!pointer) return;
    Allocation *allocation = (Allocation *)pointer - 1;
    allocated -= allocation->size;
    free(allocation);
}

static void *image_realloc(void *pointer, size_t size) {
    if (!pointer) return image_malloc(size);
    Allocation *allocation = (Allocation *)pointer - 1;
    size_t previous = allocation->size;
    if (size > limit - (allocated - previous)) {
        exhausted = 1;
        return NULL;
    }
    allocation = realloc(allocation, sizeof(Allocation) + size);
    if (!allocation) {
        exhausted = 1;
        return NULL;
    }
    allocation->size = size;
    allocated = allocated - previous + size;
    return allocation + 1;
}

#define STBI_MALLOC image_malloc
#define STBI_REALLOC image_realloc
#define STBI_FREE image_free
#define STBI_NO_STDIO
#define STBI_MAX_DIMENSIONS DIMENSION_MAX
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

/* Status: 0 success, 1 invalid format, 2 too large, 3 out of memory. */
int ptz_image_load(const unsigned char *bytes, int length, size_t budget,
                   int *width, int *height, unsigned char **pixels) {
    limit = budget;
    allocated = 0;
    exhausted = 0;
    int channels;
    if (!stbi_info_from_memory(bytes, length, width, height, &channels))
        return exhausted ? 3 : 1;
    if (*width <= 0 || *height <= 0) return 1;
    if (*width > DIMENSION_MAX || *height > DIMENSION_MAX ||
        (uint64_t)*width * (uint64_t)*height > PIXEL_BYTES_MAX / 4)
        return 2;
    int expected_width = *width;
    int expected_height = *height;
    *pixels = stbi_load_from_memory(bytes, length, width, height, &channels, 4);
    if (!*pixels) return exhausted ? 3 : 1;
    /* Never trust metadata from one decoder path to validate another. */
    if (*width != expected_width || *height != expected_height) {
        stbi_image_free(*pixels);
        *pixels = NULL;
        return 1;
    }
    return 0;
}

void ptz_image_free(unsigned char *pixels) {
    stbi_image_free(pixels);
}
