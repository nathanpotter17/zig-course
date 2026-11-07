const std = @import("std");

// The build script of a library package. Anyone who depends on this package gets its modules,
// its artifacts and its named steps through `b.dependency(...)`.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // addModule, unlike createModule, gives the module a name that dependents can ask for:
    // `dep.module("mathlib")`. Its root file decides what the package exposes.
    const mod = b.addModule("mathlib", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // A static library artifact built from the same module: for linking from C, and because the
    // documentation generator works on a compilation.
    const lib = b.addLibrary(.{
        .name = "mathlib",
        .root_module = mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // `zig build test` here runs the package's own tests.
    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run mathlib's tests").dependOn(&b.addRunArtifact(tests).step);

    // `zig build docs` renders the doc comments to HTML in zig-out/docs.
    const docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.step("docs", "Generate the documentation").dependOn(&docs.step);
}
