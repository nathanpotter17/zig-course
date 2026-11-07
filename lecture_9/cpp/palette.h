/* The C interface to the C++ color counter in palette.cpp.
   C++ has no stable ABI (name mangling, class layout and exception handling differ between
   compilers), so what crosses the boundary is plain C: an opaque pointer, a plain struct, and
   integer return codes. The same header works from C, C++ and Zig. */
#ifndef PALETTE_H
#define PALETTE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque: the caller only ever holds a pointer to it. The definition lives in palette.cpp. */
typedef struct Palette Palette;

typedef struct {
    uint8_t r, g, b;
    uint32_t count;
} PaletteEntry;

/* NULL if out of memory. */
Palette *palette_create(void);
void palette_destroy(Palette *p);

/* Counts pixel_count RGB pixels (three bytes each). Returns 0, or -1 if out of memory. */
int palette_add_pixels(Palette *p, const uint8_t *rgb, size_t pixel_count);

/* How many different colors have been seen. */
size_t palette_distinct(const Palette *p);

/* The most frequent colors, most frequent first, into out; returns how many were written. */
size_t palette_top(const Palette *p, PaletteEntry *out, size_t max_entries);

#ifdef __cplusplus
}
#endif

#endif
