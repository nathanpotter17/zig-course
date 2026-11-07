# Lecture 9: C and C++ interop

Zig was designed to live alongside C. It compiles C and C++ (the compiler bundles clang), translates C headers into Zig declarations, speaks the C ABI natively in both directions, and ships libc and libc++ for every target it supports. This lecture uses all of that in one small program, an image tool assembled from three languages:

- **C into Zig:** `stb_image` and `stb_image_write`, two well-known single-header C libraries, vendored into the repository, translated by the build system's `translate-c` step into a module, and wrapped in a Zig type with slices, error unions and clear ownership.
- **C++ into Zig:** a color counter written in C++ (`std::unordered_map`, `std::partial_sort`) behind an `extern "C"` interface, compiled with libc++, with the Zig side declaring the functions by hand.
- **Zig into C:** image filters written in Zig with `export fn`, built as a static library with a hand-written header, and called from a C program that the build also compiles. `zig cc` does the same from the command line.
- **The mechanics:** `[*c]T` pointers and what to do with them, `c_int` and friends, `?*anyopaque` for `void*`, `[:0]const u8` for C strings and `std.mem.span` back, `callconv(.c)` callbacks, `extern struct` layout, opaque types, and the rule that errors and exceptions never cross the boundary.

The files:
```text
lecture_9/
  build.zig, build.zig.zon       translate, compile C and C++, build a library, link a C program
  vendor/stb/                    stb_image.h, stb_image_write.h (public domain, unmodified)
  c/stb.h                        the header translate-c reads
  c/stb_impl.c                   the one C file that holds the stb implementations
  c/filters.h                    the C header for the Zig library
  c/demo.c                       a C program using the Zig library
  cpp/palette.h, palette.cpp     the C++ color counter and its C interface
  src/stb.zig                    Image: the Zig wrapper around stb
  src/palette.zig                Palette: the Zig wrapper around the C++ counter
  src/filters.zig                the filters, exported with the C ABI
  src/main.zig                   the program
  assets/sample.png              a test image the program generated
```

## 9.1 The build script

### Why
Everything in this lecture is set up by `build.zig`: which header to translate, which C and C++ files to compile with which flags, which libraries to link, and how to turn Zig into a library a C program can use. The source files are then ordinary; `@import("stb")` is just a module like `mathlib` was in lecture 7.

### How
- **`b.addTranslateC(.{ .root_source_file, .target, .optimize })`** is a build step that runs the translator on one header and produces a Zig file. `addIncludePath` tells it where `#include "stb_image.h"` finds its file. **`createModule()`** wraps the output as a module, with libc linked (`link_libc` defaults to true, since translated headers refer to libc types).
- **`addCSourceFile(.{ .file, .flags })`** adds a C or C++ file to a module; the language is chosen by extension (`.c`, `.cpp`), and the flags go to clang. Each file is compiled by the Zig compiler's bundled clang for the module's target, so cross-compiling the whole thing still works. **`.link_libc = true`** and **`.link_libcpp = true`** on `createModule` link Zig's own libc (musl or glibc, by target) and libc++.
- **`b.addLibrary(.{ .linkage = .static, .name, .root_module })`** builds `libimgfilters.a` from `filters.zig`. **`installHeader(path, "filters.h")`** installs the header beside it, under `zig-out/include`. A C program module then takes **`addIncludePath`** for the header and **`linkLibrary(filters)`** for the archive. Zig doesn't generate C headers from Zig source in 0.17 (that feature is being redone), so the header is written by hand.
- **`b.addInstallFile(stb_translate.getOutput(), "stb.zig")`** copies the translated file into `zig-out` for reading. It's the quickest way to see what translate-c made of a header.
- **End-to-end checks** reuse lecture 7's tools. `generate.addOutputFileArg("sample.png")` hands the program a path in the cache and returns it as a `LazyPath`, which `process.addFileArg(sample)` passes to the next run: a pipeline between runs of the same program. **`addCheck(.{ .expect_stdout_match = "..." })`** is the looser cousin of `expectStdOutEqual`: the output must *contain* the text.

