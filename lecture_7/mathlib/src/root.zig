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
