//! A bump allocator: hands out consecutive pieces of one buffer, and frees them all at once.
//!
//! This file is a struct. Every Zig source file is implicitly `struct { ... }` wrapped around its
//! contents, so the field declarations below (`buffer`, `end`, `allocations`, `peak`) are the struct's
//! fields, the `fn`s are its methods, and `@import("BumpAllocator.zig")` evaluates to the type. It is
//! exactly equivalent to writing `pub const BumpAllocator = struct { buffer: []u8, ... };` in another
//! file; the standard library's FixedBufferAllocator.zig uses the same layout.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// The type this file declares, for use inside it.
const BumpAllocator = @This();

/// All the memory the allocator will ever hand out. The allocator doesn't own it: whoever made the
/// buffer frees it.
buffer: []u8,
/// Bytes used so far: everything before `end` has been handed out, everything after is free.
end: usize = 0,
/// Statistics, to show what the program asked for.
allocations: usize = 0,
peak: usize = 0,

pub fn init(buffer: []u8) BumpAllocator {
    return .{ .buffer = buffer };
}

/// Forgets every allocation at once. The caller promises not to use them again.
pub fn reset(self: *BumpAllocator) void {
    self.end = 0;
}

/// The std.mem.Allocator interface: a pointer to our state, type-erased to *anyopaque, and a table of
/// four functions that know how to turn it back. Every std data structure and function that allocates
/// takes one of these, so our allocator works everywhere the general-purpose one does.
pub fn allocator(self: *BumpAllocator) Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

/// Hands out `len` bytes at an address that's a multiple of `alignment`, or null when the buffer is full.
fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    // The reverse of the type erasure in allocator(): the opaque pointer is really a *BumpAllocator.
    // @alignCast asserts (checked in debug builds) that the address is aligned enough for the struct.
    const self: *BumpAllocator = @ptrCast(@alignCast(ctx));
    _ = ret_addr;

    // Skip forward to the next aligned address. Alignment.forward rounds an address up.
    const base = @intFromPtr(self.buffer.ptr);
    const start = alignment.forward(base + self.end) - base;
    const new_end = start + len;
    if (new_end > self.buffer.len) return null;

    self.end = new_end;
    self.allocations += 1;
    self.peak = @max(self.peak, new_end);
    return self.buffer[start..new_end].ptr;
}

/// Whether `memory` is the most recent allocation, the only one that can grow or shrink in place.
fn isLast(self: *const BumpAllocator, memory: []u8) bool {
    return memory.ptr + memory.len == self.buffer.ptr + self.end;
}

/// Grows or shrinks an allocation without moving it, if it can: shrinking always works, growing only
/// for the last allocation, and only while the buffer has room.
fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *BumpAllocator = @ptrCast(@alignCast(ctx));
    _ = alignment;
    _ = ret_addr;

    if (!self.isLast(memory)) return new_len <= memory.len;

    const start = self.end - memory.len;
    if (start + new_len > self.buffer.len) return false;
    self.end = start + new_len;
    self.peak = @max(self.peak, self.end);
    return true;
}

/// Like resize, but allowed to move the memory. A bump allocator has nowhere better to move it, so
/// it either resizes in place or declines, and the caller copies.
fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    return if (resize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
}

/// Frees nothing, unless it's the last allocation, which can be given back. Everything else waits for reset().
fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    const self: *BumpAllocator = @ptrCast(@alignCast(ctx));
    _ = alignment;
    _ = ret_addr;
    if (self.isLast(memory)) self.end -= memory.len;
}

// Tests

test "allocations are consecutive and aligned" {
    var buffer: [64]u8 = undefined;
    var bump = BumpAllocator.init(&buffer);
    const a = bump.allocator();

    const bytes = try a.alloc(u8, 3);
    const word = try a.create(u32);
    try std.testing.expectEqual(&buffer[0], &bytes[0]);
    // The u32 skipped one byte to land on a multiple of 4.
    try std.testing.expectEqual(@intFromPtr(&buffer[4]), @intFromPtr(word));
    try std.testing.expectEqual(8, bump.end);
    try std.testing.expectEqual(2, bump.allocations);
}

test "the last allocation can grow, shrink and be freed" {
    var buffer: [16]u8 = undefined;
    var bump = BumpAllocator.init(&buffer);
    const a = bump.allocator();

    const first = try a.alloc(u8, 4);
    var second = try a.alloc(u8, 4);
    try std.testing.expect(a.resize(second, 12)); // grows into the free space
    second = second.ptr[0..12];
    try std.testing.expect(!a.resize(first, 5)); // not the last allocation
    try std.testing.expect(a.resize(first, 2)); // shrinking is always fine
    a.free(second);
    try std.testing.expectEqual(4, bump.end);
}

test "out of memory is an error, not a crash" {
    var buffer: [8]u8 = undefined;
    var bump = BumpAllocator.init(&buffer);
    const a = bump.allocator();

    _ = try a.alloc(u8, 8);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 1));
    bump.reset();
    _ = try a.alloc(u8, 8);
}

test "passes the standard library's allocator test" {
    // The backing buffer comes from the testing allocator, which reports it if we forget to free it.
    const buffer = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(buffer);
    var bump = BumpAllocator.init(buffer);
    try std.heap.testAllocator(bump.allocator());
    try std.heap.testAllocatorAligned(bump.allocator());
}
