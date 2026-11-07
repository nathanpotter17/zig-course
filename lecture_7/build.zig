const std = @import("std");

/// The program's own version, baked in through the options module.
const version = "0.7.0";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // User options: `zig build -Dprecision=5 -Dverbose`. They become comptime constants in the
    // program, through a module the build script writes: @import("build_options").
    const precision = b.option(u8, "precision", "Digits after the decimal point (default 3)") orelse 3;
    const verbose = b.option(bool, "verbose", "Print build and target information after the report") orelse false;
    const options = b.addOptions();
    options.addOption(u8, "precision", precision);
    options.addOption(bool, "verbose", verbose);
    options.addOption([]const u8, "version", version);

    // Generated code: a generator program built for the host (whatever the target), run during the
    // build with an output path in the cache, and its output imported as a module. The table is
    // rebuilt only when the generator changes.
    const generator = b.addExecutable(.{
        .name = "gen_table",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_table.zig"),
            .target = b.graph.host,
        }),
    });
    const generate = b.addRunArtifact(generator);
    const table_source = generate.addOutputFileArg("crc_table.zig");

    // The program for the chosen target.
    const exe = addProgram(b, target, optimize, options, table_source);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run the program; pass numbers after --").dependOn(&run.step);

    // Tests: this package's unit tests, the dependency's, and end-to-end checks that run the built
    // program and compare its output. All three hang off one `test` step.
    const test_step = b.step("test", "Run the unit tests and the end-to-end checks");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module })).step);
    const mathlib = b.dependency("mathlib", .{ .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mathlib.module("mathlib") })).step);

    const e2e = b.addRunArtifact(exe);
    e2e.addArgs(&.{ "3", "1", "4", "1", "5" });
    e2e.expectStdOutEqual("count   5\nmin     1.000\nmax     5.000\nmean    2.800\nmedian  3.000\nstddev  1.600\nprimes  3 5\n");
    test_step.dependOn(&e2e.step);
    const bad_input = b.addRunArtifact(exe);
    bad_input.addArg("seven");
    bad_input.expectExitCode(2);
    bad_input.expectStdErrEqual("not a number: seven\n");
    test_step.dependOn(&bad_input.step);

    // `zig build fmt`: fail if any file isn't formatted.
    const fmt = b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("src"), b.path("tools"), b.path("mathlib") }, .check = true });
    b.step("fmt", "Check that every file is formatted").dependOn(&fmt.step);

    // `zig build cross`: the same program for two other platforms, from this machine, into
    // zig-out/cross/<triple>/. The generator still runs on the host; only the program changes target.
    const cross_step = b.step("cross", "Cross-compile for x86_64 Windows and aarch64 Linux");
    for ([_][]const u8{ "x86_64-windows-gnu", "aarch64-linux-musl" }) |triple| {
        const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch unreachable;
        const cross_exe = addProgram(b, b.resolveTargetQuery(query), optimize, options, table_source);
        const install = b.addInstallArtifact(cross_exe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("cross/{s}", .{triple}) } },
        });
        cross_step.dependOn(&install.step);
    }

    // `zig build docs`: the dependency's documentation, rendered from its doc comments.
    const docs = b.addInstallDirectory(.{
        .source_dir = mathlib.artifact("mathlib").getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.step("docs", "Generate mathlib's documentation into zig-out/docs").dependOn(&docs.step);
}

/// The program as a compile step, for any target. Modules are tied to a target, so each target
/// gets its own instance of the dependency and its own imports.
fn addProgram(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    options: *std.Build.Step.Options,
    table_source: std.Build.LazyPath,
) *std.Build.Step.Compile {
    // A dependency named in build.zig.zon. The arguments are the dependency's own `-D` options:
    // its standardTargetOptions and standardOptimizeOption receive them.
    const mathlib = b.dependency("mathlib", .{ .target = target, .optimize = optimize });

    return b.addExecutable(.{
        .name = "lecture_7",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // Each import is a name the source code uses with @import, and the module behind it.
            .imports = &.{
                .{ .name = "mathlib", .module = mathlib.module("mathlib") },
                .{ .name = "build_options", .module = options.createModule() },
                .{ .name = "crc_table", .module = b.createModule(.{ .root_source_file = table_source }) },
            },
        }),
    });
}
