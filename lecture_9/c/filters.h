/* The C interface of the Zig library (src/filters.zig). Written by hand: each prototype matches an
   `export fn` on the Zig side, type for type (uint8_t* <-> [*]u8, size_t <-> usize, uint32_t <-> u32,
   const char* <-> [*:0]const u8). */
#ifndef FILTERS_H
#define FILTERS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The library's version string, including the Zig version it was built with. */
const char *filters_version(void);

/* RGB, three bytes per pixel, in place. */
void filters_grayscale(uint8_t *rgb, size_t pixel_count);

/* Any bytes, in place. */
void filters_invert(uint8_t *bytes, size_t len);

/* RGB box blur of the given radius from src into dst (same size, may not overlap). */
void filters_box_blur(const uint8_t *src_rgb, uint8_t *dst_rgb, uint32_t width, uint32_t height, uint32_t radius);

#ifdef __cplusplus
}
#endif

#endif