### Code
`lecture_9/build.zig`:
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. C into Zig: translate the stb headers into a Zig module. Only the declarations are
    //    translated (functions, types, constants); the function bodies are compiled from
    //    c/stb_impl.c below, as C, and linked in like any other object.
    const stb_translate = b.addTranslateC(.{
        .root_source_file = b.path("c/stb.h"),
        .target = target,
        .optimize = optimize,
    });
    stb_translate.addIncludePath(b.path("vendor/stb"));
    const stb_module = stb_translate.createModule();

    // 2. Zig as a C library: the `export fn`s in filters.zig become a static library with a
    //    hand-written header, for C programs (and anything else that speaks the C ABI).
    const filters = b.addLibrary(.{
        .name = "imgfilters",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/filters.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    filters.installHeader(b.path("c/filters.h"), "filters.h");
    b.installArtifact(filters);

    // 3. The program: Zig, plus the translated C declarations, plus a C file and a C++ file
    //    compiled by the Zig compiler's bundled clang and linked with libc and libc++.
    const exe = b.addExecutable(.{
        .name = "lecture_9",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // stb uses stdio and malloc
            .link_libcpp = true, // palette.cpp uses the C++ standard library
            .imports = &.{
                .{ .name = "stb", .module = stb_module },
            },
        }),
    });
    exe.root_module.addIncludePath(b.path("vendor/stb"));
    exe.root_module.addIncludePath(b.path("cpp"));
    // The flags go to clang. (Zig compiles C with the undefined-behavior sanitizer trapping in debug
    // and safe builds; a C library that crashes with "illegal instruction" there is UB being caught,
    // and -fno-sanitize=undefined here is the escape hatch. stb needs no such thing.)
    exe.root_module.addCSourceFile(.{ .file = b.path("c/stb_impl.c"), .flags = &.{"-std=c99"} });
    exe.root_module.addCSourceFile(.{ .file = b.path("cpp/palette.cpp"), .flags = &.{"-std=c++17"} });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run the program; pass a command after --").dependOn(&run.step);

    // 4. The other direction: a C program that links the Zig library.
    const demo_c = b.addExecutable(.{
        .name = "demo_c",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    demo_c.root_module.addCSourceFile(.{ .file = b.path("c/demo.c"), .flags = &.{"-std=c99"} });
    demo_c.root_module.addIncludePath(b.path("c"));
    demo_c.root_module.linkLibrary(filters);
    b.installArtifact(demo_c);
    const run_c = b.addRunArtifact(demo_c);
    b.step("run-c", "Run the C program that uses the Zig library").dependOn(&run_c.step);

    // 5. `zig build translate`: a copy of what translate-c produced, to read.
    const translated = b.addInstallFile(stb_translate.getOutput(), "stb.zig");
    b.step("translate", "Write the translated stb header to zig-out/stb.zig").dependOn(&translated.step);

    // 6. Tests: the unit tests, then an end-to-end run: generate an image, process it, and run
    //    the C demo, checking the outputs.
    const test_step = b.step("test", "Run the unit tests and the end-to-end checks");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module })).step);

    const generate = b.addRunArtifact(exe);
    generate.addArg("generate");
    const sample = generate.addOutputFileArg("sample.png");
    generate.addCheck(.{ .expect_stdout_match = "256x192" });

    const process = b.addRunArtifact(exe);
    process.addArg("process");
    process.addFileArg(sample);
    _ = process.addOutputFileArg("gray.png");
    process.addArgs(&.{ "--blur", "1", "--gray" });
    process.addCheck(.{ .expect_stdout_match = "distinct colors" });
    process.addCheck(.{ .expect_stdout_match = "#c83232" });
    test_step.dependOn(&process.step);

    const demo_check = b.addRunArtifact(demo_c);
    demo_check.addCheck(.{ .expect_stdout_match = "grayscale: 76 149 29 255" });
    test_step.dependOn(&demo_check.step);
}
```
`lecture_9/build.zig.zon`:
```zig
.{
    .name = .lecture_9,
    .version = "0.9.0",
    .fingerprint = 0x3286169e58fee138, // Changing this has security and trust implications.
    .minimum_zig_version = "0.17.1",
    // The C library is vendored (copied into the repository) rather than fetched: two files,
    // public domain, and the build never needs the network.
    .paths = .{ "build.zig", "build.zig.zon", "src", "c", "cpp", "vendor" },
}
```

## 9.2 Translating a C header

### Why
A C library is a header (declarations) and compiled code. To call it from Zig you need the declarations in Zig form, and `translate-c` produces them mechanically: every function becomes `pub extern fn`, every typedef a `pub const`, every `#define` of a constant a `pub const`, every struct an `extern struct`. The compiled code comes from compiling the library's C files like any other. For a single-header library like stb, the "C file" is one you write: it defines the implementation macro and includes the header.

