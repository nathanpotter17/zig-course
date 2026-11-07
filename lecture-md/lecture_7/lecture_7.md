# Lecture 7: Testing, the build system and packages

Every lecture so far has used the same twenty-line `build.zig`. This one is about everything else the build system does, and about the parts of `std.testing` we haven't needed yet. The project is small on purpose: a statistics library, `mathlib`, written as its own *package* with its own tests and documentation, and a command-line program that depends on it. Around them, the build script does the things real projects need:
- **User options:** `zig build -Dprecision=5 -Dverbose`, which the program sees as compile-time constants through a module the build writes.
- **A dependency** declared in `build.zig.zon`: here a path to a directory, and the same mechanism that fetches packages from the internet by hash.
- **Generated code:** a generator program built and run *during* the build, whose output is imported as a module.
- **Tests at three levels:** the library's unit tests, the program's, and end-to-end checks that run the built program and compare its output and exit code.
- **Cross-compilation** to Windows and ARM Linux from one command, **formatting checks**, and **documentation** rendered from doc comments.
- **In the tests:** approximate comparison, deep equality, a check that a function survives allocation failure at every point, a fuzz test, and a test that skips itself.

The files:
```text
lecture_7/
  build.zig, build.zig.zon       the program's package, depending on mathlib
  src/main.zig                   the program
  tools/gen_table.zig            the build-time generator
  mathlib/
    build.zig, build.zig.zon     the library package
    src/root.zig                 what @import("mathlib") sees
    src/stats.zig, src/primes.zig
```

## 7.1 Packages and the manifest

### Why
A Zig *package* is a directory with a `build.zig` and a `build.zig.zon`. The manifest names the package, lists the files that belong to it, and declares its dependencies: other packages, found at a path or fetched from a URL and verified by hash. There's no registry and no central index; a dependency is a URL (or a path) and a hash, and the compiler fetches and caches it. The same mechanism serves a library in a subdirectory and a library on the internet.

