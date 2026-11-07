//! Base64 (RFC 4648), with its decoding table built at compile time.

const std = @import("std");

pub const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const padding = '=';
/// Marks a byte that isn't in the alphabet.
const invalid: u8 = 0xff;

/// Maps a byte to its 6-bit value, or `invalid`. The block runs in the compiler: the executable holds
/// the finished 256-byte table, and the program never computes it.
pub const decode_table: [256]u8 = blk: {
    var table: [256]u8 = @splat(invalid);
    for (alphabet, 0..) |char, value| table[char] = value;
    break :blk table;
};

// The table is checked while compiling too: an assert here that fails is a compile error.
comptime {
    for (alphabet, 0..) |char, value| std.debug.assert(decode_table[char] == value);
    std.debug.assert(decode_table[padding] == invalid);
}

/// Encoded size of `len` bytes: every 3 bytes (or part of 3) become 4 characters.
pub fn encodedLen(len: usize) usize {
    return (len + 2) / 3 * 4;
}

/// Encodes `source` into `dest`, which must hold encodedLen(source.len) bytes, and returns the part written.
pub fn encode(dest: []u8, source: []const u8) []const u8 {
    std.debug.assert(dest.len >= encodedLen(source.len));
    var out: usize = 0;
    var i: usize = 0;
    // Whole groups of three bytes: 24 bits, cut into four 6-bit values.
    while (i + 3 <= source.len) : (i += 3) {
        const chunk = @as(u24, source[i]) << 16 | @as(u24, source[i + 1]) << 8 | source[i + 2];
        dest[out] = alphabet[@as(u6, @truncate(chunk >> 18))];
        dest[out + 1] = alphabet[@as(u6, @truncate(chunk >> 12))];
        dest[out + 2] = alphabet[@as(u6, @truncate(chunk >> 6))];
        dest[out + 3] = alphabet[@as(u6, @truncate(chunk))];
        out += 4;
    }
    // One or two bytes left over: pad with = to a group of four.
    switch (source.len - i) {
        0 => {},
        1 => {
            const chunk = @as(u24, source[i]) << 16;
            dest[out] = alphabet[@as(u6, @truncate(chunk >> 18))];
            dest[out + 1] = alphabet[@as(u6, @truncate(chunk >> 12))];
            dest[out + 2] = padding;
            dest[out + 3] = padding;
            out += 4;
        },
        2 => {
            const chunk = @as(u24, source[i]) << 16 | @as(u24, source[i + 1]) << 8;
            dest[out] = alphabet[@as(u6, @truncate(chunk >> 18))];
            dest[out + 1] = alphabet[@as(u6, @truncate(chunk >> 12))];
            dest[out + 2] = alphabet[@as(u6, @truncate(chunk >> 6))];
            dest[out + 3] = padding;
            out += 4;
        },
        else => unreachable, // the loop ran while 3 or more were left
    }
    return dest[0..out];
}

pub const DecodeError = error{ InvalidLength, InvalidCharacter, InvalidPadding };

/// Decoded size of an encoded string, accounting for its padding.
pub fn decodedLen(source: []const u8) DecodeError!usize {
    if (source.len % 4 != 0) return error.InvalidLength;
    if (source.len == 0) return 0;
    var pad: usize = 0;
    if (source[source.len - 1] == padding) pad += 1;
    if (source[source.len - 2] == padding) pad += 1;
    return source.len / 4 * 3 - pad;
}

/// Decodes `source` into `dest`, which must hold decodedLen(source) bytes, and returns the part written.
pub fn decode(dest: []u8, source: []const u8) DecodeError![]const u8 {
    const len = try decodedLen(source);
    std.debug.assert(dest.len >= len);
    var out: usize = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 4) {
        // Padding may only appear in the last group, in the last two places.
        var values: [4]u6 = undefined;
        var padded: usize = 0;
        for (source[i..][0..4], 0..) |char, j| {
            if (char == padding) {
                if (i + 4 != source.len or j < 2) return error.InvalidPadding;
                padded += 1;
                values[j] = 0;
            } else {
                if (padded > 0) return error.InvalidPadding; // a character after a =
                const value = decode_table[char];
                if (value == invalid) return error.InvalidCharacter;
                values[j] = @intCast(value);
            }
        }
        const chunk = @as(u24, values[0]) << 18 | @as(u24, values[1]) << 12 | @as(u24, values[2]) << 6 | values[3];
        dest[out] = @truncate(chunk >> 16);
        if (padded < 2) dest[out + 1] = @truncate(chunk >> 8);
        if (padded < 1) dest[out + 2] = @truncate(chunk);
        out += 3 - padded;
    }
    return dest[0..out];
}

/// Encodes into newly allocated memory. Caller owns the result.
pub fn encodeAlloc(gpa: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error![]u8 {
    const dest = try gpa.alloc(u8, encodedLen(source.len));
    _ = encode(dest, source);
    return dest;
}

/// Decodes into newly allocated memory. Caller owns the result.
pub fn decodeAlloc(gpa: std.mem.Allocator, source: []const u8) (DecodeError || std.mem.Allocator.Error)![]u8 {
    const dest = try gpa.alloc(u8, try decodedLen(source));
    errdefer gpa.free(dest);
    _ = try decode(dest, source);
    return dest;
}

// Tests

test "RFC 4648 test vectors" {
    // The pairs are a comptime array of tuples; the loop over them is an ordinary runtime loop.
    const vectors = [_]struct { []const u8, []const u8 }{
        .{ "", "" },
        .{ "f", "Zg==" },
        .{ "fo", "Zm8=" },
        .{ "foo", "Zm9v" },
        .{ "foob", "Zm9vYg==" },
        .{ "fooba", "Zm9vYmE=" },
        .{ "foobar", "Zm9vYmFy" },
    };
    var buffer: [16]u8 = undefined;
    for (vectors) |vector| {
        const plain, const encoded = vector;
        try std.testing.expectEqualStrings(encoded, encode(&buffer, plain));
        try std.testing.expectEqualStrings(plain, try decode(&buffer, encoded));
    }
}

test "agrees with the standard library on random data" {
    // A seeded generator, so the test is the same every run.
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    var plain: [64]u8 = undefined;
    var ours: [128]u8 = undefined;
    var theirs: [128]u8 = undefined;
    for (0..50) |_| {
        const len = random.intRangeAtMost(usize, 0, plain.len);
        random.bytes(plain[0..len]);
        const expected = std.base64.standard.Encoder.encode(&theirs, plain[0..len]);
        try std.testing.expectEqualStrings(expected, encode(&ours, plain[0..len]));
        var decoded: [64]u8 = undefined;
        try std.testing.expectEqualSlices(u8, plain[0..len], try decode(&decoded, expected));
    }
}

test "malformed input is rejected" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectError(error.InvalidLength, decode(&buffer, "Zm9"));
    try std.testing.expectError(error.InvalidCharacter, decode(&buffer, "Zm9!"));
    try std.testing.expectError(error.InvalidPadding, decode(&buffer, "Z==="));
    try std.testing.expectError(error.InvalidPadding, decode(&buffer, "Zg==Zg=="));
}

test "the allocating versions round-trip" {
    const encoded = try encodeAlloc(std.testing.allocator, "Zig is comptime all the way down");
    defer std.testing.allocator.free(encoded);
    const decoded = try decodeAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("Zig is comptime all the way down", decoded);
}