### How
- **`@cImport` is gone.** Earlier Zig versions translated headers inside a source file with `@cImport(@cInclude("..."))`. In 0.17 translation is a build step and the result is a module; the source file does `@import("stb")`. The same translation serves every file that imports it, and it's visible in `zig-out` with `zig build translate`.
- **What the translation looks like.** Pointers become `[*c]T`, *C pointers*, which may be null, may point to one item or many, and coerce to Zig's pointer types. `int` becomes `c_int`, `void*` becomes `?*anyopaque`, `unsigned char*` becomes `[*c]u8`. A function-pointer typedef becomes a `fn (...) callconv(.c)` type. From `zig-out/stb.zig`:
  ```zig
  pub const STBI_rgb: c_int = 3;
  pub const stbi_uc = u8;
  pub extern fn stbi_load(filename: [*c]const u8, x: [*c]c_int, y: [*c]c_int, channels_in_file: [*c]c_int, desired_channels: c_int) [*c]stbi_uc;
  pub extern fn stbi_image_free(retval_from_stbi_load: ?*anyopaque) void;
  pub extern fn stbi_write_png(filename: [*c]const u8, w: c_int, h: c_int, comp: c_int, data: ?*const anyopaque, stride_in_bytes: c_int) c_int;
  pub const stbi_write_func = fn (context: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void;
  pub extern fn stbi_write_png_to_func(func: ?*const stbi_write_func, context: ?*anyopaque, w: c_int, h: c_int, comp: c_int, data: ?*const anyopaque, stride_in_bytes: c_int) c_int;
  ```
  Eighteen hundred lines from two headers; most of it the libc declarations they include.
- **What can't be translated** (macros that are code, bit fields, `goto`) is *demoted*: a struct becomes `opaque {}`, a function stays `extern`, a macro becomes a `@compileError` you only hit if you use it. The library is still usable; you just can't touch those parts from Zig.
- **The single-header pattern.** `stb_image.h` is declarations only until a file defines `STB_IMAGE_IMPLEMENTATION` before including it; then it's the whole library. Exactly one C file must do that, or the functions are defined twice. `c/stb_impl.c` is that file. The header translate-c reads, `c/stb.h`, includes both headers without the macros: declarations only.

### Code
`c/stb.h`:
```c
/* The header translate-c reads: the declarations of both stb libraries, and nothing else.
   Their implementations are compiled once, from stb_impl.c. */
#include "stb_image.h"
#include "stb_image_write.h"
```
`c/stb_impl.c`:
```c
/* The single-header pattern: a header is only declarations until one translation unit defines
   the *_IMPLEMENTATION macro before including it; then it's the whole library. This file is that
   translation unit. The build compiles it as C and links the result into the program. */
#define STB_IMAGE_IMPLEMENTATION
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image.h"
#include "stb_image_write.h"
```

## 9.3 Wrapping C in Zig: the Image type

### Why
Translated declarations are usable as they are, but they carry C's weaknesses: pointers that may be null, lengths passed separately, failure signaled by a null or a zero, and memory whose owner is a convention in the documentation. A wrapper puts the Zig types back: a slice with its length, an error union instead of a null check, and a `deinit` that knows who allocated the pixels. The rest of the program then never sees a C pointer. The wrapper is where the C conventions are *encoded once*, which is the point of writing one.

