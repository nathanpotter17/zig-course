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
