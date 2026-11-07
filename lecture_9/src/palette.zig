//! The C++ color counter, through the C interface in cpp/palette.h.
//! These declarations are written by hand instead of translated: that way they use Zig's own
//! pointer types (*CPalette, [*]const u8) and the wrapper needs no casts. Writing them by hand is
//! fine for a five-function API; for stb's hundred, translate-c does it.

const std = @import("std");

/// The C++ struct, as Zig sees it: opaque. We only ever hold pointers to it, and only the C++
/// side knows its size and contents.
const CPalette = opaque {};

/// Must match PaletteEntry in palette.h field for field. `extern struct` gives it C's layout rules,
/// so r, g, b sit at offsets 0, 1, 2 and count at 4 on both sides.
pub const Entry = extern struct {
    r: u8,
    g: u8,
    b: u8,
    count: u32,
};

comptime {
    std.debug.assert(@sizeOf(Entry) == 8);
}

// `extern fn`: the body is somewhere else, found by the linker under this exact name. The types are
// our translation of the C prototypes: Palette* that may be null -> ?*CPalette, one that may not ->
// *CPalette, const uint8_t* -> [*]const u8, size_t -> usize, int -> c_int.
extern fn palette_create() ?*CPalette;
extern fn palette_destroy(p: *CPalette) void;
extern fn palette_add_pixels(p: *CPalette, rgb: [*]const u8, pixel_count: usize) c_int;
extern fn palette_distinct(p: *const CPalette) usize;
extern fn palette_top(p: *const CPalette, out: [*]Entry, max_entries: usize) usize;

/// The Zig face of the C++ object: init/deinit, slices, error unions.
pub const Palette = struct {
    handle: *CPalette,

    pub fn init() error{OutOfMemory}!Palette {
        return .{ .handle = palette_create() orelse return error.OutOfMemory };
    }

    pub fn deinit(self: *Palette) void {
        palette_destroy(self.handle);
        self.* = undefined;
    }

    /// Counts RGB pixels: the slice is pixels * 3 bytes.
    pub fn addPixels(self: *Palette, rgb: []const u8) error{OutOfMemory}!void {
        std.debug.assert(rgb.len % 3 == 0);
        if (palette_add_pixels(self.handle, rgb.ptr, rgb.len / 3) != 0) return error.OutOfMemory;
    }

    pub fn distinct(self: Palette) usize {
        return palette_distinct(self.handle);
    }

    /// The most frequent colors, into the caller's buffer; returns the part that was filled.
    pub fn top(self: Palette, out: []Entry) []Entry {
        return out[0..palette_top(self.handle, out.ptr, out.len)];
    }
};

// Tests

test "counting colors" {
    var palette = try Palette.init();
    defer palette.deinit();

    const red = [_]u8{ 255, 0, 0 };
    const blue = [_]u8{ 0, 0, 255 };
    try palette.addPixels(&(red ++ blue ++ red ++ red ++ blue));
    try palette.addPixels(&(blue ++ blue ++ blue));
    try std.testing.expectEqual(2, palette.distinct());

    var buffer: [8]Entry = undefined;
    const entries = palette.top(&buffer);
    try std.testing.expectEqual(2, entries.len);
    try std.testing.expectEqual(Entry{ .r = 0, .g = 0, .b = 255, .count = 5 }, entries[0]);
    try std.testing.expectEqual(Entry{ .r = 255, .g = 0, .b = 0, .count = 3 }, entries[1]);

    // A smaller buffer gets the top of the list only.
    try std.testing.expectEqual(1, palette.top(buffer[0..1]).len);
}

test "an empty palette" {
    var palette = try Palette.init();
    defer palette.deinit();
    var buffer: [2]Entry = undefined;
    try std.testing.expectEqual(0, palette.distinct());
    try std.testing.expectEqual(0, palette.top(&buffer).len);
}