### How
- **Ownership is a union.** `stbi_load` returns memory from C's `malloc`, which must go back through `stbi_image_free`; an image the Zig side creates belongs to a Zig allocator. `Owner = union(enum) { stb, zig: Allocator }` records which, and `deinit` switches on it. The alternative, copying every loaded image into Zig memory, costs a copy to avoid a two-line union.
- **`[*c]u8` to `?[*]u8`.** A C pointer coerces to an optional many-item pointer, which `orelse` understands: `const data: ?[*]u8 = c.stbi_load(...); data orelse return error.DecodeFailed`. From the many-item pointer, a slice: `data[0..len]`, with the length computed from the dimensions stb reported through its out-parameters (`&width`, where `width: c_int`).
- **C strings in.** C expects a 0 byte at the end of a string. `[:0]const u8` is a slice that guarantees one; `.ptr` on it is `[*:0]const u8`, which coerces to `[*c]const u8`. Command-line arguments come as `[:0]const u8` already, so paths need no copying.
- **C strings out.** `stbi_failure_reason()` returns `[*c]const u8`; giving it the type `?[*:0]const u8` and calling `std.mem.span` finds the 0 and makes a slice.
- **`c_int` conversions.** Dimensions are `u32` in the wrapper and `c_int` in C; `@intCast` both ways, which panics in debug if a value doesn't fit instead of silently truncating.
- **`?*anyopaque`** is C's `void*`. Any pointer coerces *to* it (`self.pixels.ptr` passed to `stbi_image_free`); coming *from* it needs `@ptrCast` (and `@alignCast` if the target type is aligned), as the callback in the next section does.

### Code
`src/stb.zig`, part 1 of 2:
```zig
//! Image loading and saving through stb_image and stb_image_write, two single-header C libraries.
//! The build script translated their header into the module @import("stb"); this file wraps the
//! C functions in a Zig type with slices, errors and clear ownership, so the rest of the program
//! never sees a C pointer.

const std = @import("std");
const Allocator = std.mem.Allocator;
/// The translated header: every stb function, type and constant, with C types ([*c]u8, c_int).
const c = @import("stb");

pub const Image = struct {
    width: u32,
    height: u32,
    /// RGB, three bytes per pixel, rows from the top. Who frees it depends on `owner`.
    pixels: []u8,
    owner: Owner,

    /// Memory from stb must go back to stb (it used C's malloc); memory from a Zig allocator goes
    /// back to that allocator. The union remembers which, so deinit always does the right thing.
    pub const Owner = union(enum) {
        stb,
        zig: Allocator,
    };

    pub const channels = 3;

    pub const LoadError = error{DecodeFailed};
    pub const EncodeError = error{EncodeFailed} || Allocator.Error;

    /// A black image owned by the allocator.
    pub fn init(gpa: Allocator, width: u32, height: u32) Allocator.Error!Image {
        const pixels = try gpa.alloc(u8, @as(usize, width) * height * channels);
        @memset(pixels, 0);
        return .{ .width = width, .height = height, .pixels = pixels, .owner = .{ .zig = gpa } };
    }

    pub fn deinit(self: *Image) void {
        switch (self.owner) {
            // Accepts ?*anyopaque, C's void*; a [*]u8 coerces to it.
            .stb => c.stbi_image_free(self.pixels.ptr),
            .zig => |gpa| gpa.free(self.pixels),
        }
        self.* = undefined;
    }

    /// Decodes a PNG, JPEG, BMP, GIF, ... file. The path must be 0-terminated: C strings end at a 0
    /// byte, and a [:0]const u8 guarantees one is there. Always 3 channels, whatever the file has.
    pub fn load(path: [:0]const u8) LoadError!Image {
        var width: c_int = undefined;
        var height: c_int = undefined;
        var file_channels: c_int = undefined;
        // stbi_load returns a C pointer, [*c]u8: null on failure. Giving it an optional many-item
        // pointer type turns null into a proper Zig null, and `orelse` handles it.
        const data: ?[*]u8 = c.stbi_load(path.ptr, &width, &height, &file_channels, channels);
        return fromStb(data orelse return error.DecodeFailed, width, height);
    }

    /// The same from bytes already in memory.
    pub fn loadFromMemory(bytes: []const u8) LoadError!Image {
        var width: c_int = undefined;
        var height: c_int = undefined;
        var file_channels: c_int = undefined;
        const data: ?[*]u8 = c.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &width, &height, &file_channels, channels);
        return fromStb(data orelse return error.DecodeFailed, width, height);
    }

    fn fromStb(data: [*]u8, width: c_int, height: c_int) Image {
        const w: u32 = @intCast(width);
        const h: u32 = @intCast(height);
        // A many-item pointer becomes a slice once we know the length; stb told us the dimensions.
        return .{ .width = w, .height = h, .pixels = data[0 .. @as(usize, w) * h * channels], .owner = .stb };
    }

    /// Why the last load failed, as stb describes it. The C string becomes a slice with span.
    pub fn failureReason() []const u8 {
        const reason: ?[*:0]const u8 = c.stbi_failure_reason();
        return std.mem.span(reason orelse return "unknown");
    }

    pub fn writePng(self: Image, path: [:0]const u8) EncodeError!void {
        const stride: c_int = @intCast(self.width * channels);
        if (c.stbi_write_png(path.ptr, @intCast(self.width), @intCast(self.height), channels, self.pixels.ptr, stride) == 0) {
            return error.EncodeFailed;
        }
    }
```

