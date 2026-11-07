const std = @import("std");
const BumpAllocator = @import("BumpAllocator.zig");

// A test build never calls main, so nothing in it would reach the allocator's file, and the compiler only
// analyzes (and only runs the tests of) files it reaches. This block imports the file so its tests are discovered.
test {
    _ = @import("BumpAllocator.zig");
}

// A type that says when it's set up and torn down

/// Zig has no destructors: nothing runs when a value goes out of scope. The convention is an `init`
/// that sets a value up and a `deinit` that tears it down, called by hand, usually through `defer`.
/// This one prints on both, so the output shows exactly when each happens.
const Tracer = struct {
    name: u8,

    fn init(name: u8) Tracer {
        std.debug.print("    [{c}] init\n", .{name});
        return .{ .name = name };
    }

    fn deinit(self: Tracer) void {
        std.debug.print("    [{c}] deinit\n", .{self.name});
    }
};

// Scopes and defer

fn demoScopes() void {
    std.debug.print("Scopes and defer:\n", .{});
    const a = Tracer.init('a');
    // defer runs its statement when the enclosing block ends, however it ends. Deferred statements
    // run last-in, first-out, so pairing each init with a defer deinit tears down in reverse order.
    defer a.deinit();
    {
        const b = Tracer.init('b');
        defer b.deinit();
        std.debug.print("    end of the inner block\n", .{});
    }
    std.debug.print("    end of the outer block\n", .{});
}

/// errdefer runs only when the block exits with an error. It's how a function that sets up two things
/// undoes the first when the second fails, without repeating the cleanup in every error path.
fn demoErrdefer(fail: bool) !void {
    const a = Tracer.init('x');
    errdefer a.deinit();
    if (fail) return error.SetupFailed;
    // On success, `a` belongs to the caller now (here we just drop it: that's a leak in real code).
}

// Copies and pointers

/// A struct copies by value: assignment copies every field, and a function parameter is a copy (or a
/// read-only reference, at the compiler's discretion; the function can't tell, since it can't write to it).
const Point = struct { x: i32, y: i32 };

fn demoCopies() void {
    std.debug.print("Copies:\n", .{});
    var p = Point{ .x = 1, .y = 2 };
    const q = p; // a copy: changing p leaves q alone
    p.x = 10;
    std.debug.print("    p = {any}, q = {any}\n", .{ p, q });

    // Arrays copy by value too, however large: `big2 = big1` copies 1024 bytes.
    var big1: [1024]u8 = @splat(1);
    const big2 = big1;
    big1[0] = 2;
    std.debug.print("    big1[0] = {d}, big2[0] = {d}\n", .{ big1[0], big2[0] });
}

/// Pointers share instead of copying. `*Point` can change what it points at, `*const Point` can only read.
fn moveRight(p: *Point, by: i32) void {
    p.x += by; // p.x is shorthand for p.*.x
}

fn demoPointers() void {
    std.debug.print("Pointers:\n", .{});
    var p = Point{ .x = 1, .y = 2 };
    // & takes the address. Its type is *Point because p is var; &constant gives *const T.
    const ptr = &p;
    moveRight(ptr, 5);
    moveRight(&p, 5); // the same thing, written inline
    std.debug.print("    p = {any} via {s}, address {*}\n", .{ ptr.*, @typeName(@TypeOf(ptr)), ptr });

    // A pointer to an array coerces to a slice, and a slice is a pointer plus a length.
    var numbers = [_]u32{ 10, 20, 30, 40 };
    const array_ptr: *[4]u32 = &numbers;
    const slice: []u32 = array_ptr;
    slice[0] = 11;
    std.debug.print("    slice.len = {d}, slice.ptr = {*}, numbers[0] = {d}\n", .{ slice.len, slice.ptr, numbers[0] });

    // A many-item pointer, [*]T, is a bare address with no length: it's what C calls a pointer. It
    // indexes and does arithmetic, and nothing checks the bounds. Slices know their length, so prefer them.
    var many: [*]const u32 = &numbers;
    many += 2;
    std.debug.print("    many[0] after += 2: {d}; &numbers[2] - &numbers[0] = {d} elements\n", .{ many[0], &numbers[2] - &numbers[0] });

    // A string literal is a pointer to a sentinel-terminated array: *const [5:0]u8, with a 0 after the
    // last byte, like a C string. std.mem.span finds the sentinel and makes a slice.
    const c_string: [*:0]const u8 = "hello";
    const as_slice = std.mem.span(c_string);
    std.debug.print("    {s} is {d} bytes, and byte {d} is the sentinel {d}\n", .{ as_slice, as_slice.len, as_slice.len, c_string[as_slice.len] });

    // Every pointer is an integer underneath. @intFromPtr reads it; {x} prints it.
    std.debug.print("    &numbers[1] - &numbers[0] in bytes: {d}\n", .{@intFromPtr(&numbers[1]) - @intFromPtr(&numbers[0])});
}

// Optionals

