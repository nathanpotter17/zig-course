//! Lecture 9: C and C++ interop. A small image tool built from three languages:
//!
//!   zig build run -- generate <out.png>                       a test image (Zig, written by stb)
//!   zig build run -- process <in> <out.png> [--gray] [--invert] [--blur R]
//!                                                              load (C), count colors (C++),
//!                                                              filter (Zig), save (C)
//!   zig build run-c                                            a C program calling the Zig library

const std = @import("std");
const stb = @import("stb.zig");
const palette = @import("palette.zig");
const filters = @import("filters.zig");

const Image = stb.Image;

test {
    _ = stb;
    _ = palette;
    _ = filters;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    // Arguments are [:0]const u8: 0-terminated, exactly what the C functions need for paths.
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len >= 3 and std.mem.eql(u8, args[1], "generate")) {
        try generate(gpa, out, args[2]);
        return 0;
    }
    if (args.len >= 4 and std.mem.eql(u8, args[1], "process")) {
        return process(gpa, out, args[2], args[3], args[4..]);
    }
    std.debug.print(
        \\usage: lecture_9 generate <out.png>
        \\       lecture_9 process <in.png> <out.png> [--gray] [--invert] [--blur RADIUS]
        \\
    , .{});
    return 2;
}

/// A 256x192 test image: a dark background, three flat-colored discs, a white diagonal, and a
/// gradient strip along the bottom, so the palette has a few big colors and many small ones.
fn generate(gpa: std.mem.Allocator, out: *std.Io.Writer, path: [:0]const u8) !void {
    var image = try Image.init(gpa, 256, 192);
    defer image.deinit();

    const Disc = struct { cx: i32, cy: i32, r: i32, color: [3]u8 };
    const discs = [_]Disc{
        .{ .cx = 70, .cy = 80, .r = 45, .color = .{ 200, 50, 50 } },
        .{ .cx = 150, .cy = 70, .r = 38, .color = .{ 60, 180, 90 } },
        .{ .cx = 200, .cy = 120, .r = 30, .color = .{ 240, 200, 40 } },
    };
    for (0..image.height) |y| {
        for (0..image.width) |x| {
            const p = image.pixel(@intCast(x), @intCast(y));
            p.* = .{ 20, 30, 60 };
            if (y >= 176) {
                // Gradient strip: 256 different colors.
                p.* = .{ @intCast(x), @intCast(255 - x), 128 };
                continue;
            }
            if (@abs(@as(i32, @intCast(x)) - @as(i32, @intCast(y)) - 40) < 4) p.* = .{ 255, 255, 255 };
            for (discs) |d| {
                const dx = @as(i32, @intCast(x)) - d.cx;
                const dy = @as(i32, @intCast(y)) - d.cy;
                if (dx * dx + dy * dy <= d.r * d.r) p.* = d.color;
            }
        }
    }
    try image.writePng(path);
    try out.print("wrote {s}: {d}x{d}\n", .{ path, image.width, image.height });
}

fn process(gpa: std.mem.Allocator, out: *std.Io.Writer, in_path: [:0]const u8, out_path: [:0]const u8, options: []const [:0]const u8) !u8 {
    // C: decode the file.
    var image = Image.load(in_path) catch {
        std.debug.print("could not load {s}: {s}\n", .{ in_path, Image.failureReason() });
        return 1;
    };
    defer image.deinit();
    try out.print("{s}: {d}x{d}, {Bi:.1} of RGB\n", .{ in_path, image.width, image.height, image.pixels.len });

    // C++: count the colors.
    var colors = try palette.Palette.init();
    defer colors.deinit();
    try colors.addPixels(image.pixels);
    var buffer: [5]palette.Entry = undefined;
    try out.print("{d} distinct colors; the most common:\n", .{colors.distinct()});
    for (colors.top(&buffer)) |entry| {
        try out.print("    #{x:0>2}{x:0>2}{x:0>2}  {d:>6} pixels\n", .{ entry.r, entry.g, entry.b, entry.count });
    }

    // Zig: the filters, in the order given on the command line.
    var i: usize = 0;
    while (i < options.len) : (i += 1) {
        const option = options[i];
        if (std.mem.eql(u8, option, "--gray")) {
            filters.grayscale(image.pixels);
        } else if (std.mem.eql(u8, option, "--invert")) {
            filters.invert(image.pixels);
        } else if (std.mem.eql(u8, option, "--blur") and i + 1 < options.len) {
            i += 1;
            const radius = try std.fmt.parseInt(u32, options[i], 10);
            // The blur reads one buffer and writes another; a Zig-owned copy is the destination,
            // and then the two images swap roles.
            const blurred = try Image.init(gpa, image.width, image.height);
            filters.boxBlur(image.pixels, blurred.pixels, image.width, image.height, radius);
            image.deinit();
            image = blurred;
        } else {
            std.debug.print("unknown option: {s}\n", .{option});
            return 2;
        }
        try out.print("applied {s}\n", .{option});
    }

    // C: encode and write the result.
    image.writePng(out_path) catch {
        std.debug.print("could not write {s}\n", .{out_path});
        return 1;
    };
    try out.print("wrote {s} using {s}\n", .{ out_path, filters.version() });
    return 0;
}