## 9.4 A C callback into Zig

### Why
Libraries often call *you*: a comparison function for `qsort`, a handler for each parsed element, a writer for each chunk of output. `stbi_write_png_to_func` is the last kind: instead of writing a file, it calls a function of yours with each piece of the PNG. The function is Zig, but it's called from C, so it must look exactly like the C function pointer type: same parameters, same calling convention. And it must not let anything escape: no error return (C has none), no panic that unwinds through C frames.

### How
- **`callconv(.c)`** on a function gives it the C calling convention, so C code can call it. Its parameters mirror the C typedef: `?*anyopaque, ?*anyopaque, c_int`. A pointer to it (`writeChunk`, the function name, coerces to `?*const stbi_write_func`) is what C receives.
- **The context pointer** is C's way of giving a callback state: you pass any pointer as `context`, C passes it back untouched. Inside, `@ptrCast(@alignCast(context.?))` turns the `void*` back into `*WriteContext`. The `.?` asserts it isn't null; `@alignCast` asserts the address is aligned for the struct (checked in debug); `@ptrCast` changes the pointee type.
- **Errors stay inside.** `appendSlice` can fail, but the callback returns `void`. It records the failure in the context, and `encodePng` checks the flag after stb returns. The same shape serves any callback: collect, don't throw.
- **The result is Zig-owned:** `toOwnedSlice` gives the caller a `[]u8` to free with the same allocator, and the `errdefer` frees the partial buffer if encoding fails.