/// A pointer can't be null. A `?*T` can: it's a pointer or null, and the compiler makes every use say
/// which case it's handling. The null is address 0, so it costs nothing over a plain pointer.
fn findFirstEven(numbers: []u32) ?*u32 {
    // Capturing with |*n| gives a pointer to each element instead of a copy.
    for (numbers) |*n| {
        if (n.* % 2 == 0) return n;
    }
    return null;
}

fn demoOptionals() void {
    std.debug.print("Optionals:\n", .{});
    var numbers = [_]u32{ 7, 9, 12, 15 };

    // `if (optional) |value|` runs the block with the unwrapped value when it isn't null.
    if (findFirstEven(&numbers)) |n| {
        n.* += 100; // the pointer reaches back into the array
    }
    std.debug.print("    numbers = {any}\n", .{numbers});

    // `orelse` supplies a value for the null case, or diverts: `orelse return`, `orelse unreachable`.
    var odds = [_]u32{ 1, 3, 5 };
    const found = findFirstEven(&odds) orelse &odds[0];
    std.debug.print("    no even number; fell back to {d}\n", .{found.*});

    // `.?` asserts non-null: a safety-checked panic ("attempt to use null value") if it's wrong.
    const first: ?u32 = 42;
    std.debug.print("    first.? = {d}; an optional u32 takes {d} bytes, an optional pointer {d}\n", .{ first.?, @sizeOf(?u32), @sizeOf(?*u32) });
}

// Layout and alignment

/// The compiler may reorder a plain struct's fields to pack them. extern struct keeps C's order and
/// padding; packed struct is bits in an integer with no padding at all.
const Auto = struct { a: u8, b: u32, c: u8 };
const Extern = extern struct { a: u8, b: u32, c: u8 };
/// Three fields in one byte: a bool is one bit, a u2 two, a u5 five. The backing integer is spelled out
/// so the compiler checks that the fields add up to exactly 8 bits.
const Flags = packed struct(u8) {
    ready: bool,
    mode: u2,
    level: u5,
};

fn demoLayout() void {
    std.debug.print("Layout:\n", .{});
    std.debug.print("    struct {{ u8, u32, u8 }}: auto {d} bytes (align {d}), extern {d} bytes (align {d})\n", .{ @sizeOf(Auto), @alignOf(Auto), @sizeOf(Extern), @alignOf(Extern) });
    std.debug.print("    extern offsets a={d} b={d} c={d}; auto offsets a={d} b={d} c={d}\n", .{
        @offsetOf(Extern, "a"), @offsetOf(Extern, "b"), @offsetOf(Extern, "c"),
        @offsetOf(Auto, "a"),   @offsetOf(Auto, "b"),   @offsetOf(Auto, "c"),
    });

    const flags = Flags{ .ready = true, .mode = 2, .level = 17 };
    // @bitCast to the backing integer shows the bits: level in the top five, then mode, then ready.
    std.debug.print("    Flags {{ ready, mode=2, level=17 }} = 0b{b:0>8}, {d} byte; level starts at bit {d}\n", .{ @as(u8, @bitCast(flags)), @sizeOf(Flags), @bitOffsetOf(Flags, "level") });

    // `undefined` leaves memory uninitialized. Debug and safe builds fill it with 0xaa so that reading
    // it by mistake shows an obviously wrong value instead of a plausible one.
    var junk: u32 = undefined;
    _ = &junk; // tell the compiler we mean to read it
    std.debug.print("    an undefined u32 in a debug build: 0x{x}\n", .{junk});
    std.debug.print("    sizes: *u8 {d}, []u8 {d}, ?*u8 {d}, anyerror {d}\n", .{ @sizeOf(*u8), @sizeOf([]u8), @sizeOf(?*u8), @sizeOf(anyerror) });
}

// Allocators

/// A person whose name is a copy on the heap. The struct remembers nothing about where the memory
/// came from: whoever calls deinit passes the same allocator again. That's the convention in std.
const Person = struct {
    name: []u8,
    age: u8,

    /// Copies `name`, so the Person outlives whatever buffer the caller had it in.
    fn init(gpa: std.mem.Allocator, name: []const u8, age: u8) !Person {
        return .{ .name = try gpa.dupe(u8, name), .age = age };
    }

    fn deinit(self: Person, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
    }
};

/// Joins words with spaces into new memory. "Caller owns the returned memory" is the documentation
/// every such function carries, and the allocator parameter is the signal that it allocates.
fn joinWords(gpa: std.mem.Allocator, words: []const []const u8) ![]u8 {
    var total: usize = 0;
    for (words) |w| total += w.len + 1;
    const out = try gpa.alloc(u8, total);
    // If anything after this point failed, errdefer would free `out` so the error path doesn't leak.
    errdefer gpa.free(out);

    var pos: usize = 0;
    for (words) |w| {
        @memcpy(out[pos .. pos + w.len], w);
        out[pos + w.len] = ' ';
        pos += w.len + 1;
    }
    return out;
}

