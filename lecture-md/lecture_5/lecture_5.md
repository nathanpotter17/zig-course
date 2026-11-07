# Lecture 5: comptime, generics and reflection

Zig has no templates, no macros, no preprocessor and no generics syntax. It has one idea instead: *code can run at compile time*, and types are ordinary values while it does. A generic container is a function that takes a type and returns a type. A lookup table is a loop that runs in the compiler. A serializer for every struct is a function that reads the struct's fields and generates the right code for each. `print`'s format string is checked the same way, by Zig code in the standard library, not by the compiler.

By the end of this lecture we'll have three small libraries built on that idea:
- **`generic.zig`:** a `Stack(T)`, a `RingBuffer(T, capacity)` whose capacity is part of its type, and a `Matrix(rows, cols)` that refuses, at compile time, to multiply matrices of the wrong shapes.
- **`reflect.zig`:** `printAny`, which prints any value by walking its type; `describe`, which builds a description of a type as a compile-time string; and `setField`, which parses "key = value" text into any struct, with each field parsed as its own type. A config parser written once, for every struct.
- **`base64.zig`:** an RFC 4648 encoder and decoder whose decoding table is computed by a `comptime` block and checked by another, tested against the standard library's.

`main.zig` demonstrates the mechanisms first: compile-time parameters, `comptime` variables and blocks, `inline for`, `anytype`, `@typeInfo`, `inline else`, and the standard library's compile-time tables. The build files are lecture 1's with the name changed.

## 5.1 Compile-time parameters and types as values

### Why
`fn max(comptime T: type, a: T, b: T) T` is the whole of Zig's generics. The parameter `T` is a type, passed at compile time; the function is compiled once per distinct `T`; and inside it, `T` is a constant like any other, so the body can branch on it. Everything else in this lecture is a use of that.