### How
- **`.name`** is an enum literal (`.lecture_7`), the default name dependents use for the package. **`.version`** is semantic. **`.fingerprint`** is a random 64-bit id the compiler generates on the first build and asks you to paste in; it identifies the package across renames and versions, and must never be copied from another package (hence the comment the compiler insists on). **`.minimum_zig_version`** is checked. **`.paths`** lists what's part of the package: only these files are hashed and distributed, so `zig-out` and `.zig-cache` are never included.
- **`.dependencies`** maps a name to a source. **`.path = "mathlib"`** is a directory relative to the manifest, used here and for any sub-project in the same repository. A remote dependency is **`.url`** plus **`.hash`**: `zig fetch --save https://example.com/pkg.tar.gz` downloads the archive, computes the hash and adds both lines. The hash is of the *contents* (the files in the dependency's own `.paths`), so the URL is just one way to obtain them: a mirror serving the same bytes satisfies the same hash. Lectures 9 and 10 use URL dependencies.
- **`.lazy = true`** on a dependency means it's fetched only if the build script asks for it with `b.lazyDependency`; a build that doesn't need it never downloads it.
- **The dependency's manifest** is its own: `mathlib/build.zig.zon` has its own name, fingerprint and paths. Nothing in it refers to the program that uses it.
- **`zig build --fetch`** fetches the dependency tree and stops, for an offline build later. The cache is global (`~/.cache/zig/p/`), keyed by hash, shared by every project on the machine.

### Code
`lecture_7/build.zig.zon`:
```zig
.{
    .name = .lecture_7,
    .version = "0.7.0",
    .fingerprint = 0xd53e3b99e71ba392, // Changing this has security and trust implications.
    .minimum_zig_version = "0.17.1",
    // Dependencies are fetched by hash from a URL, or found at a path relative to this file.
    // mathlib is the package in the mathlib/ directory: its build.zig and build.zig.zon are its own.
    .dependencies = .{
        .mathlib = .{ .path = "mathlib" },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src", "tools" },
}
```

`lecture_7/mathlib/build.zig.zon`:
```zig
.{
    .name = .mathlib,
    .version = "0.1.0",
    .fingerprint = 0x102b55997b1c1065, // Changing this has security and trust implications.
    .minimum_zig_version = "0.17.1",
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

## 7.2 The library package

### Why
A library's build script has one job the program's doesn't: to *expose* things. A module that dependents can import by name, an artifact they can link, steps they can run. `mathlib/build.zig` does all three, and its root source file decides what the module shows.

### How
- **`b.addModule("mathlib", ...)`** creates a module *and names it* for dependents, who get it with `dep.module("mathlib")`. `b.createModule` (what the lectures' executables use) makes an anonymous one. The module carries its target and optimization, which come from the dependency's own `-D` options: when the program's build calls `b.dependency("mathlib", .{ .target = ..., .optimize = ... })`, those arguments are what `standardTargetOptions` and `standardOptimizeOption` return inside this script.
- **`b.addLibrary(.{ .linkage = .static, ... })`** builds a static library from the module. The program doesn't link it (it imports the module and compiles the source itself, which is the normal way between Zig packages); the artifact is for C consumers and for the documentation generator, which works on a compilation. `installArtifact` puts `libmathlib.a` in `zig-out/lib`.
- **`getEmittedDocs()`** on a compile step is a directory of generated documentation: `index.html`, a WebAssembly viewer and the sources. `addInstallDirectory` copies it into `zig-out/docs`, and `b.step("docs", ...)` names the step. The docs come from the `///` and `//!` comments, with the source alongside.
- **The root file** `src/root.zig` is the module's whole public interface: `pub const stats = @import("stats.zig")` and `pub const primes = @import("primes.zig")` re-export two files as namespaces, so a dependent writes `mathlib.stats.mean`. A `pub const version` is a value dependents can read. The `test` block is lecture 2's discovery idiom, needed here too: a test build of the module starts at `root.zig`, which otherwise references nothing.
- **Private is the default.** Anything not `pub` in `root.zig`, and any file it doesn't import, is invisible to dependents. There's no header to keep in sync.

### Code
`lecture_7/mathlib/build.zig`:
```zig
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
```

`lecture_7/mathlib/src/root.zig`:
```zig
//! mathlib: descriptive statistics and prime numbers, as a package other builds can depend on.
//!
//! The root file is the package's public face: what's `pub` here is what `@import("mathlib")` sees.
//! The implementation lives in two files, re-exported as namespaces.

const std = @import("std");

pub const stats = @import("stats.zig");
pub const primes = @import("primes.zig");

/// The version, for programs that want to print it. The build script could also read this from
/// build.zig.zon; keeping it in the code keeps the library self-describing.
pub const version: std.SemanticVersion = .{ .major = 0, .minor = 1, .patch = 0 };

test {
    // Discovery (lecture 2): a test build of this module reaches both files through these references.
    _ = stats;
    _ = primes;
}
```

## 7.3 Testing beyond `expectEqual`

### Why
The library's code is short and ordinary; its tests are where the new material is. Floating point needs tolerances, structs need deep comparison, code that allocates needs to be checked under allocation failure, and a property that should hold for all inputs is a job for a fuzzer. Each has a function in `std.testing`.

### How
- **`expectApproxEqAbs(expected, actual, tolerance)`** compares floats within an absolute tolerance; `expectApproxEqRel` uses a relative one. `1.6` happens to come out exact here, but the test says what it means.
- **`expectEqualDeep(expected, actual)`** compares structs, arrays, slices, optionals and unions recursively by value, where `expectEqual` compares slices by pointer. It's the one to use on a `Summary`.
- **`checkAllAllocationFailures(backing, testFn, extra_args)`** calls `testFn(allocator, extra_args...)` once with a working allocator and counts its allocations, then once more per allocation with *that* allocation failing (`error.OutOfMemory`). The function must return the error cleanly and must not leak, which the testing allocator checks. `summarize` allocates once (the sorted copy for the median) and `sieve` twice (the bit set and the result): on the run where the result allocation fails, the bit set must still be freed, which its `defer` guarantees. This is how Zig code earns the claim that it handles out-of-memory, and it's cheap to add to any function that takes an allocator.
- **Fuzzing.** `std.testing.fuzz(context, testOne, options)` runs `testOne(context, smith)` with a `Smith` that turns the fuzzer's bytes into values: `smith.value(T)`, `smith.valueRangeAtMost(T, lo, hi)`, `smith.bytes(buf)`, `smith.eos()` for "out of input". In an ordinary `zig build test` the test runs once on a fixed input; with `zig build test --fuzz` the fuzzer mutates inputs to reach new code, reporting coverage, until stopped or until `--fuzz=N` iterations. The test checks a *property* (the mean lies between the extremes, the deviation is non-negative) rather than an example. One practical note for 0.17.1: fuzzing needs coverage instrumentation, which only the LLVM backend provides, so run it as `zig build test --fuzz=5000 -Doptimize=fast`; the default debug build on x86-64 uses Zig's own backend and the fuzzer reports a corrupted coverage file.
- **`error.SkipZigTest`** returned from a test marks it skipped, and the summary counts it separately. The slow sieve runs only in optimized builds: `builtin.mode` is the optimization mode, known at compile time, so the `if` costs nothing.
- **`std.DynamicBitSet`** is the sieve's storage: one bit per candidate, `initFull`, `unset`, `isSet`, `count`, and an iterator over the set bits. `std.StaticBitSet(N)` is the fixed-size version with no allocator.
- **Explicit error sets again:** `SummarizeError = error{EmptyInput} || Allocator.Error` documents exactly what `summarize` can fail with, so a dependent can `switch` on it.

### Code
`lecture_7/mathlib/src/stats.zig`:
```zig
//! Descriptive statistics over slices of f64.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The arithmetic mean, or null for an empty slice.
pub fn mean(values: []const f64) ?f64 {
    if (values.len == 0) return null;
    var total: f64 = 0;
    for (values) |v| total += v;
    return total / @as(f64, @floatFromInt(values.len));
}

/// The population standard deviation, or null for an empty slice.
pub fn stddev(values: []const f64) ?f64 {
    const m = mean(values) orelse return null;
    var sum_squares: f64 = 0;
    for (values) |v| sum_squares += (v - m) * (v - m);
    return @sqrt(sum_squares / @as(f64, @floatFromInt(values.len)));
}

/// The median: the middle value of the sorted data, or the mean of the two middle values. Sorting
/// needs a copy, hence the allocator; the copy is freed before returning.
pub fn median(gpa: Allocator, values: []const f64) Allocator.Error!?f64 {
    if (values.len == 0) return null;
    const sorted = try gpa.dupe(f64, values);
    defer gpa.free(sorted);
    std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
    const mid = sorted.len / 2;
    return if (sorted.len % 2 == 1) sorted[mid] else (sorted[mid - 1] + sorted[mid]) / 2;
}

/// Everything at once. A struct result, so a caller can print or serialize it as a whole.
pub const Summary = struct {
    count: usize,
    min: f64,
    max: f64,
    mean: f64,
    median: f64,
    stddev: f64,
};

pub const SummarizeError = error{EmptyInput} || Allocator.Error;

pub fn summarize(gpa: Allocator, values: []const f64) SummarizeError!Summary {
    if (values.len == 0) return error.EmptyInput;
    return .{
        .count = values.len,
        .min = std.mem.min(f64, values),
        .max = std.mem.max(f64, values),
        .mean = mean(values).?,
        .median = (try median(gpa, values)).?,
        .stddev = stddev(values).?,
    };
}

// Tests

test "mean, median and stddev of a known sample" {
    const sample = [_]f64{ 3, 1, 4, 1, 5 };
    try std.testing.expectEqual(2.8, mean(&sample));
    try std.testing.expectEqual(3, try median(std.testing.allocator, &sample));
    // Floating point: compare with a tolerance, not ==.
    try std.testing.expectApproxEqAbs(1.6, stddev(&sample).?, 1e-12);
    try std.testing.expectEqual(2.5, try median(std.testing.allocator, &.{ 1, 2, 3, 4 }));
}

test "empty input" {
    try std.testing.expectEqual(null, mean(&.{}));
    try std.testing.expectEqual(null, try median(std.testing.allocator, &.{}));
    try std.testing.expectError(error.EmptyInput, summarize(std.testing.allocator, &.{}));
}

test "summarize fills every field" {
    const summary = try summarize(std.testing.allocator, &.{ 3, 1, 4, 1, 5 });
    // expectEqualDeep compares structs (and slices, optionals, unions inside them) field by field.
    try std.testing.expectEqualDeep(Summary{ .count = 5, .min = 1, .max = 5, .mean = 2.8, .median = 3, .stddev = 1.6 }, summary);
}

/// The shape checkAllAllocationFailures wants: an allocator first, then anything else, returning an
/// error union. It's called once with a working allocator, then once per allocation with that
/// allocation failing, and must neither leak nor crash in any of those runs.
fn summarizeWithFailures(allocator: Allocator, values: []const f64) !void {
    _ = try summarize(allocator, values);
}

test "summarize survives allocation failure at every point" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, summarizeWithFailures, .{&[_]f64{ 2, 7, 1, 8 }});
}

/// A property for the fuzzer: for any data, the mean lies between the minimum and the maximum,
/// and the standard deviation is never negative. Smith turns the fuzzer's bytes into values.
fn meanIsBounded(_: void, smith: *std.testing.Smith) !void {
    var values: [32]f64 = undefined;
    var n: usize = 0;
    while (n < values.len and !smith.eos()) : (n += 1) {
        // Finite values only: a NaN or an infinity would make the property meaningless.
        values[n] = @floatFromInt(smith.valueRangeAtMost(i32, -1_000_000, 1_000_000));
    }
    if (n == 0) return;
    const sample = values[0..n];
    const m = mean(sample).?;
    try std.testing.expect(m >= std.mem.min(f64, sample) - 1e-9);
    try std.testing.expect(m <= std.mem.max(f64, sample) + 1e-9);
    try std.testing.expect(stddev(sample).? >= 0);
}

test "fuzz: the mean is bounded by the extremes" {
    // Without --fuzz this runs once on a fixed input; with `zig build test --fuzz` it runs
    // continuously on inputs the fuzzer mutates towards new code paths.
    try std.testing.fuzz({}, meanIsBounded, .{});
}
```

`lecture_7/mathlib/src/primes.zig`:
```zig
//! Prime numbers: a test by trial division, and a sieve.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Trial division up to the square root. Fine for the sizes a command-line tool meets.
pub fn isPrime(n: u64) bool {
    if (n < 2) return false;
    if (n % 2 == 0) return n == 2;
    var d: u64 = 3;
    while (d * d <= n) : (d += 2) {
        if (n % d == 0) return false;
    }
    return true;
}

/// Every prime up to and including `limit`, by the sieve of Eratosthenes. Caller owns the slice.
/// Two allocations: the sieve's bit set, freed on the way out, and the result.
pub fn sieve(gpa: Allocator, limit: u64) Allocator.Error![]u64 {
    if (limit < 2) return gpa.alloc(u64, 0);
    const size: usize = @intCast(limit + 1);

    // A dynamic bit set: one bit per candidate, all set, and the composites cleared.
    var candidates = try std.DynamicBitSet.initFull(gpa, size);
    defer candidates.deinit();
    candidates.unset(0);
    candidates.unset(1);
    var p: usize = 2;
    while (p * p < size) : (p += 1) {
        if (!candidates.isSet(p)) continue;
        var multiple = p * p;
        while (multiple < size) : (multiple += p) candidates.unset(multiple);
    }

    const result = try gpa.alloc(u64, candidates.count());
    var it = candidates.iterator(.{});
    var i: usize = 0;
    while (it.next()) |prime| : (i += 1) result[i] = prime;
    return result;
}

// Tests

test "isPrime on small numbers" {
    const expected = [_]bool{ false, false, true, true, false, true, false, true, false, false, false, true };
    for (expected, 0..) |is_prime, n| {
        try std.testing.expectEqual(is_prime, isPrime(n));
    }
    try std.testing.expect(isPrime(2_147_483_647)); // a Mersenne prime
    try std.testing.expect(!isPrime(2_147_483_649));
}

test "the sieve agrees with trial division" {
    const found = try sieve(std.testing.allocator, 1000);
    defer std.testing.allocator.free(found);
    try std.testing.expectEqual(168, found.len);
    try std.testing.expectEqual(997, found[found.len - 1]);
    for (found) |p| try std.testing.expect(isPrime(p));
    // And nothing is missing: every prime up to 1000 is in the list.
    var count: usize = 0;
    for (0..1001) |n| {
        if (isPrime(n)) count += 1;
    }
    try std.testing.expectEqual(count, found.len);
}

fn sieveWithFailures(allocator: Allocator, limit: u64) !void {
    const found = try sieve(allocator, limit);
    allocator.free(found);
}

test "the sieve frees its bit set when the result allocation fails" {
    // The first run counts the allocations (two); then each one is made to fail in turn, and the
    // testing allocator reports a leak if the bit set isn't freed on the failing path.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, sieveWithFailures, .{100});
}

test "a slow test, skipped unless the build is optimized" {
    // error.SkipZigTest marks a test as skipped rather than passed or failed. Here it keeps a
    // long-running check out of debug test runs; `zig build test -Doptimize=fast` includes it.
    if (builtin.mode == .debug) return error.SkipZigTest;
    const found = try sieve(std.testing.allocator, 2_000_000);
    defer std.testing.allocator.free(found);
    try std.testing.expectEqual(148_933, found.len);
}
```

## 7.4 Build options and generated code

### Why
Two things a program often wants from its build: configuration decided at build time (a feature flag, a version string, a precision) and code produced by a tool (a lookup table, bindings, embedded data). Zig does both through modules: the build script writes a Zig source file and hands it to the program as `@import("something")`, so the program sees ordinary compile-time constants, and the build system tracks the inputs so nothing is regenerated needlessly.

### How
- **`b.option(T, "name", "description")`** declares a `-Dname=value` option and returns `?T`: null if the user didn't pass it, hence `orelse 3`. The declared options appear in `zig build --help` under "Project-Specific Options" with their types. `bool` options accept `-Dverbose` alone as true.
- **`b.addOptions()`** creates a step that writes a Zig file of `pub const` declarations; `options.addOption(T, "name", value)` adds one (integers, bools, strings, enums, optionals, slices and more). `options.createModule()` is the module to import; the program names it `build_options` and reads `build_options.precision` as a comptime constant. Changing an option changes the generated file's contents, so dependents rebuild.
- **A generator in the build.** `tools/gen_table.zig` is an ordinary program that writes a Zig file. The build script compiles it *for the host* (`b.graph.host`), whatever the program's target, because it has to run here. `b.addRunArtifact(generator)` makes a run step, and **`addOutputFileArg("crc_table.zig")`** adds an argument that's a path in the cache and returns it as a `LazyPath`: a path that doesn't exist until the step runs. `b.createModule(.{ .root_source_file = table_source })` turns the future file into a module, and the dependency graph does the rest: the program's compilation waits for the generator to run, and the generator runs again only when its own source changes. The generated file is never committed.
- **`LazyPath`** is the build system's type for "a file or directory, maybe not yet": `b.path("src/main.zig")` for a source file, the output of a step, a dependency's path. Every API that takes a file takes one, so steps compose.
- **The generator** writes the CRC-32 table the way every CRC implementation computes it (eight shifts per entry), into a file whose first line says it's generated. It opens its output with `createFileAbsolute`, since the build passes an absolute cache path, and uses a buffered writer, as in lecture 6.

### Code
`lecture_7/tools/gen_table.zig`:
```zig
//! A build-time code generator: writes a Zig source file holding the CRC-32 lookup table.
//! The build script compiles this for the host, runs it with the output path as its argument, and
//! imports the file it writes as a module. The generated file is never checked in.

const std = @import("std");

/// The reflected polynomial of CRC-32 (ISO-HDLC, the one in zip, PNG and Ethernet).
const polynomial: u32 = 0xedb88320;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.log.err("usage: gen_table <output.zig>", .{});
        return error.MissingOutputPath;
    }

    // The build runner passes an absolute path inside its cache directory.
    const path = args[1];
    const file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.createFileAbsolute(init.io, path, .{})
    else
        try std.Io.Dir.cwd().createFile(init.io, path, .{});
    defer file.close(init.io);

    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(init.io, &buffer);
    const out = &file_writer.interface;

    try out.writeAll(
        \\//! Generated by tools/gen_table.zig at build time. Do not edit.
        \\
        \\pub const polynomial: u32 = 0xedb88320;
        \\
        \\/// table[i] is the CRC-32 of the single byte i, with the final inversion left out.
        \\pub const table: [256]u32 = .{
        \\
    );
    for (0..256) |i| {
        var crc: u32 = @intCast(i);
        for (0..8) |_| {
            crc = if (crc & 1 != 0) polynomial ^ (crc >> 1) else crc >> 1;
        }
        try out.print("{s}0x{x:0>8},{s}", .{ if (i % 4 == 0) "    " else " ", crc, if (i % 4 == 3) "\n" else "" });
    }
    try out.writeAll("};\n");
    try out.flush();
}
```

`lecture_7/build.zig`, part 1:
```zig
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
```

## 7.5 Depending on a package, for any target

### Why
`b.dependency` is how a build script reaches into another package: it runs the other package's `build.zig` with the arguments given, and returns a handle to its modules, artifacts and files. Because modules are tied to a target, a program built for several targets needs the dependency instantiated for each; `addProgram` wraps the whole recipe so the cross-compilation loop can call it.

### How
- **`b.dependency("mathlib", .{ .target = target, .optimize = optimize })`** looks `mathlib` up in `build.zig.zon`, runs its build script with these as its `-D` options, and returns a `*Dependency`. `.module("mathlib")` is the module the dependency declared with `addModule`; `.artifact("mathlib")` the library it built; `.path("...")` a file inside it. Calling `dependency` again with different arguments gives a different instance, which is what the cross targets need.
- **Imports** are declared when the module is created: `.imports = &.{ .{ .name = "mathlib", .module = ... }, ... }`. Each pairs the name used in `@import` with a module. The three here are the dependency, the options module and the generated table; `exe.root_module.addImport(name, module)` adds one later.
- **`addProgram`** is an ordinary Zig function that takes the build, a target, the optimization, the shared options step and the generated file's path, and returns the compile step. Build scripts are programs: helpers, loops and data tables are all available, and a long `build.zig` is organized the same way as any other Zig file.
- **Cross-compilation.** `std.Target.Query.parse(.{ .arch_os_abi = "x86_64-windows-gnu" })` parses a triple into a query, and `b.resolveTargetQuery` fills in the details (CPU model, OS version range). Passing the result as the target is the whole of cross-compiling in Zig: the compiler carries the libc headers and start files for every supported target, so there's nothing to install. `zig targets` lists them. The generator still runs on the host; the program, and the dependency, are compiled for the target.
- **`b.addInstallArtifact(exe, .{ .dest_dir = ... })`** installs with control over the destination: `.{ .override = .{ .custom = "cross/x86_64-windows-gnu" } }` puts each build in its own directory under `zig-out`. `b.fmt` formats a string with the build's allocator, for names computed in the script. The plain `installArtifact` is this with the defaults (`bin/` for executables, `lib/` for libraries).

### Code
`lecture_7/build.zig`, part 2 (the helper at the end of the file):
```zig
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
```

## 7.6 Steps: run, test, fmt, cross and docs

### Why
A *step* is a named unit of work the user can ask for: `zig build test`, `zig build cross`. Steps depend on other steps, and the runner executes the ones needed, in parallel, caching whatever hasn't changed. The rest of `build.zig` wires six of them.

### How
- **`run`** builds, installs and runs, forwarding arguments after `--`. `run.step.dependOn(b.getInstallStep())` makes it run the installed copy.
- **`test`** depends on four things: a test runner for the program's module, a test runner for the dependency's module (a dependency's tests aren't run unless asked; `b.addTest(.{ .root_module = mathlib.module("mathlib") })` asks), and two *end-to-end checks*. A `Run` step can assert on what the program does: `expectStdOutEqual` compares the whole standard output, `expectExitCode` the status, `expectStdErrEqual` the error output, and `addCheck` more specific matches. The build runner captures the output, compares, and reports a mismatch as a failed step with both texts. That's integration testing with no extra tooling, and it's how the Zig compiler's own tests check error messages.
- **`fmt`** is `b.addFmt(.{ .paths = ..., .check = true })`: `zig fmt --check` over the given paths as a build step, so CI can run `zig build fmt`. Without `.check` it reformats in place.
- **`cross`** loops over two triples, calling `addProgram` for each and installing under `zig-out/cross/`. Nothing about the source changes; `builtin.target` inside the program reflects each.
- **`docs`** installs the dependency's generated documentation; `mathlib.artifact("mathlib")` is the library compile step the dependency installed, and `getEmittedDocs` its docs directory.
- **`zig build --help`** lists every step with its description and every option with its type, generated from these calls. `--summary all` prints the whole step tree with timings; `--watch` rebuilds on file changes; `-j4` limits parallelism; `--prefix` moves `zig-out`.

### Code
`lecture_7/build.zig`, part 3 (the rest of `build`):
```zig
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
```

## 7.7 The program

### Why
The program is deliberately thin: its job is to show the three imports in use, and to be something the end-to-end checks can pin down.

### How
- **Three imports, three origins.** `@import("mathlib")` is the dependency; `@import("build_options")` the options module; `@import("crc_table")` the generated file. The program can't tell them apart from files of its own, and `@import("builtin")` is a fourth kind: the compiler's description of this compilation (`mode`, `target`, `zig_version_string`, `is_test`).
- **A comptime format string.** `build_options.precision` is a comptime constant, so `std.fmt.comptimePrint("{{d:.{d}}}", .{precision})` builds the format `"{d:.3}"` at compile time, and `"min     " ++ number ++ "\n"` concatenates it into the full format string, which `print` then checks against its arguments as usual. `{{` and `}}` are literal braces.
- **`crc32`** is the table-driven algorithm: one table lookup and one shift per byte. The test compares it with `std.hash.Crc32`, so the generator's output is verified every time the tests run.
- **The exit code** is the return value of `main`: 2 for a usage error, 0 otherwise; `std.debug.print` sends the complaint to standard error, which the `bad_input` check reads.
- **`-Dverbose`** adds a line with the baked-in version, the dependency's version (printed with `{f}`, since `SemanticVersion` has a `format` method), the Zig version, the mode and the target triple from `builtin.target`, and a CRC of the arguments.

### Code
`lecture_7/src/main.zig`:
```zig
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
```

## 7.8 Running it

### How
From `lecture_7/`:
```bash
zig build run -- 3 1 4 1 5
```
```text
count   5
min     1.000
max     5.000
mean    2.800
median  3.000
stddev  1.600
primes  3 5
```
```bash
zig build run -Dverbose -Dprecision=1 -- 3 1 4 1 5
```
```text
...
stddev  1.6
primes  3 5

lecture_7 0.7.0, mathlib 0.1.0, built with Zig 0.17.1 in debug mode for x86_64-linux-gnu; crc32 of the input 1376ff61
```
```bash
zig build test --summary all
```
```text
Build Summary: 11/11 steps succeeded; 11/12 tests passed (1 skipped)
test success
+- run test 2 pass (2 total)
|  +- compile test debug native
|     +- options
|     +- run exe gen_table (crc_table.zig)
|        +- compile exe gen_table debug native
+- run test 9 pass, 1 skip (10 total)
|  +- compile test debug native
+- run exe lecture_7 success
|  +- compile exe lecture_7 debug native
+- run exe lecture_7 success
```
The tree is the dependency graph: the program's tests needed the options and the generated table, which needed the generator. `-Doptimize=fast` un-skips the slow sieve test (12 of 12). `zig build cross` produces `zig-out/cross/x86_64-windows-gnu/lecture_7.exe` (with a `.pdb`) and `zig-out/cross/aarch64-linux-musl/lecture_7`, a statically linked ARM executable, in a few seconds each; `file` confirms what they are. `zig build fmt` is silent when everything is formatted and lists the files when not. `zig build docs` writes `zig-out/docs/index.html`; open it in a browser (it needs to be served or opened as a file with its `main.wasm` beside it).

Fuzzing, with the optimized build that has coverage instrumentation:
```bash
zig build test --fuzz=5000 -Doptimize=fast
```
```text
======= FUZZING REPORT =======
Step: run test
Fuzz test: "stats.test.fuzz: the mean is bounded by the extremes" (8d7178cc28056b61)
Runs: 0 -> 5003
Unique runs: 0 -> 3
Coverage: 0/10340 -> 33/10340 (0.32%)
```
Without a limit, `--fuzz` runs until interrupted and opens a web interface showing coverage. In `mathlib/`, `zig build test` and `zig build docs` work on their own: the package is complete by itself.

Two experiments: change the expected output in `e2e.expectStdOutEqual` by one character and run `zig build test` to see the build runner print both texts; and add a third triple to the `cross` loop, say `riscv64-linux-musl`, and build it. Then make `summarize` leak by removing the `defer gpa.free(sorted)` in `median`, and watch `checkAllAllocationFailures` and the testing allocator find it on the very first run.