fn demoAllocators(gpa: std.mem.Allocator) !void {
    std.debug.print("Allocators:\n", .{});

    // create/destroy: one item. alloc/free: a slice of items. Both return error.OutOfMemory on failure,
    // which `try` passes up: allocation failure is an error like any other, never a crash.
    const n = try gpa.create(u32);
    defer gpa.destroy(n);
    n.* = 7;

    var items = try gpa.alloc(u32, 4);
    defer gpa.free(items);
    @memset(items, n.*);
    // realloc grows (or shrinks) a slice, moving it if it must. The old slice is invalid afterwards,
    // which is why the result is assigned back to the same variable.
    items = try gpa.realloc(items, 6);
    items[4] = 8;
    items[5] = 9;
    std.debug.print("    items = {any}\n", .{items});

    const sentence = try joinWords(gpa, &.{ "memory", "is", "explicit" });
    defer gpa.free(sentence);
    std.debug.print("    joined: '{s}'\n", .{sentence});

    var person = try Person.init(gpa, "Ada", 36);
    defer person.deinit(gpa);
    person.name[0] = 'a';
    std.debug.print("    person: {s}, {d}\n", .{ person.name, person.age });

    // An arena: allocate as often as you like, free everything with one deinit. Right for anything
    // with a natural end: a request, a frame, a compile. Nothing inside needs its own defer.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const scratch = arena.allocator();
    var total: usize = 0;
    for (0..100) |i| {
        const piece = try scratch.alloc(u8, i + 1);
        total += piece.len;
    }
    std.debug.print("    arena handed out {d} bytes in 100 allocations, freed by one deinit\n", .{total});

    // A fixed buffer: a stack array as the heap. It runs out, and says so.
    var stack_buffer: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&stack_buffer);
    const small = fba.allocator();
    _ = try small.alloc(u8, 60);
    const too_much = small.alloc(u8, 8);
    std.debug.print("    fixed buffer of 64 bytes, 60 used, asked for 8 more: {!any}\n", .{too_much});

    // The page allocator asks the operating system directly, in whole pages: for big buffers that
    // live long, or as the backing allocator of other allocators.
    const pages = try std.heap.page_allocator.alloc(u8, 1 << 20);
    defer std.heap.page_allocator.free(pages);
    std.debug.print("    page_allocator gave {d} KiB at an address that's a multiple of {d}\n", .{ pages.len / 1024, @as(usize, 1) << @as(u6, @intCast(@ctz(@intFromPtr(pages.ptr)))) });
}

/// The debug allocator tracks every allocation, and reports the ones not freed when it's torn down,
/// with the stack trace of where each was made. main's `init.gpa` does the same in debug builds.
fn demoLeakDetection() void {
    std.debug.print("Leak detection:\n", .{});
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa = debug_allocator.allocator();

    const kept = gpa.alloc(u8, 16) catch unreachable;
    gpa.free(kept);
    const forgotten = gpa.alloc(u8, 32) catch unreachable;
    _ = forgotten; // never freed, on purpose

    // deinit returns .leak if anything is still allocated, and logs each leak to stderr with a trace.
    const result = debug_allocator.deinit();
    std.debug.print("    deinit says: {t} (the trace above points at the alloc that was never freed)\n", .{result});
}

// Our own allocator

fn demoBumpAllocator(gpa: std.mem.Allocator) !void {
    std.debug.print("A bump allocator:\n", .{});
    // The bump allocator's buffer comes from the general-purpose allocator; it could be a stack array.
    const buffer = try gpa.alloc(u8, 256);
    defer gpa.free(buffer);

    var bump = BumpAllocator.init(buffer);
    const a = bump.allocator();

    // It works with everything in std that takes an Allocator: here std.fmt.allocPrint and a list.
    const greeting = try std.fmt.allocPrint(a, "{s}, {s}!", .{ "hello", "arena" });
    var list: std.ArrayList(u16) = .empty;
    for (0..10) |i| try list.append(a, @intCast(i * i));
    const doubled = try a.create(u64);
    doubled.* = 2 * list.items[9];
    std.debug.print("    '{s}', squares {any}, doubled {d}\n", .{ greeting, list.items, doubled.* });
    std.debug.print("    {d} allocations, {d} of {d} bytes used (peak {d}); the list grew in place, since it was the last allocation\n", .{ bump.allocations, bump.end, buffer.len, bump.peak });

    // Nothing to free one by one: reset forgets it all.
    bump.reset();
    std.debug.print("    after reset: {d} bytes used\n", .{bump.end});
}

// The program

pub fn main(init: std.process.Init) !void {
    demoScopes();
    std.debug.print("errdefer on failure:\n", .{});
    demoErrdefer(true) catch |err| std.debug.print("    caught {t}\n", .{err});
    std.debug.print("errdefer on success:\n", .{});
    try demoErrdefer(false);

    demoCopies();
    demoPointers();
    demoOptionals();
    demoLayout();

    // init.gpa is the process's general-purpose allocator: in debug and safe builds a checking
    // allocator that reports leaks at exit, in fast builds a fast one. Functions take it as a parameter.
    try demoAllocators(init.gpa);
    demoLeakDetection();
    try demoBumpAllocator(init.gpa);

    // std.log writes to stderr with a level and scope prefix, and can be filtered per scope at compile
    // time (see std.Options.log_level). std.debug.print is the raw form for quick debugging.
    std.log.info("done; std.process.Init is {d} bytes", .{@sizeOf(@TypeOf(init))});
}