### Code
`src/stb.zig`, part 2 of 2:
```zig
    /// PNG bytes in memory. stb produces the file in chunks and calls a function of ours for each:
    /// a C callback into Zig. The context pointer is how C hands our own state back to us.
    pub fn encodePng(self: Image, gpa: Allocator) EncodeError![]u8 {
        var context = WriteContext{ .gpa = gpa, .out = .empty, .failed = false };
        errdefer context.out.deinit(gpa);
        const stride: c_int = @intCast(self.width * channels);
        const ok = c.stbi_write_png_to_func(writeChunk, &context, @intCast(self.width), @intCast(self.height), channels, self.pixels.ptr, stride);
        if (ok == 0 or context.failed) return error.EncodeFailed;
        return context.out.toOwnedSlice(gpa);
    }

    const WriteContext = struct {
        gpa: Allocator,
        out: std.ArrayList(u8),
        failed: bool,
    };

    /// Must match stb's `stbi_write_func`: void (*)(void *context, void *data, int size), hence the
    /// C calling convention and the C-shaped parameters. Nothing may escape a callback into C, so
    /// an allocation failure is recorded in the context and reported after stb returns.
    fn writeChunk(context: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void {
        // Back from void* to our type: ptrCast changes the pointee, alignCast restores the alignment.
        const self: *WriteContext = @ptrCast(@alignCast(context.?));
        const bytes: [*]const u8 = @ptrCast(data.?);
        self.out.appendSlice(self.gpa, bytes[0..@intCast(size)]) catch {
            self.failed = true;
        };
    }

    pub fn pixel(self: Image, x: u32, y: u32) *[channels]u8 {
        const index = (@as(usize, y) * self.width + x) * channels;
        return self.pixels[index..][0..channels];
    }
};

// Tests

test "round trip through PNG in memory" {
    const gpa = std.testing.allocator;
    var original = try Image.init(gpa, 4, 3);
    defer original.deinit();
    for (0..3) |y| {
        for (0..4) |x| {
            original.pixel(@intCast(x), @intCast(y)).* = .{ @intCast(x * 60), @intCast(y * 100), 7 };
        }
    }

    const png = try original.encodePng(gpa);
    defer gpa.free(png);
    try std.testing.expect(std.mem.startsWith(u8, png, "\x89PNG\r\n\x1a\n"));

    var decoded = try Image.loadFromMemory(png);
    defer decoded.deinit();
    try std.testing.expectEqual(4, decoded.width);
    try std.testing.expectEqual(3, decoded.height);
    try std.testing.expectEqualSlices(u8, original.pixels, decoded.pixels);
    try std.testing.expect(decoded.owner == .stb);
}

test "garbage is a decode error with a reason" {
    try std.testing.expectError(error.DecodeFailed, Image.loadFromMemory("definitely not an image"));
    try std.testing.expect(Image.failureReason().len > 0);
}

test "the translated constants and types are usable directly" {
    // What translate-c made of `#define STBI_rgb 3` and `typedef unsigned char stbi_uc;`.
    try std.testing.expectEqual(3, c.STBI_rgb);
    try std.testing.expectEqual(u8, c.stbi_uc);
}
```
The round-trip test exercises the whole chain: Zig pixels, encoded by C through the Zig callback, decoded by C into C-owned memory, compared and freed by the right owner. The testing allocator confirms nothing on the Zig side leaked; C's side is stb's responsibility.

## 9.5 C++ behind a C interface

### Why
Zig can compile C++ and link libc++, but it cannot call C++ directly: C++ has no stable ABI. Names are mangled differently by different compilers, class layout and virtual tables are compiler-specific, templates exist only at compile time, and exceptions unwind through frames in a way Zig knows nothing about. The universal solution, used by every language that talks to C++, is a C interface: the C++ code exposes `extern "C"` functions that take and return C types, and keeps its classes behind an opaque pointer. Zig then talks C, which it does natively.

### How
- **`extern "C"`** turns off name mangling, so `palette_create` is the symbol's name, and makes the function callable with the C calling convention. The header wraps the block in `#ifdef __cplusplus` so the same header works for C, C++ and (by hand or through translate-c) Zig.
- **An opaque type:** `typedef struct Palette Palette;` declares the type without its contents. C and Zig can hold a `Palette*` but can't look inside; `palette.cpp` defines the struct with C++ members. Object lifetime becomes a create/destroy pair, which the Zig side maps to `init`/`deinit`.
- **Plain data crosses:** `PaletteEntry` is a C struct with no methods, so it has the same layout for everyone.
- **Exceptions don't cross.** Every function that can throw catches inside and returns a code: `palette_create` uses `new (std::nothrow)`, which returns null instead of throwing; `palette_add_pixels` returns `-1` for `std::bad_alloc`. An exception propagating into Zig would be undefined behavior.
- **Determinism** is worth a line: `partial_sort` with ties broken by color value, so the top-5 list is the same on every run and the end-to-end test can check it.

### Code
`cpp/palette.h`:
```c
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
```
`cpp/palette.cpp`:
```cpp
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
```

## 9.6 Hand-written extern declarations

### Why
translate-c is one way to get declarations; writing them yourself is the other, and for a five-function API it's better. You choose the Zig types: `*CPalette` where the C side says the pointer is never null, `?*CPalette` where it can be, `[*]const u8` for a pointer to many bytes, `usize` for `size_t`. The result needs no casts at the call sites, and the compiler enforces what the C header could only say in comments. The cost is that nothing checks your declarations against the header; a mismatch is a bug the linker can't see. Keep them side by side and keep them small.

