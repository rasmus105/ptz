#include "mupdf/fitz.h"

#include <stdlib.h>

static void *bounded_malloc(void *user, size_t size)
{
    (void)user;
    return size <= 2 * 1024 * 1024 ? malloc(size) : NULL;
}

static void *bounded_realloc(void *user, void *pointer, size_t size)
{
    (void)user;
    return size <= 2 * 1024 * 1024 ? realloc(pointer, size) : NULL;
}

static void bounded_free(void *user, void *pointer)
{
    (void)user;
    free(pointer);
}

static int mitchell_scale(void *user, int dw, int dh, int sw, int sh)
{
    (void)user;
    (void)dw;
    (void)dh;
    (void)sw;
    (void)sh;
    return 1;
}

/* The document API does not rotate scalable images. Exercise the native
 * boundary directly so a small rotated crop cannot allocate a whole image. */
int ptz_test_rotated_scalable_crop(void)
{
    fz_alloc_context allocator = {NULL, bounded_malloc, bounded_realloc, bounded_free};
    fz_context *ctx = fz_new_context(&allocator, NULL, 0);
    if (!ctx) return 1;
    fz_tune_image_scale(ctx, mitchell_scale, NULL);
    fz_display_list *list = NULL;
    fz_device *device = NULL;
    fz_path *path = NULL;
    fz_image *image = NULL;
    fz_pixmap *pixmap = NULL;
    int failed = 0;
    fz_var(list);
    fz_var(device);
    fz_var(path);
    fz_var(image);
    fz_var(pixmap);
    fz_var(failed);
    fz_try(ctx) {
        list = fz_new_display_list(ctx, (fz_rect){0, 0, 160, 160});
        device = fz_new_list_device(ctx, list);
        path = fz_new_path(ctx);
        fz_rectto(ctx, path, 0, 0, 160, 160);
        float red[3] = {1, 0, 0};
        fz_fill_path(ctx, device, path, 0, fz_identity, fz_device_rgb(ctx), red, 1, fz_default_color_params);
        fz_close_device(ctx, device);
        fz_drop_device(ctx, device);
        device = NULL;
        image = fz_new_image_from_display_list(ctx, 160, 160, list);
        pixmap = fz_new_pixmap_with_bbox(ctx, fz_device_rgb(ctx), (fz_irect){2000, 3750, 2064, 3814}, NULL, 1);
        fz_clear_pixmap_with_value(ctx, pixmap, 255);
        device = fz_new_draw_device(ctx, fz_identity, pixmap);
        fz_matrix transform = fz_concat(fz_scale(6000, 6000), fz_rotate(17));
        fz_fill_image(ctx, device, image, transform, 1, fz_default_color_params);
        fz_close_device(ctx, device);
        unsigned char *pixels = fz_pixmap_samples(ctx, pixmap);
        for (int i = 0; i < 64 * 64; i++) {
            if (pixels[i * 4] != 255 || pixels[i * 4 + 1] != 0 ||
                pixels[i * 4 + 2] != 0 || pixels[i * 4 + 3] != 255) failed = 1;
        }
    }
    fz_always(ctx) {
        fz_drop_device(ctx, device);
        fz_drop_pixmap(ctx, pixmap);
        fz_drop_image(ctx, image);
        fz_drop_path(ctx, path);
        fz_drop_display_list(ctx, list);
    }
    fz_catch(ctx) {
        failed = 1;
    }
    fz_drop_context(ctx);
    return failed;
}
