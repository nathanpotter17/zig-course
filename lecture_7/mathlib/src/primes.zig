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
