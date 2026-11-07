//! Image filters with a C interface. `export fn` gives a function the C calling convention and a
//! symbol with exactly its name, so any program that speaks the C ABI can call it: the C demo in
//! c/demo.c does, through c/filters.h and the static library the build makes of this file. The Zig
//! program calls the same functions directly, through the slice-based wrappers below.

const std = @import("std");
const builtin = @import("builtin");

/// Only C-ABI types may appear in an exported signature: pointers, integers, floats, extern
/// structs. Slices are not among them (C has no slice), so pointer and length travel separately.
export fn filters_grayscale(rgb: [*]u8, pixel_count: usize) void {
    for (0..pixel_count) |i| {
        const p = rgb[i * 3 ..][0..3];
        const y = luma(p);
        p.* = .{ y, y, y };
    }
}

export fn filters_invert(bytes: [*]u8, len: usize) void {
    for (bytes[0..len]) |*b| b.* = 255 - b.*;
}

/// Every output pixel is the mean of the (2r+1)x(2r+1) square around it, clamped at the edges.
export fn filters_box_blur(src: [*]const u8, dst: [*]u8, width: u32, height: u32, radius: u32) void {
    const r: i64 = radius;
    for (0..height) |y| {
        for (0..width) |x| {
            var sum: [3]u64 = .{ 0, 0, 0 };
            var n: u64 = 0;
            const y0 = @max(@as(i64, @intCast(y)) - r, 0);
            const y1 = @min(@as(i64, @intCast(y)) + r, @as(i64, height) - 1);
            const x0 = @max(@as(i64, @intCast(x)) - r, 0);
            const x1 = @min(@as(i64, @intCast(x)) + r, @as(i64, width) - 1);
            var sy = y0;
            while (sy <= y1) : (sy += 1) {
                var sx = x0;
                while (sx <= x1) : (sx += 1) {
                    const index = (@as(usize, @intCast(sy)) * width + @as(usize, @intCast(sx))) * 3;
                    for (&sum, src[index..][0..3]) |*s, v| s.* += v;
                    n += 1;
                }
            }
            const out = dst[(y * width + x) * 3 ..][0..3];
            for (out, sum) |*o, s| o.* = @intCast(s / n);
        }
    }
}

/// A 0-terminated string, as C expects. The pointer is to a comptime constant, so it stays valid.
export fn filters_version() [*:0]const u8 {
    return "imgfilters 0.9.0 (Zig " ++ builtin.zig_version_string ++ ")";
}

/// Rec. 601 luma, in integers: 0.299 R + 0.587 G + 0.114 B.
pub fn luma(rgb: *const [3]u8) u8 {
    const y = (299 * @as(u32, rgb[0]) + 587 * @as(u32, rgb[1]) + 114 * @as(u32, rgb[2])) / 1000;
    return @intCast(y);
}

// The Zig-side API: the same functions with slices. Exported functions are ordinary functions to
// Zig code in the same compilation; these just pack and unpack the slices.

pub fn grayscale(rgb: []u8) void {
    filters_grayscale(rgb.ptr, rgb.len / 3);
}

pub fn invert(bytes: []u8) void {
    filters_invert(bytes.ptr, bytes.len);
}

pub fn boxBlur(src: []const u8, dst: []u8, width: u32, height: u32, radius: u32) void {
    std.debug.assert(src.len == dst.len and src.len == @as(usize, width) * height * 3);
    filters_box_blur(src.ptr, dst.ptr, width, height, radius);
}

pub fn version() [:0]const u8 {
    return std.mem.span(filters_version());
}

// Tests

test "grayscale of the primaries" {
    var pixels = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255 };
    grayscale(&pixels);
    try std.testing.expectEqualSlices(u8, &.{ 76, 76, 76, 149, 149, 149, 29, 29, 29, 255, 255, 255 }, &pixels);
}

test "inverting twice is the identity" {
    var bytes = [_]u8{ 0, 1, 2, 100, 200, 255 };
    const original = bytes;
    invert(&bytes);
    try std.testing.expectEqual(255, bytes[0]);
    invert(&bytes);
    try std.testing.expectEqualSlices(u8, &original, &bytes);
}

test "blurring a flat image changes nothing; blurring a dot spreads it" {
    var flat: [4 * 4 * 3]u8 = @splat(42);
    var out: [4 * 4 * 3]u8 = undefined;
    boxBlur(&flat, &out, 4, 4, 1);
    try std.testing.expectEqualSlices(u8, &flat, &out);

    var dot: [3 * 3 * 3]u8 = @splat(0);
    dot[(1 * 3 + 1) * 3] = 90; // red, at the center
    boxBlur(&dot, &out[0 .. 3 * 3 * 3].*, 3, 3, 1);
    // Every pixel's 3x3 neighborhood contains the dot once; corners average over 4, edges 6, center 9.
    try std.testing.expectEqual(90 / 4, out[0]); // corner
    try std.testing.expectEqual(90 / 6, out[1 * 3]); // top edge
    try std.testing.expectEqual(90 / 9, out[(1 * 3 + 1) * 3]); // center
}

test "the version string names the compiler" {
    try std.testing.expect(std.mem.find(u8, version(), builtin.zig_version_string) != null);
}
