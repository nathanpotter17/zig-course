//! Generic data structures: functions that take types (and numbers) at compile time and return types.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A stack of T on the heap. `Stack(u32)` is a type; the function is evaluated once per distinct
/// argument and the result cached, so `Stack(u32) == Stack(u32)` is true.
pub fn Stack(comptime T: type) type {
    return struct {
        /// The struct being declared has no name of its own; @This() refers to it.
        const Self = @This();

        items: []T,
        len: usize = 0,

        pub fn init(gpa: Allocator, initial_capacity: usize) Allocator.Error!Self {
            return .{ .items = try gpa.alloc(T, initial_capacity) };
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.items);
            self.* = undefined;
        }

        /// Pushes a value, doubling the buffer when it's full. realloc moves the items if it has to.
        pub fn push(self: *Self, gpa: Allocator, value: T) Allocator.Error!void {
            if (self.len == self.items.len) {
                self.items = try gpa.realloc(self.items, @max(4, self.items.len * 2));
            }
            self.items[self.len] = value;
            self.len += 1;
        }

        /// The top value, removed, or null when the stack is empty.
        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.items[self.len];
        }

        pub fn peek(self: Self) ?T {
            return if (self.len == 0) null else self.items[self.len - 1];
        }

        pub fn capacity(self: Self) usize {
            return self.items.len;
        }
    };
}

/// A fixed-capacity queue that overwrites its oldest element when full. The capacity is a comptime
/// value, so the storage is an array inside the struct: no allocator, and the type knows its size.
pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    // Checks on the parameters run while the type is being built; a bad argument is a compile error
    // at the call site, like a type error.
    if (capacity == 0) @compileError("RingBuffer needs a capacity of at least 1");

    return struct {
        const Self = @This();

        buffer: [capacity]T = undefined,
        /// Index of the oldest element.
        head: usize = 0,
        len: usize = 0,

        pub fn push(self: *Self, value: T) void {
            const tail = (self.head + self.len) % capacity;
            self.buffer[tail] = value;
            if (self.len == capacity) {
                self.head = (self.head + 1) % capacity; // overwrote the oldest: advance past it
            } else {
                self.len += 1;
            }
        }

        /// The oldest element, removed, or null when empty.
        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            const value = self.buffer[self.head];
            self.head = (self.head + 1) % capacity;
            self.len -= 1;
            return value;
        }

        pub fn isFull(self: Self) bool {
            return self.len == capacity;
        }
    };
}

/// A matrix whose dimensions are part of its type. Multiplying a 2x3 by a 3x2 gives a 2x2, and
/// multiplying a 2x3 by a 2x3 is a compile error, because the types say so.
pub fn Matrix(comptime rows: usize, comptime cols: usize) type {
    return struct {
        const Self = @This();

        /// Declarations inside the type let other code read the dimensions back: Matrix(2, 3).cols is 3.
        pub const row_count = rows;
        pub const col_count = cols;

        data: [rows][cols]f64,

        pub const zero: Self = .{ .data = @splat(@splat(0)) };

        /// Only a square matrix has an identity. For a non-square type this declaration is a compile
        /// error, but only if something refers to it: declarations are analyzed lazily.
        pub fn identity() Self {
            if (rows != cols) @compileError("identity() needs a square matrix, not " ++ @typeName(Self));
            var m = zero;
            for (0..rows) |i| m.data[i][i] = 1;
            return m;
        }

        /// `other` is anytype so that it can be any Matrix(cols, n); the return type is computed from it.
        pub fn mul(self: Self, other: anytype) Matrix(rows, @TypeOf(other).col_count) {
            const Other = @TypeOf(other);
            if (Other.row_count != cols) {
                @compileError(std.fmt.comptimePrint("can't multiply a {d}x{d} matrix by a {d}x{d} one", .{ rows, cols, Other.row_count, Other.col_count }));
            }
            var result: Matrix(rows, Other.col_count) = .zero;
            for (0..rows) |i| {
                for (0..Other.col_count) |j| {
                    for (0..cols) |k| result.data[i][j] += self.data[i][k] * other.data[k][j];
                }
            }
            return result;
        }

        pub fn transpose(self: Self) Matrix(cols, rows) {
            var result: Matrix(cols, rows) = undefined;
            for (0..rows) |i| {
                for (0..cols) |j| result.data[j][i] = self.data[i][j];
            }
            return result;
        }

        /// The method that `{f}` in a format string calls. Any type with this signature can be printed.
        pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            for (self.data) |row| {
                try w.writeAll("[");
                for (row, 0..) |x, j| {
                    if (j > 0) try w.writeAll(", ");
                    try w.print("{d:6.2}", .{x});
                }
                try w.writeAll(" ]\n");
            }
        }
    };
}

// Tests

test "a stack grows and pops in reverse" {
    var stack = try Stack(u32).init(std.testing.allocator, 2);
    defer stack.deinit(std.testing.allocator);
    for (1..6) |i| try stack.push(std.testing.allocator, @intCast(i));
    try std.testing.expectEqual(5, stack.len);
    try std.testing.expect(stack.capacity() >= 5);
    try std.testing.expectEqual(5, stack.peek());
    try std.testing.expectEqual(5, stack.pop());
    try std.testing.expectEqual(4, stack.pop());
    stack.len = 0;
    try std.testing.expectEqual(null, stack.pop());
}

test "the same type arguments give the same type" {
    try std.testing.expect(Stack(u32) == Stack(u32));
    try std.testing.expect(Stack(u32) != Stack(i32));
    // Each instantiation is its own type with its own size.
    try std.testing.expectEqual(@sizeOf([4]f32) + 2 * @sizeOf(usize), @sizeOf(RingBuffer(f32, 4)));
}

test "a ring buffer overwrites the oldest" {
    var ring: RingBuffer(u8, 3) = .{};
    ring.push(1);
    ring.push(2);
    ring.push(3);
    try std.testing.expect(ring.isFull());
    ring.push(4); // 1 is gone
    try std.testing.expectEqual(2, ring.pop());
    try std.testing.expectEqual(3, ring.pop());
    try std.testing.expectEqual(4, ring.pop());
    try std.testing.expectEqual(null, ring.pop());
}

test "matrix dimensions are types" {
    const a = Matrix(2, 3){ .data = .{ .{ 1, 2, 3 }, .{ 4, 5, 6 } } };
    const b = a.transpose();
    try std.testing.expectEqual(Matrix(3, 2), @TypeOf(b));
    const c = a.mul(b); // 2x3 times 3x2: a 2x2
    try std.testing.expectEqual(Matrix(2, 2), @TypeOf(c));
    try std.testing.expectEqual(14, c.data[0][0]);
    try std.testing.expectEqual(77, c.data[1][1]);
    // a.mul(a) would not compile: "can't multiply a 2x3 matrix by a 2x3 one".
    const i = Matrix(2, 2).identity();
    try std.testing.expectEqual(c.data, c.mul(i).data);
}
