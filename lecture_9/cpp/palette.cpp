// A C++ class behind the C interface declared in palette.h.
// The Zig compiler compiles this file with its bundled clang and links libc++, so std::unordered_map
// and friends are available; nothing C++-specific may leak through the interface, exceptions included.
#include "palette.h"

#include <algorithm>
#include <new>
#include <unordered_map>
#include <utility>
#include <vector>

// The opaque struct from the header, defined here with C++ members.
struct Palette {
    std::unordered_map<uint32_t, uint32_t> counts;
};

static uint32_t pack(uint8_t r, uint8_t g, uint8_t b) {
    return (uint32_t(r) << 16) | (uint32_t(g) << 8) | uint32_t(b);
}

extern "C" {

Palette *palette_create(void) {
    // nothrow new returns nullptr instead of throwing: the C caller can't catch anything.
    return new (std::nothrow) Palette();
}

void palette_destroy(Palette *p) {
    delete p;
}

int palette_add_pixels(Palette *p, const uint8_t *rgb, size_t pixel_count) {
    try {
        for (size_t i = 0; i < pixel_count; i++) {
            p->counts[pack(rgb[3 * i], rgb[3 * i + 1], rgb[3 * i + 2])]++;
        }
        return 0;
    } catch (const std::bad_alloc &) {
        // An exception crossing into Zig would be undefined behavior; it becomes a return code.
        return -1;
    }
}

size_t palette_distinct(const Palette *p) {
    return p->counts.size();
}

size_t palette_top(const Palette *p, PaletteEntry *out, size_t max_entries) {
    try {
        std::vector<std::pair<uint32_t, uint32_t>> entries(p->counts.begin(), p->counts.end());
        const size_t n = std::min(max_entries, entries.size());
        // Most frequent first; ties broken by color value so the order is deterministic.
        std::partial_sort(entries.begin(), entries.begin() + n, entries.end(),
                          [](const std::pair<uint32_t, uint32_t> &a, const std::pair<uint32_t, uint32_t> &b) {
                              return a.second != b.second ? a.second > b.second : a.first < b.first;
                          });
        for (size_t i = 0; i < n; i++) {
            out[i].r = uint8_t(entries[i].first >> 16);
            out[i].g = uint8_t(entries[i].first >> 8);
            out[i].b = uint8_t(entries[i].first);
            out[i].count = entries[i].second;
        }
        return n;
    } catch (const std::bad_alloc &) {
        return 0;
    }
}

} // extern "C"
