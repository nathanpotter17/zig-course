/* The single-header pattern: a header is only declarations until one translation unit defines
   the *_IMPLEMENTATION macro before including it; then it's the whole library. This file is that
   translation unit. The build compiles it as C and links the result into the program. */
#define STB_IMAGE_IMPLEMENTATION
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image.h"
#include "stb_image_write.h"
