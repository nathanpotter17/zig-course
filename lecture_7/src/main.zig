//! A small statistics command, assembled from three imports the build script provides:
//! the mathlib package, the build options, and a source file generated while building.

const std = @import("std");
const builtin = @import("builtin");
const mathlib = @import("mathlib");
const build_options = @import("build_options");
const crc_table = @import("crc_table");

/// CRC-32 over bytes, with the generated table. The test below checks it against the standard library.
pub fn crc32(bytes: []const u8) u32 {
    var crc: u32 = 0xffff_ffff;
    for (bytes) |b| {
        crc = crc_table.table[@as(u8, @truncate(crc ^ b))] ^ (crc >> 8);
    }
    return ~crc;
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    // Every argument is a number; anything else is a usage error with exit status 2.
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("usage: lecture_7 <number> [number...]\n", .{});
        return 2;
    }
    const values = try arena.alloc(f64, args.len - 1);
    for (args[1..], values) |arg, *value| {
        value.* = std.fmt.parseFloat(f64, arg) catch {
            std.debug.print("not a number: {s}\n", .{arg});
            return 2;
        };
    }

    // The library does the work; `precision` came from the command line of `zig build`, not of this
    // program. It's a comptime constant, so the format string is assembled at compile time: "{d:.3}".
    const summary = try mathlib.stats.summarize(init.gpa, values);
    const number = std.fmt.comptimePrint("{{d:.{d}}}", .{build_options.precision});
    try out.print("count   {d}\n", .{summary.count});
    try out.print("min     " ++ number ++ "\nmax     " ++ number ++ "\n", .{ summary.min, summary.max });
    try out.print("mean    " ++ number ++ "\nmedian  " ++ number ++ "\nstddev  " ++ number ++ "\n", .{ summary.mean, summary.median, summary.stddev });

    // Which inputs are prime integers.
    try out.writeAll("primes ");
    for (values) |v| {
        if (v >= 0 and v == @trunc(v) and v < 1e15 and mathlib.primes.isPrime(@intFromFloat(v))) try out.print(" {d}", .{@as(u64, @intFromFloat(v))});
    }
    try out.writeAll("\n");

    // -Dverbose: what the build baked in. `builtin` describes this compilation; the options module
    // carries what the build script chose.
    if (build_options.verbose) {
        const joined = try std.mem.join(arena, " ", args[1..]);
        try out.print("\nlecture_7 {s}, mathlib {f}, built with Zig {s} in {t} mode for {t}-{t}-{t}; crc32 of the input {x:0>8}\n", .{
            build_options.version,
            mathlib.version,
            builtin.zig_version_string,
            builtin.mode,
            builtin.target.cpu.arch,
            builtin.target.os.tag,
            builtin.target.abi,
            crc32(joined),
        });
    }
    return 0;
}

// Tests

test "the generated table and the CRC agree with the standard library" {
    try std.testing.expectEqual(0x77073096, crc_table.table[1]);
    try std.testing.expectEqual(0x2d02ef8d, crc_table.table[255]);
    try std.testing.expectEqual(std.hash.Crc32.hash("hello, world"), crc32("hello, world"));
    try std.testing.expectEqual(0, crc32(""));
}

test "build options are compile-time constants" {
    // The option is a comptime value: this comparison is resolved while compiling.
    comptime std.debug.assert(build_options.precision <= 20);
    try std.testing.expect(mathlib.version.major == 0);
}
