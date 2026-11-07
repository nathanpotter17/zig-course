const std = @import("std");

// The build script is a Zig program. `zig build` compiles and runs it, and the build() function
// describes a graph of steps (compile, install, run, test) that the build runner then executes.
pub fn build(b: *std.Build) void {
    // -Dtarget=... and -Doptimize=... on the command line; the host and debug by default.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // One module (a set of Zig source files rooted at main.zig) compiled into one executable.
    const exe = b.addExecutable(.{
        .name = "lecture_2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // Copy the executable into zig-out/bin/ when the default step runs.
    b.installArtifact(exe);

    // `zig build run [-- args]`: build, install, then run the installed executable.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run the lecture").dependOn(&run_cmd.step);

    // `zig build test`: compile every `test` block reachable from main.zig into a test runner, and run it.
    const tests = b.addTest(.{ .root_module = exe.root_module });
    b.step("test", "Run the lecture's tests").dependOn(&b.addRunArtifact(tests).step);
}