### How
- **`comptime T: type`** means the argument must be known at compile time, and inside the function it is. `type` is the type of types. `max(u8, 3, 7)` compiles a `u8` version, `max(f64, ...)` an `f64` one. The language reference calls it *compile-time duck typing*: `max(bool, ...)` fails to compile where `>` is applied to a `bool`, not at the call.
- **Types are values** in compile-time code: `const Int = if (@sizeOf(usize) == 8) u64 else u32;` picks a type with an `if`, `Int == u64` compares two, and `@typeName` prints one. A type can be stored in a `const`, put in a struct's declarations, returned from a function; it can't exist at run time, which is why `T` must be `comptime`.
- **A function that runs at compile time.** `firstPrimes` is ordinary Zig: a `while`, a `for` with an `else`, an array. Called at run time it computes primes at run time. Assigned to a namespace-level constant, `const primes = firstPrimes(10);`, it runs *in the compiler*, because every top-level initializer is a compile-time expression, and the executable contains the ten numbers. The language reference shows the generated code for its own version: a constant array, nothing else. There's no annotation on the function; the same function serves both.
- **`comptime` blocks and variables:** `comptime blk: { ... }` forces a block to run at compile time (a compile error if it can't), and `break :blk value` makes the result a constant. A `comptime var` (5.4) is a variable that exists only in the compiler.
- **`std.fmt.comptimePrint(fmt, args)`** is `bufPrint` at compile time: its result is a string literal, which `++` can glue to another one. `"    " ++ comptimePrint(...) ++ ": {any}\n"` builds a format string that is itself checked against its arguments.
- **`inline for`** unrolls a loop at compile time: the body is emitted once per element, and in each copy the element is a *comptime value*. That's what lets the body use it as a number of bits: `@Int(.unsigned, bits)` builds an integer type (`u24` is a real type), and `std.math.maxInt(T)` is a comptime constant. A runtime `for` couldn't do either. `.{ 8, 16, 24, 32 }` is a tuple, which `inline for` can walk; a runtime `for` can't.
- **The branch quota.** Compile-time loops are interpreted, and the compiler gives up after 1000 backward branches unless `@setEvalBranchQuota(n)` raises the limit. The prime table stays well under it; the base64 table in 5.6 (256 slots) does too.

### Code
`lecture_5/src/main.zig`, part 1:
```zig
const std = @import("std");
const generic = @import("generic.zig");
const reflect = @import("reflect.zig");
const base64 = @import("base64.zig");

// Discovery: the three files' tests run only if a test build reaches them (lecture 2).
test {
    _ = generic;
    _ = reflect;
    _ = base64;
}

// comptime: compile-time parameters, values and blocks

/// A generic function: T is a type passed at compile time, and the function is compiled once per T.
/// Compile-time duck typing: `max(bool, ...)` fails to compile because bools have no `>`.
fn max(comptime T: type, a: T, b: T) T {
    return if (a > b) a else b;
}

/// The first n primes, computed by whatever code calls it, at compile time or run time. The
/// namespace-level constant below forces compile time: the table is data in the executable.
fn firstPrimes(comptime n: usize) [n]u32 {
    var table: [n]u32 = undefined;
    var found: usize = 0;
    var candidate: u32 = 2;
    while (found < n) : (candidate += 1) {
        const is_prime = for (table[0..found]) |p| {
            if (candidate % p == 0) break false;
        } else true;
        if (is_prime) {
            table[found] = candidate;
            found += 1;
        }
    }
    return table;
}

const primes = firstPrimes(10);

fn demoComptime() void {
    std.debug.print("comptime:\n", .{});
    std.debug.print("    max(u8, 3, 7) = {d}; max(f64, 2.5, -1) = {d}; max of two strings' lengths: {d}\n", .{ max(u8, 3, 7), max(f64, 2.5, -1), max(usize, "abc".len, "de".len) });

    // Types are values at compile time: they can be stored, compared and passed around.
    const Int = if (@sizeOf(usize) == 8) u64 else u32;
    std.debug.print("    the type chosen for this machine is {s}; Int == u64: {}\n", .{ @typeName(Int), Int == u64 });

    // The table was computed while compiling. std.fmt.comptimePrint formats at compile time too: its
    // result is a string literal, here used as part of another format string.
    std.debug.print("    " ++ std.fmt.comptimePrint("the first {d} primes", .{primes.len}) ++ ": {any}\n", .{primes});

    // A comptime block can do what a runtime block does, and the result is a constant.
    const sum_of_squares = comptime blk: {
        var total: u64 = 0;
        for (primes) |p| total += @as(u64, p) * p;
        break :blk total;
    };
    std.debug.print("    sum of their squares, a constant: {d}\n", .{sum_of_squares});

    // inline for unrolls the loop at compile time, so the body sees a comptime-known value each time
    // and can do things no runtime loop could: here, use the value as a type's width.
    std.debug.print("    integer widths and their maximums:", .{});
    inline for (.{ 8, 16, 24, 32 }) |bits| {
        const T = @Int(.unsigned, bits);
        std.debug.print(" {s}={d}", .{ @typeName(T), std.math.maxInt(T) });
    }
    std.debug.print("\n", .{});
}
```

## 5.2 `anytype` and duck typing

### Why
Sometimes the type parameter is a nuisance: `sum(u32, &array)` repeats what the array already knows. `anytype` lets a parameter take any type, inferred from the argument, and `@TypeOf` and `@typeInfo` let the function look at what it got. The function is still compiled once per type; the type is just implicit.

### How
- **`fn sum(items: anytype) std.meta.Elem(@TypeOf(items))`:** the parameter type is inferred at each call, and the return type is computed from it: `std.meta.Elem` is the element type of an array, slice, pointer-to-array or vector. The return type expression runs at compile time with `@TypeOf(items)` known.
- **Branching on the type:** `if (@typeInfo(T) == .vector) return @reduce(.Add, items);` is an `if` on a comptime-known condition, so it's resolved while compiling: the vector version of `sum` contains only the `@reduce`, the slice version only the loop. (`for` can't iterate a vector, so without the branch the vector call wouldn't compile.) This is how one function body adapts to types with different capabilities.
- **`@TypeOf(sum(vector))` is `f32`:** the same source produces functions with different return types, and the compiler names them by their argument types in error messages.
- **A tuple of different types.** `totalArea(.{ Circle{...}, Square{...}, Square{...} })` takes a tuple, an anonymous struct whose fields are numbered, so each element keeps its own type. `inline for (shapes) |shape|` visits each with its type known, and `shape.area()` resolves to `Circle.area` or `Square.area` at compile time: static dispatch, no vtable, no common base type. A runtime slice could never hold a `Circle` and a `Square` together.
- **A clear error for a missing method.** `comptime reflect.requireMethods(@TypeOf(shape), &.{"area"})` (5.5) checks `@hasDecl` and emits `@compileError` naming the type and the method. Without it, a shape without `area` would still fail, but with "no field or member function named 'area'" pointing into `totalArea`, not at the caller's mistake. Interface checks in Zig are functions that run at compile time.
- **When to use which:** `comptime T: type` when the caller needs to name the type (`Stack(u32)`), or the type isn't derivable from the other arguments; `anytype` when the argument carries the type and the function only needs to work on it. The standard library uses both: `ArrayList(T)` and `std.mem.eql(T, a, b)` on one side, `print(fmt, args: anytype)` on the other.

### Code
`lecture_5/src/main.zig`, part 2:
```zig
// anytype: duck typing

/// `items` can be an array, a slice, a pointer to an array, or a vector. The element type comes from
/// the argument's type, and so does the code: a vector is summed with one @reduce, the rest with a loop.
/// The `if` on the type is resolved at compile time, so each version of sum contains only its own branch.
fn sum(items: anytype) std.meta.Elem(@TypeOf(items)) {
    const T = @TypeOf(items);
    if (@typeInfo(T) == .vector) return @reduce(.Add, items);
    var total: std.meta.Elem(T) = 0;
    for (items) |item| total += item;
    return total;
}

const Circle = struct {
    radius: f64,
    pub fn area(self: Circle) f64 {
        return std.math.pi * self.radius * self.radius;
    }
};

const Square = struct {
    side: f64,
    pub fn area(self: Square) f64 {
        return self.side * self.side;
    }
};

/// A tuple of shapes of different types, which no runtime collection could hold. inline for visits
/// each with its own type, and the comptime check gives a clear error for a shape without area().
fn totalArea(shapes: anytype) f64 {
    var total: f64 = 0;
    inline for (shapes) |shape| {
        comptime reflect.requireMethods(@TypeOf(shape), &.{"area"});
        total += shape.area();
    }
    return total;
}

fn demoAnytype() void {
    std.debug.print("anytype:\n", .{});
    const array = [_]u32{ 1, 2, 3 };
    var runtime_len: usize = 2;
    _ = &runtime_len;
    const slice: []const u32 = array[0..runtime_len];
    const vector: @Vector(4, f32) = .{ 0.5, 0.5, 1, 2 };
    std.debug.print("    sum of an array {d}, a slice {d}, a vector {d}\n", .{ sum(array), sum(slice), sum(vector) });
    // `@TypeOf(sum(...))` differs per call: the function has as many versions as it has argument types.
    std.debug.print("    the vector sum is a {s}\n", .{@typeName(@TypeOf(sum(vector)))});

    std.debug.print("    total area of a circle and two squares: {d:.3}\n", .{totalArea(.{ Circle{ .radius = 1 }, Square{ .side = 2 }, Square{ .side = 3 } })});
}
```

## 5.3 Generic data structures

### Why
`std.ArrayList(u32)` is a function call that returns a type, and so is every generic container in the standard library. Writing three of our own shows the pattern: a function with `comptime` parameters that returns a `struct { ... }`, with `@This()` to name the struct inside itself, and with checks on the parameters that become compile errors at the call site.

### How
- **The shape:** `pub fn Stack(comptime T: type) type { return struct { ... }; }`. The returned struct is anonymous; `const Self = @This();` gives it a name for use in signatures. The compiler memoizes the function: `Stack(u32)` evaluated twice is the same type, so values of it are interchangeable, and `Stack(u32) != Stack(i32)`.
- **`Stack`** stores a slice and a length and takes the allocator on every call, like `ArrayList` (lecture 3). `push` doubles the buffer with `realloc` when full; `pop` and `peek` return `?T`. `deinit` sets `self.* = undefined` after freeing, so a use after `deinit` reads `0xaa` bytes in a debug build rather than the old pointer.
- **A number as a type parameter.** `RingBuffer(T, capacity)` has `buffer: [capacity]T` as a field: the capacity is baked into the type, the storage is inline, and there's no allocator at all. `RingBuffer(u8, 4)` and `RingBuffer(u8, 8)` are different types of different sizes; the test checks one's size exactly.
- **Checking parameters:** `if (capacity == 0) @compileError("...")` at the top of the function runs when the type is instantiated. `RingBuffer(u8, 0)` anywhere in the program is a compile error pointing at that line, with the message; nothing at run time.
- **Dimensions as types.** `Matrix(rows, cols)` exposes its dimensions as declarations, `row_count` and `col_count`, so other code can compute with them. `mul` takes `other: anytype` and declares its return type as `Matrix(rows, @TypeOf(other).col_count)`: a 2x3 times a 3x2 *is* a 2x2 as far as the type system is concerned. Inside, `if (Other.row_count != cols) @compileError(comptimePrint(...))` makes a shape mismatch a compile error with the actual numbers in the message. `transpose` returns `Matrix(cols, rows)`.
- **Lazy declarations.** `identity()` contains `@compileError` for a non-square matrix, yet `Matrix(2, 3)` compiles fine: declarations are analyzed only when referenced, so the error fires only for code that calls `Matrix(2, 3).identity()`. This laziness is why a generic type can offer methods that make sense for only some parameters.
- **`format`** is the method the `{f}` format specifier calls: `pub fn format(self, w: *std.Io.Writer) std.Io.Writer.Error!void`. Any type with that method prints with `{f}`; `{d:6.2}` inside it right-aligns each number in 6 columns with 2 decimals.
- **`pub const zero: Self = .{ .data = @splat(@splat(0)) };`** is a constant of the type, inside the type, like `ArrayList.empty`; `@splat` nested fills a 2D array.

### Code
`lecture_5/src/generic.zig`:
```zig
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
```

## 5.4 Reflection: walking a type

### Why
`std.debug.print("{any}", .{value})` prints any value. Nothing in the compiler knows how; it's a function in the standard library that asks `@typeInfo` what the value's type is made of and recurses. `printAny` is a small version of it, and `describe` does the same to produce a compile-time string. Once the pattern is clear, serializers, hashers, comparators and parsers for every type are the same loop.

### How
- **`@typeInfo(T)`** returns a `std.lang.Type`, a tagged union with one case per kind of type: `.int` with its signedness and bits, `.pointer` with its size and child, `.array` with its length and child, `.@"struct"` with `field_names` and `field_types` (parallel slices) and `is_tuple`, `.@"enum"`, `.@"union"` with its `tag_type`, `.optional`, `.error_union`, and so on. Keywords as field names are written `@"struct"`. It's a comptime value, so a `switch` on it is resolved at compile time and only the matching prong is compiled into each version of `printAny`.
- **Recursion through types.** `.optional => if (value) |inner| try printAny(w, inner)` calls `printAny` with a different type, which instantiates another version. The error set is named (`Writer.Error!void`) because of the recursion, as in lecture 4. Any pointer to one item prints what it points at, so a `*const [5:0]u8` string literal goes through `.pointer` to `.array`.
- **Byte arrays versus strings.** A `[N]u8` is a list of numbers unless it carries a 0 sentinel, which is what a string literal dereferences to; `info.sentinel()` reads it. A `[]const u8` slice is printed as a string, since that's the convention for strings. `&value` turns an array into a slice for `{s}` and for `printList`.
- **`inline for` over fields.** `inline for (info.field_names, 0..) |name, i|` unrolls once per field with `name` a comptime string, so `@field(value, name)` is an ordinary field access in the generated code. `@field` accesses a field (or declaration) by a comptime-known string; it's how generated code reaches into structs.
- **`inline else` on a tagged union.** `switch (value) { inline else => |payload, tag| ... }` generates one prong per field, each with `payload` of that field's type and `tag` a comptime constant. A bare union has no tag to switch on; the `@compileError` says so instead of letting the compiler produce a confusing message.
- **`@compileError`** in the `else` of the type switch makes unsupported types a compile error with the type's name. Because the switch is comptime, the error fires only if a program actually tries to print such a type.
- **`describe`** builds a string at compile time. `comptime var text: []const u8` lives only in the compiler; `text = text ++ ...` concatenates comptime strings; the switch on `@typeInfo(T)` and the `inline for` over fields are unrolled. The function returns a `[]const u8` that is comptime-known: a string literal in the executable, built by Zig code. `@tagName(@typeInfo(T))` is the name of the type's kind.

### Code
`lecture_5/src/reflect.zig`, part 1:
```zig
//! Reflection: code that reads types at compile time and generates the right code for each.

const std = @import("std");
const Writer = std.Io.Writer;

/// Prints any value in a Zig-like notation, by switching on its type's structure. The switch runs at
/// compile time, since @typeInfo is comptime-known, so each instantiation of printAny is straight-line
/// code for one type. The error set is named because the function is recursive.
pub fn printAny(w: *Writer, value: anytype) Writer.Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int, .comptime_int, .float, .comptime_float => try w.print("{d}", .{value}),
        .bool => try w.print("{}", .{value}),
        .void => try w.writeAll("{}"),
        .@"enum" => try w.print(".{t}", .{value}),
        .error_set => try w.print("error.{t}", .{value}),
        .optional => if (value) |inner| try printAny(w, inner) else try w.writeAll("null"),
        .error_union => if (value) |inner| try printAny(w, inner) else |err| try printAny(w, err),
        .array => |info| {
            // A 0-terminated byte array is what a string literal dereferences to; print it as text.
            // Any other array, including a plain [N]u8, is a list of values.
            if (info.child == u8 and info.sentinel() == 0) return w.print("\"{s}\"", .{&value});
            try printList(w, &value);
        },
        .pointer => |info| switch (info.size) {
            // A single-item pointer: print what it points at. For a pointer to an array, that's the array.
            .one => try printAny(w, value.*),
            .slice => if (info.child == u8) try w.print("\"{s}\"", .{value}) else try printList(w, value),
            .many, .c => try w.print("{*}", .{value}),
        },
        .@"struct" => |info| {
            try w.writeAll(if (info.is_tuple) ".{ " else "{ ");
            // inline for unrolls at compile time, once per field, so `name` is a comptime string and
            // @field(value, name) is an ordinary field access in the generated code.
            inline for (info.field_names, 0..) |name, i| {
                if (i > 0) try w.writeAll(", ");
                if (!info.is_tuple) try w.print(".{s} = ", .{name});
                try printAny(w, @field(value, name));
            }
            try w.writeAll(" }");
        },
        .@"union" => |info| {
            if (info.tag_type == null) @compileError("printAny can't print the bare union " ++ @typeName(T) ++ ": it doesn't know which field is active");
            // `inline else` generates a prong per field; `tag` is comptime-known in each.
            switch (value) {
                inline else => |payload, tag| {
                    try w.print(".{{ .{t} = ", .{tag});
                    try printAny(w, payload);
                    try w.writeAll(" }");
                },
            }
        },
        // A type this function doesn't handle is a compile error with a clear message, not a runtime one.
        else => @compileError("printAny doesn't know how to print a " ++ @typeName(T)),
    }
}

fn printList(w: *Writer, items: anytype) Writer.Error!void {
    try w.writeAll("[");
    for (items, 0..) |item, i| {
        if (i > 0) try w.writeAll(", ");
        try printAny(w, item);
    }
    try w.writeAll("]");
}

/// A one-line description of a type, built at compile time by concatenating strings. `text` is a
/// comptime variable, so every assignment to it happens in the compiler, and the switch on a
/// comptime-known value is unrolled too; the caller receives a string literal.
pub fn describe(comptime T: type) []const u8 {
    comptime var text: []const u8 = @typeName(T) ++ ": ";
    switch (@typeInfo(T)) {
        .int => |info| text = text ++ std.fmt.comptimePrint("{t} {d}-bit integer", .{ info.signedness, info.bits }),
        .float => |info| text = text ++ std.fmt.comptimePrint("{d}-bit float", .{info.bits}),
        .@"struct" => |info| {
            text = text ++ std.fmt.comptimePrint("struct of {d} fields (", .{info.field_names.len});
            inline for (info.field_names, info.field_types, 0..) |name, FieldType, i| {
                text = text ++ (if (i > 0) ", " else "") ++ name ++ ": " ++ @typeName(FieldType);
            }
            text = text ++ ")";
        },
        .@"enum" => |info| text = text ++ std.fmt.comptimePrint("enum of {d} values backed by {s}", .{ info.field_names.len, @typeName(info.tag_type) }),
        .@"union" => |info| text = text ++ std.fmt.comptimePrint("{s} union of {d} fields", .{ if (info.tag_type != null) "tagged" else "bare", info.field_names.len }),
        .pointer => |info| text = text ++ std.fmt.comptimePrint("{t} pointer to {s}", .{ info.size, @typeName(info.child) }),
        else => text = text ++ @tagName(@typeInfo(T)),
    }
    return text;
}
```

## 5.5 Reflection: generating code from a type

### Why
Reading a type is half of reflection; the other half is generating code from it. `setField` turns "port = 8080" into `config.port = 8080` for any struct, parsing the text as whatever type the field has. It's the core of every config-file, command-line and JSON parser in Zig, including `std.json`'s, and it needs no annotations on the struct.

### How
- **`setField(target: anytype, name, text)`:** `target` is a pointer to any struct; `@TypeOf(target.*)` is the struct type. `inline for` over `field_names` emits one `if (std.mem.eql(u8, name, field_name))` per field; the runtime cost is a string comparison per field until the match, and the code inside each `if` is specialized to that field: `@FieldType(T, field_name)` is its type, and `@field(target, field_name) = ...` the assignment.
- **`parseAs(comptime T, text) ?T`** switches on the field type's kind: `parseInt` for integers (the `catch null` turns its errors into "no value"), `parseFloat`, a comparison for bools, `std.meta.stringToEnum` for enums, the text itself for `[]const u8`, and recursion for optionals. A field type it can't handle is a compile error at the point of use, naming the type. The result type `?T` differs per instantiation.
- **Errors versus null:** `parseAs` returns `null` for unparseable text because the caller has one thing to do about it; `setField` turns that into `error.InvalidValue`, and a name that matches no field into `error.UnknownField`. `SetError` is the named set callers switch on.
- **`requireMethods`** is a compile-time interface check: `@hasDecl(T, name)` is true if `T` has a *public* declaration of that name, and `@compileError` with a built-up message makes a clear diagnostic. `@hasField` does the same for fields. The language reference warns against using `@hasDecl` for feature detection (a renamed method silently disables code); here it's used to produce an error, which is the safe direction.
- **The tests** print a struct with every kind of field, check `describe`'s strings (one of them at compile time, with `comptime std.debug.assert`), fill a config from text, and check both error cases. `printToString` captures `printAny`'s output in an `Allocating` writer and hands the buffer to the caller with `toOwnedSlice`.

### Code
`lecture_5/src/reflect.zig`, part 2:
```zig
/// Sets a struct field by name from text, parsing the text according to the field's type. This is how
/// a config-file parser or a command-line parser is written once for every struct.
pub const SetError = error{ UnknownField, InvalidValue };

pub fn setField(target: anytype, name: []const u8, text: []const u8) SetError!void {
    const T = @TypeOf(target.*);
    // One `if` per field, unrolled; the runtime cost is a string comparison per field until the match.
    inline for (@typeInfo(T).@"struct".field_names) |field_name| {
        if (std.mem.eql(u8, name, field_name)) {
            const FieldType = @FieldType(T, field_name);
            @field(target, field_name) = parseAs(FieldType, text) orelse return error.InvalidValue;
            return;
        }
    }
    return error.UnknownField;
}

/// Parses text as a value of T: integers, floats, bools, enums (by name) and strings.
fn parseAs(comptime T: type, text: []const u8) ?T {
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, text, 10) catch null,
        .float => std.fmt.parseFloat(T, text) catch null,
        .bool => if (std.mem.eql(u8, text, "true")) true else if (std.mem.eql(u8, text, "false")) false else null,
        .@"enum" => std.meta.stringToEnum(T, text),
        .pointer => |info| if (info.size == .slice and info.child == u8) text else @compileError("can't parse a " ++ @typeName(T)),
        .optional => |info| if (std.mem.eql(u8, text, "null")) null else parseAs(info.child, text),
        else => @compileError("can't parse a " ++ @typeName(T)),
    };
}

/// Checks at compile time that a type has the public methods an interface needs, with a message that
/// names what's missing. Used as `comptime requireMethods(T, &.{ "area", "name" });`.
pub fn requireMethods(comptime T: type, comptime names: []const []const u8) void {
    inline for (names) |name| {
        if (!@hasDecl(T, name)) @compileError(@typeName(T) ++ " is missing the method '" ++ name ++ "'");
    }
}

// Tests

const Level = enum { low, high };
const Sample = struct {
    name: []const u8,
    level: Level,
    readings: [3]u8,
    note: ?[]const u8 = null,
    pair: struct { u8, bool } = .{ 7, true },
};
const Message = union(enum) { text: []const u8, code: u32 };

fn printToString(gpa: std.mem.Allocator, value: anytype) ![]u8 {
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try printAny(&out.writer, value);
    return out.toOwnedSlice();
}

test "printAny walks structs, arrays, optionals and unions" {
    const sample = Sample{ .name = "probe", .level = .high, .readings = .{ 1, 2, 3 } };
    const text = try printToString(std.testing.allocator, sample);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{ .name = \"probe\", .level = .high, .readings = [1, 2, 3], .note = null, .pair = .{ 7, true } }", text);

    const message = try printToString(std.testing.allocator, Message{ .code = 404 });
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings(".{ .code = 404 }", message);

    const slice = try printToString(std.testing.allocator, @as([]const u16, &.{ 10, 20 }));
    defer std.testing.allocator.free(slice);
    try std.testing.expectEqualStrings("[10, 20]", slice);
}

test "describe builds its text at compile time" {
    try std.testing.expectEqualStrings("u8: unsigned 8-bit integer", describe(u8));
    try std.testing.expectEqualStrings("reflect.Level: enum of 2 values backed by u1", describe(Level));
    try std.testing.expectEqualStrings("[]const u8: slice pointer to u8", describe([]const u8));
    // comptime: the string is a constant, so the comparison itself could run at compile time.
    comptime std.debug.assert(std.mem.startsWith(u8, describe(Sample), "reflect.Sample: struct of 5 fields ("));
}

test "setField parses by field type" {
    const Config = struct { port: u16 = 80, verbose: bool = false, level: Level = .low, name: []const u8 = "", ratio: f32 = 1.0 };
    var config: Config = .{};
    try setField(&config, "port", "8080");
    try setField(&config, "verbose", "true");
    try setField(&config, "level", "high");
    try setField(&config, "name", "server");
    try setField(&config, "ratio", "0.5");
    try std.testing.expectEqual(8080, config.port);
    try std.testing.expect(config.verbose);
    try std.testing.expectEqual(.high, config.level);
    try std.testing.expectEqualStrings("server", config.name);
    try std.testing.expectEqual(0.5, config.ratio);
    try std.testing.expectError(error.InvalidValue, setField(&config, "port", "eighty"));
    try std.testing.expectError(error.UnknownField, setField(&config, "colour", "red"));
}

test "requireMethods passes for a type that has them" {
    const Circle = struct {
        pub fn area(_: @This()) f64 {
            return 0;
        }
    };
    comptime requireMethods(Circle, &.{"area"});
    // comptime requireMethods(Circle, &.{"perimeter"}); would be a compile error naming the method.
}
```

## 5.6 Compile-time tables

### Why
A lookup table replaces a computation with an index. The C way is to paste the table into the source and hope it's right; Zig's is to write the loop that computes it inside a `comptime` block, so the compiler builds the table and the source shows how. The base64 decoder needs a 256-entry table from byte to 6-bit value, and the standard library has two ready-made tables for the common cases: a map from strings and an array indexed by an enum.

### How
- **`decode_table`** is `[256]u8`, filled by a labeled block at namespace level: `@splat(invalid)` then one assignment per alphabet character. The block runs in the compiler; the executable holds 256 bytes. A second `comptime { ... }` block asserts the table is right, and a failing assert there is a compile error. The alphabet is a string literal, and `for (alphabet, 0..) |char, value|` indexes the table by the character's byte value.
- **The encoder** packs three bytes into a `u24` with shifts and `|`, then takes four 6-bit slices with `@truncate` to `u6`, which is exactly the index type the 64-entry alphabet wants: a `u6` can't be out of bounds, so the index needs no check. The leftover one or two bytes are handled by a `switch` on `source.len - i`, with `=` padding; the `else => unreachable` documents that the loop guarantees 0, 1 or 2.
- **The decoder** validates as it goes: a length that isn't a multiple of 4, a byte that isn't in the table (`invalid`), or padding anywhere but the last two places of the last group is an error in `DecodeError`. `decodedLen` computes the output size from the padding so callers can allocate first.
- **The tests** check the seven RFC 4648 vectors both ways (a comptime array of tuples, destructured in the loop), compare against `std.base64.standard` on 50 random inputs from a seeded `std.Random.DefaultPrng` (seeded, so the test is deterministic), and check each error.
- **`std.StaticStringMap(V).initComptime(.{ .{ "key", value }, ... })`** builds a string-to-value map at compile time, sorted by key length for a fast lookup, with no allocation and no hashing. `get` returns `?V`. It's what the standard library uses for keyword tables, and it's the right tool for a command parser or an enum-from-name with aliases.
- **`std.EnumArray(E, V)`** is an array with one slot per enum value, indexed by the enum: `counts.set(.run, 3)`, `counts.getPtr(.run).* += 1`, and an iterator over `(key, value)` entries. It's lecture 1's `stock: [Product.all.len]u8` with the `@backingInt` done by the type. `.initFill(0)` fills every slot.

### Code
`lecture_5/src/base64.zig`:
```zig
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
```

`lecture_5/src/main.zig`, part 3:
```zig
// Compile-time tables

const Command = enum { help, run, stop, status };

/// A map from strings to values, built at compile time and searched with a binary search over
/// keys sorted by length. No allocation, no hashing at run time.
const commands = std.StaticStringMap(Command).initComptime(.{
    .{ "help", .help },
    .{ "run", .run },
    .{ "stop", .stop },
    .{ "status", .status },
});

fn demoTables(gpa: std.mem.Allocator) !void {
    std.debug.print("Tables:\n", .{});
    for ([_][]const u8{ "run", "status", "reboot" }) |word| {
        std.debug.print("    '{s}' -> {?t}\n", .{ word, commands.get(word) });
    }

    // An array indexed by an enum: one slot per value, checked at compile time, no @backingInt.
    var counts: std.EnumArray(Command, u32) = .initFill(0);
    counts.set(.run, 3);
    counts.getPtr(.run).* += 1;
    counts.set(.help, 1);
    var it = counts.iterator();
    std.debug.print("    counts:", .{});
    while (it.next()) |entry| std.debug.print(" {t}={d}", .{ entry.key, entry.value.* });
    std.debug.print("\n", .{});

    // The base64 decode table was built by a comptime block; here's a slice of it.
    std.debug.print("    decode_table['A'..'F'] = {any}, ['0'] = {d}, ['!'] = 0x{x}\n", .{ base64.decode_table['A' .. 'F' + 1], base64.decode_table['0'], base64.decode_table['!'] });
    const encoded = try base64.encodeAlloc(gpa, "comptime");
    defer gpa.free(encoded);
    const decoded = try base64.decodeAlloc(gpa, encoded);
    defer gpa.free(decoded);
    std.debug.print("    'comptime' -> {s} -> {s}\n", .{ encoded, decoded });
}
```

## 5.7 The program

### Why
The remaining demos use the three libraries from outside: a config parsed into a struct, a nested record printed by its type, and the containers in use, including the `{f}` formatting of a matrix.

### How
- **The config parser** is `setField` in a loop over lines: `std.mem.cutScalar` splits each line at `=`, `std.mem.trim` cleans both sides, and the two error cases are reported and skipped. `Server` is an ordinary struct with defaults; nothing about it is written for the parser's benefit, and a new field would be accepted the moment it's declared.
- **`comptime reflect.describe(Server)`** at the call site makes clear the string is a constant; it would be anyway.
- **A recursive type.** `Record` has `parent: ?*const @This()`: a struct can refer to itself through a pointer (its size is known), and `@This()` names the struct from inside its own declaration. `printAny` follows the pointer, prints the parent record, and prints the union's active field with `inline else`.
- **`std.meta.fieldNames(Server)`** is a comptime slice of the field names, iterated at run time.
- **Generics in use:** `Stack(u32)` and `Stack([]const u8)` from one function, their type names printed by `@typeName` (the compiler names them after the call that made them); a `RingBuffer(u8, 4)` that keeps the last four bytes of `"abcde"`; and `Matrix(2, 3)` times its transpose, printed with `{f}`, which calls `Matrix.format`. The commented `a.mul(a)` is the line that would not compile.

### Code
`lecture_5/src/main.zig`, part 4:
```zig
// Reflection

const Level = enum { low, high };
const Server = struct {
    name: []const u8 = "default",
    port: u16 = 80,
    verbose: bool = false,
    level: Level = .low,
    ratio: f32 = 1.0,
};

fn demoReflection(out: *std.Io.Writer) !void {
    try out.writeAll("Reflection:\n");

    // A config parser written once: each "key = value" line sets the field of that name, parsed as
    // the field's type. Adding a field to Server is all it takes to accept a new key.
    var server: Server = .{};
    const config =
        \\name = api
        \\port = 8443
        \\verbose = true
        \\level = high
        \\ratio = 0.75
        \\colour = blue
        \\port = lots
    ;
    var lines = std.mem.splitScalar(u8, config, '\n');
    while (lines.next()) |line| {
        const key, const value = std.mem.cutScalar(u8, line, '=') orelse continue;
        reflect.setField(&server, std.mem.trim(u8, key, " "), std.mem.trim(u8, value, " ")) catch |err| {
            try out.print("    ignored '{s}': {t}\n", .{ line, err });
        };
    }
    try out.writeAll("    server = ");
    try reflect.printAny(out, server);
    try out.writeAll("\n");

    // A type described at compile time, and a nested value printed by walking its type.
    try out.print("    {s}\n", .{comptime reflect.describe(Server)});
    const Record = struct { id: u32, tags: []const []const u8, parent: ?*const @This(), status: union(enum) { ok, failed: []const u8 } };
    const root = Record{ .id = 1, .tags = &.{"root"}, .parent = null, .status = .ok };
    const child = Record{ .id = 2, .tags = &.{ "child", "leaf" }, .parent = &root, .status = .{ .failed = "timeout" } };
    try out.writeAll("    child = ");
    try reflect.printAny(out, child);
    try out.writeAll("\n");

    // The field names of any struct, as a comptime slice of strings.
    try out.writeAll("    Server's fields:");
    for (std.meta.fieldNames(Server)) |name| try out.print(" {s}", .{name});
    try out.writeAll("\n");
}

// Generic data structures

fn demoGenerics(gpa: std.mem.Allocator, out: *std.Io.Writer) !void {
    try out.writeAll("Generics:\n");

    // Stack(u32) and Stack([]const u8) are two different types made by one function.
    var numbers = try generic.Stack(u32).init(gpa, 2);
    defer numbers.deinit(gpa);
    for ([_]u32{ 3, 1, 4, 1, 5 }) |n| try numbers.push(gpa, n);
    var words = try generic.Stack([]const u8).init(gpa, 1);
    defer words.deinit(gpa);
    try words.push(gpa, "first");
    try words.push(gpa, "second");
    try out.print("    numbers: popped {?d} then {?d}, capacity grew to {d}; words: top is {?s}\n", .{ numbers.pop(), numbers.pop(), numbers.capacity(), words.peek() });
    try out.print("    {s} and {s} are {s} types\n", .{ @typeName(@TypeOf(numbers)), @typeName(@TypeOf(words)), if (@TypeOf(numbers) == @TypeOf(words)) "the same" else "different" });

    // A ring buffer of four: the fifth push overwrites the first.
    var recent: generic.RingBuffer(u8, 4) = .{};
    for ("abcde") |c| recent.push(c);
    try out.writeAll("    last four of \"abcde\": ");
    while (recent.pop()) |c| try out.writeByte(c);
    try out.writeAll("\n");

    // Matrices whose dimensions are types. {f} calls Matrix.format.
    const a = generic.Matrix(2, 3){ .data = .{ .{ 1, 2, 3 }, .{ 4, 5, 6 } } };
    const product = a.mul(a.transpose());
    try out.print("    a (2x3):\n{f}    a * transpose(a) ({d}x{d}):\n{f}", .{ a, @TypeOf(product).row_count, @TypeOf(product).col_count, product });
    try out.print("    identity(2):\n{f}", .{generic.Matrix(2, 2).identity()});
    // a.mul(a) is a compile error: "can't multiply a 2x3 matrix by a 2x3 one".
}

// The program

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    demoComptime();
    demoAnytype();
    try demoTables(init.gpa);
    try demoReflection(out);
    try demoGenerics(init.gpa, out);
}
```

## 5.8 Running it

### How
From `lecture_5/`, `zig build run`:
```text
comptime:
    max(u8, 3, 7) = 7; max(f64, 2.5, -1) = 2.5; max of two strings' lengths: 3
    the type chosen for this machine is u64; Int == u64: true
    the first 10 primes: { 2, 3, 5, 7, 11, 13, 17, 19, 23, 29 }
    sum of their squares, a constant: 2397
    integer widths and their maximums: u8=255 u16=65535 u24=16777215 u32=4294967295
anytype:
    sum of an array 6, a slice 3, a vector 4
    the vector sum is a f32
    total area of a circle and two squares: 16.142
Tables:
    'run' -> run
    'status' -> status
    'reboot' -> null
    counts: help=1 run=4 stop=0 status=0
    decode_table['A'..'F'] = { 0, 1, 2, 3, 4, 5 }, ['0'] = 52, ['!'] = 0xff
    'comptime' -> Y29tcHRpbWU= -> comptime
Reflection:
    ignored 'colour = blue': UnknownField
    ignored 'port = lots': InvalidValue
    server = { .name = "api", .port = 8443, .verbose = true, .level = .high, .ratio = 0.75 }
    main.Server: struct of 5 fields (name: []const u8, port: u16, verbose: bool, level: main.Level, ratio: f32)
    child = { .id = 2, .tags = ["child", "leaf"], .parent = { .id = 1, .tags = ["root"], .parent = null, .status = .{ .ok = {} } }, .status = .{ .failed = "timeout" } }
    Server's fields: name port verbose level ratio
Generics:
    numbers: popped 5 then 1, capacity grew to 8; words: top is second
    generic.Stack(u32) and generic.Stack([]const u8) are different types
    last four of "abcde": bcde
    a (2x3):
[  1.00,   2.00,   3.00 ]
[  4.00,   5.00,   6.00 ]
    a * transpose(a) (2x2):
[ 14.00,  32.00 ]
[ 32.00,  77.00 ]
    identity(2):
[  1.00,   0.00 ]
[  0.00,   1.00 ]
```
`zig build test` runs the thirteen tests across the three files (plus the discovery block). The experiments this time are compile errors, which is the point of the lecture: uncomment `a.mul(a)` and read the message with the dimensions in it; call `generic.Matrix(2, 3).identity()` and see the lazy declaration's error appear only then; add a field of type `u32` with a `?` in front of it to `Server`, and `setField` parses `"null"` and numbers for it without a change; add a field of type `[4]u8`, and `parseAs` reports at compile time that it can't parse a `[4]u8`; pass `.{ Circle{ .radius = 1 }, 5 }` to `totalArea`, and `requireMethods` says `comptime_int is missing the method 'area'`.
