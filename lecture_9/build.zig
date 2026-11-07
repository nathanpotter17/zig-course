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
