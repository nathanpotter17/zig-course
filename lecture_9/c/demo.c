/* A C program that uses the Zig library through its header and libimgfilters.a.
   Build and run with `zig build run-c`; the build script compiles this file with Zig's bundled
   clang and links the library it built from filters.zig. */
#include <stdio.h>
#include "filters.h"

int main(void) {
    printf("%s\n", filters_version());

    uint8_t pixels[] = {255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255};
    const size_t count = sizeof pixels / 3;

    filters_grayscale(pixels, count);
    printf("grayscale:");
    for (size_t i = 0; i < count; i++) printf(" %u", pixels[i * 3]);
    printf("\n");

    filters_invert(pixels, sizeof pixels);
    printf("inverted: ");
    for (size_t i = 0; i < count; i++) printf(" %u", pixels[i * 3]);
    printf("\n");
    return 0;
}
