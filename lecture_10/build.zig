const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // SDL3, from the package manager: build.zig.zon names the git tag and the content hash, and
    // the first build fetches it into zig-pkg/ and compiles it from source for the target.
    const sdl = b.dependency("sdl", .{ .target = target, .optimize = optimize });
    const sdl_lib = sdl.artifact("SDL3");

    // Vulkan and SDL declarations, translated together into one module (lecture 9's technique).
    // The Vulkan headers come from the system (the libvulkan-dev package), the SDL headers from
    // the package we just fetched.
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("c/vk_sdl.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(sdl.path("include"));

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = translate.createModule() },
        },
    });

    // Shaders: GLSL compiled to SPIR-V by glslc while building, and embedded into the program.
    // Each compiled file becomes a named import that @embedFile can read.
    const shaders = [_]struct { import: []const u8, file: []const u8 }{
        .{ .import = "triangle_vert", .file = "triangle.vert" },
        .{ .import = "triangle_frag", .file = "triangle.frag" },
    };
    for (shaders) |shader| {
        const glslc = b.addSystemCommand(&.{"glslc"});
        glslc.addFileArg(b.path(b.fmt("shaders/{s}", .{shader.file})));
        glslc.addArg("-o");
        const spirv = glslc.addOutputFileArg(b.fmt("{s}.spv", .{shader.file}));
        exe_module.addAnonymousImport(shader.import, .{ .root_source_file = spirv });
    }

    const exe = b.addExecutable(.{ .name = "lecture_10", .root_module = exe_module });
    // SDL is linked statically from the artifact we built; the Vulkan loader is the system's.
    exe.root_module.linkLibrary(sdl_lib);
    exe.root_module.linkSystemLibrary("vulkan", .{});
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Open the window; options after --").dependOn(&run.step);

    // Tests: the unit tests, then a headless render of three frames into the cache. The second
    // needs a Vulkan device (a software one like lavapipe is enough).
    const test_step = b.step("test", "Run the unit tests and a headless render");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = exe_module })).step);

    const headless = b.addRunArtifact(exe);
    headless.addArgs(&.{ "--headless", "--frames", "3", "--size", "320x200", "--out" });
    _ = headless.addOutputFileArg("frame.ppm");
    headless.addCheck(.{ .expect_stdout_match = "wrote" });
    test_step.dependOn(&headless.step);
}
