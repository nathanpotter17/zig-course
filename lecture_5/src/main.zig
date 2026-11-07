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