### How
- **`extern fn name(...) T;`** declares a function defined elsewhere, found by the linker under exactly that name. No body, no `pub` needed unless other files call it directly.
- **`opaque {}`** is Zig's opaque type: no size, no fields, only pointers to it. It mirrors `typedef struct Palette Palette;` exactly.
- **`extern struct`** has C's layout rules (fields in order, C padding and alignment), so `Entry` matches `PaletteEntry` byte for byte. A plain Zig `struct` may reorder fields and must never cross the boundary. The `comptime` assertion on `@sizeOf` is cheap insurance: if someone adds a field on one side only, the size changes and the build fails.
- **The wrapper** is the same shape as `Image`: a handle, `init`/`deinit`, slices in, error unions out. `top` returns the filled prefix of the caller's buffer rather than allocating: the C function wrote `n` entries, so `out[0..n]` is the result.

### Code
`src/palette.zig`:
```zig
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
```
`red ++ blue ++ red` concatenates arrays at compile time (the `++` from lecture 3); `&(...)` takes the address of the resulting array, which coerces to the slice `addPixels` wants.

## 9.7 Zig as a C library

### Why
The other direction: code written in Zig, used from C, or from anything that can call C (Python's ctypes, Rust, a game engine's plugin API). The `export` keyword puts a function in the object file under its own name with the C calling convention. Build the file as a library, write a header, and the function is a C function to every caller. Nothing about the Zig side changes: the same `filters.zig` is imported by `main.zig` and called like any Zig code.

### How
- **`export fn`** = `pub`-to-the-world, C calling convention, unmangled symbol. The parameters and return type must be C-ABI types: integers, floats, pointers, `extern struct`s, `[*:0]const u8`. **Slices are not C types** (C has no pointer-plus-length), so `filters_grayscale` takes `[*]u8` and a count; the Zig-side wrappers (`grayscale(rgb: []u8)`) unpack a slice into the two and are what Zig callers use.
- **The header is written by hand** (`c/filters.h`), prototype by prototype: `uint8_t*` for `[*]u8`, `size_t` for `usize`, `uint32_t` for `u32`, `const char*` for `[*:0]const u8`. The build installs it next to the library under `zig-out/include`.
- **A string constant out:** `"imgfilters ..." ++ builtin.zig_version_string` is built at compile time and lives in the binary's read-only data, so returning a pointer to it is safe forever. `std.mem.span` on the Zig side turns it back into a slice for the version test.
- **Safety stays on.** The exported functions are compiled with Zig's safety checks in debug (`@intCast`, bounds checks on `src[index..][0..3]`), so a C caller passing a wrong length gets a Zig panic with a stack trace in a debug build instead of silent corruption. In a release build the checks are gone and the behavior is C's.

### Code
`src/filters.zig`:
```zig
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
```
`@splat(42)` fills an array with one value; the `**` array-repeat operator of older Zig is gone in 0.17. `&out[0 .. 3 * 3 * 3].*` takes the first 27 bytes of the larger buffer as an array of exactly that length.

`c/filters.h`:
```c
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
```

## 9.8 The C program, and `zig cc`

### Why
The proof that the library is a C library is a C program using it, with no Zig in sight: it includes the header, calls the functions, and links the archive. The build script compiles it (section 9.1, step 4), and the same can be done by hand with `zig cc`, Zig's drop-in C compiler, which is clang with Zig's cross-compilation and bundled libc behind it. Projects that keep their own Makefiles use `CC="zig cc"` and get cross-compilation for free.

### How
- **`zig build run-c`** builds `demo_c` and runs it. The expected numbers are the luma values from the filters test: 76, 149, 29, 255.
- **By hand:** after `zig build` has installed the library and header,
  ```bash
  zig cc -std=c99 c/demo.c -Izig-out/include zig-out/lib/libimgfilters.a -o demo
  ```
  is an ordinary C compile-and-link, and `zig cc -target aarch64-linux-musl ...` would do the same for another machine (with the library built for that target first).

### Code
`c/demo.c`:
```c
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
```

## 9.9 The program

### Why
`main.zig` ties the three languages into one pipeline: decode with C, count with C++, filter with Zig, encode with C. It also has a `generate` command, so the lecture ships with a test image it made itself (`assets/sample.png`): a dark background, three flat discs, a white diagonal and a 256-color gradient strip, chosen so the palette has a few large entries and many small ones.

### How
- **Arguments are `[:0]const u8`** from `toSlice`, so file paths go straight to `stbi_load` and `stbi_write_png` without copying.
- **The blur needs two buffers** (it reads neighbors while writing). The destination is a Zig-owned `Image`; after the blur the old image is freed (through whichever owner it had) and the new one takes its place. Any further filter runs on the Zig-owned copy. `deinit` on either kind is the same call: the union did its job.
- **`{Bi:.1}`** formats a byte count as `144.0KiB`; `{x:0>2}` prints a color channel as two hex digits.
- **Exit codes:** 1 for a file stb can't read (with stb's reason on stderr), 2 for usage errors, through the `!u8` return.

### Code
`src/main.zig`:
```zig
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
```

## 9.10 Running it

### How
From `lecture_9/`. The first build compiles stb (a quarter of a million lines of C) and the C++ file; later builds are cached.
```bash
zig build run -- generate assets/sample.png
```
```text
wrote assets/sample.png: 256x192
```
```bash
zig build run -- process assets/sample.png gray.png --blur 1 --gray
```
```text
assets/sample.png: 256x192, 144.0KiB of RGB
261 distinct colors; the most common:
    #141e3c   30747 pixels
    #c83232    6335 pixels
    #3cb45a    4513 pixels
    #f0c828    2821 pixels
    #ffffff     640 pixels
applied --blur
applied --gray
wrote gray.png using imgfilters 0.9.0 (Zig 0.17.1)
```
The five colors are the background, the three discs and the diagonal, in that order; the other 256 are the gradient strip. `gray.png` is the same picture in gray with soft edges; `--invert` instead gives a cream background with cyan, magenta and blue discs. A file that isn't an image:
```bash
zig build run -- process build.zig x.png
```
```text
could not load build.zig: unknown image type
```
with exit status 1 (stb's `stbi_failure_reason` provided the message). The C program:
```bash
zig build run-c
```
```text
imgfilters 0.9.0 (Zig 0.17.1)
grayscale: 76 149 29 255
inverted:  179 106 226 0
```
and the same by hand, after `zig build`:
```bash
zig cc -std=c99 c/demo.c -Izig-out/include zig-out/lib/libimgfilters.a -o demo
```
`zig build translate` writes `zig-out/stb.zig`, 1823 lines; search it for `stbi_load` to see section 9.2's declarations. `zig-out` after a build holds `bin/lecture_9`, `bin/demo_c`, `lib/libimgfilters.a` and `include/filters.h`: a complete C library distribution.

The tests:
```bash
zig build test --summary all
```
```text
Build Summary: 11/11 steps succeeded; 10/10 tests passed
test success
+- run test 10 pass (10 total) 9ms MaxRSS:7M
|  +- compile test debug native success 601ms MaxRSS:172M
|     +- translate-c cached 7ms MaxRSS:37M
+- run exe lecture_9 (gray.png) success 24ms
|  +- compile exe lecture_9 debug native cached 7ms MaxRSS:41M
|  |  +- translate-c (reused)
|  +- run exe lecture_9 (sample.png) success 16ms
|     +- compile exe lecture_9 debug native (+1 more reused dependencies)
+- run exe demo_c success 907us
   +- compile exe demo_c debug native cached 7ms MaxRSS:40M
      +- WriteFile filters.h cached
      +- compile lib imgfilters debug native cached 3ms MaxRSS:38M
      +- compile lib imgfilters debug native (reused)
```
Ten unit tests across the three wrappers, then the pipeline: generate into the cache, process that file, run the C demo, each checked against expected output. `-Doptimize=fast` passes the same 10.

Experiments. Change `count` in `palette.zig`'s `Entry` to `u16` and build: the `comptime` assertion fails before anything can go wrong at run time. Put the two `#define *_IMPLEMENTATION` lines into `c/stb.h` as well and build: translate-c now tries to turn the whole library, not just its declarations, into Zig, and fails on stb's SSE intrinsics ("extern structs cannot contain fields of type '@Vector(2, c_longlong)'") and on code it can't resolve. Function bodies belong to the C compiler; translate-c is for the interface. Then add a fourth filter: a `filters_threshold(rgb, pixel_count, level)` that maps each pixel to black or white, with its prototype in `filters.h`, a slice wrapper, a `--threshold N` option, and a test; three files, and the C demo can call it too.
