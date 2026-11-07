# Lecture 2: Memory, pointers and allocators

Lecture 1's program never allocated: every value lived on the stack or in the executable. This lecture is about everything else: where values live, how pointers reach them, how memory is asked for and given back, and what Zig does to catch the classic mistakes. It ends with our own allocator, a *bump allocator* that hands out slices of one buffer and frees them all at once, plugged into the standard library's `Allocator` interface so that every container in `std` can use it.

Zig's answer to memory is different from both C's and Rust's, and it's worth stating before the code:
- **No destructors, no RAII.** Nothing runs when a value goes out of scope. A type that owns something has an `init` and a `deinit`, and the caller pairs them with `defer`. That's a convention, not a language feature, so the compiler can't enforce it; the allocators can detect what's forgotten.
- **No default allocator.** C has `malloc`; Zig has an `Allocator` *interface*, and a function that needs memory takes one as a parameter. You can see from a signature whether a function allocates, choose how (an arena, a fixed buffer, a leak-checking allocator) at the call site, and swap the choice without touching the function.
- **Allocation failure is an error**, `error.OutOfMemory`, returned and handled like any other error, never a crash. Lecture 4 is about errors; `try` is all we need here.
- **Pointers can't be null**, and a pointer that may be null is a different type, `?*T`, that the compiler makes you check.
- **Illegal behavior is checked where it can be.** Reading past a slice, unwrapping a null, misaligning a pointer: debug and safe builds panic with a trace. What can't be checked (a dangling pointer to a dead stack frame) is on us, and the lecture says where those are.

The program is a sequence of small demonstrations, one per idea, in `lecture_2/src/main.zig`, with the allocator in its own file, `lecture_2/src/BumpAllocator.zig`. The build files are lecture 1's with the name changed.

## 2.1 Scopes, `defer` and `errdefer`

### Why
A function sets things up and must tear them down, in reverse order, on every path out: the normal return, an early return, an error. In C that's `goto cleanup`; in C++ and Rust, destructors do it silently. Zig's `defer` puts the teardown next to the setup, and the compiler runs it on every exit of the block.

### How
- **`Tracer`** is a struct with an `init` that prints and a `deinit` that prints, so the output shows exactly when each runs. Nothing about `deinit` is special: it's a method the program calls. (Lecture 1's `Machine` had an `init` and no `deinit`, because it owned nothing that needed releasing.)
- **`defer statement;`** registers the statement to run when the enclosing *block* exits, not the function: the inner block's `defer b.deinit()` runs at the inner `}`. Several `defer`s in one block run in reverse order (last in, first out), so `init`/`defer deinit` pairs nest correctly: `a` is set up first and torn down last.
- **`defer` runs however the block exits:** falling off the end, `return`, `break`, or an error propagating through `try`. The statement can be a block, `defer { ... }`, and it can't `return` or use `try` itself; lecture 1's `defer out.flush() catch {};` handled the error inline for that reason.
- **`errdefer statement;`** runs only when the block exits with an error. `demoErrdefer` creates a tracer and then may fail: on failure the `errdefer` tears the tracer down, and on success it doesn't, because a successful function hands its results to the caller, who owns them from then on. That's the pattern for a function that allocates two things: `errdefer free(first)` between the two allocations means a failed second allocation can't leak the first. `errdefer |err|` captures the error being returned, for logging.
- **`catch |err|`** on the call in `main` handles the error instead of propagating it: `demoErrdefer(true) catch |err| std.debug.print(...)`. `{t}` prints an error's name.
- **`std.debug.print`** writes to standard error, unbuffered, and can't fail. It's what to reach for while debugging, and what this lecture uses throughout so that the demonstrations need no writer.
- **The `test` block at the top** is about discovery, and it matters for every program with more than one file. The compiler analyzes only what it reaches: in a test build nothing calls `main`, so `main`'s use of `BumpAllocator` is never analyzed, the file is never looked at, and its tests would silently not run; `zig build test` would report success with zero tests. A `test` block in the root file that imports the other file is the standard way to make sure it's reached. (Lecture 7 looks at the build's test step more closely.)

### Code
`lecture_2/src/main.zig`, part 1:
```zig
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
```

## 2.2 Copies and pointers

### Why
A value in Zig is bytes, and assigning it copies the bytes: there are no moves, no copy constructors, no reference types. To share a value instead of copying it, or to let a function change the caller's variable, you pass its address. Zig has several pointer types, each saying exactly what's at the address: one item, many items, many items plus a length (a slice), or many items ending in a sentinel.

### How
- **Copies:** `const q = p;` copies the struct; `const big2 = big1;` copies all 1024 bytes of the array. Changing the original leaves the copy alone. Parameters are the same: a function receives a copy of its argument, or a read-only reference when the compiler decides that's faster, and it can't tell which, because parameters can't be assigned to.
- **`&p`** is the address of `p`, of type `*Point` when `p` is `var` and `*const Point` when it's `const`. A `*T` coerces to a `*const T`, never the other way.
- **`ptr.*`** dereferences. For struct fields and array elements, Zig does it for you: `p.x` through a pointer is `p.*.x`. `moveRight(p: *Point, ...)` changes the caller's point through the pointer, and the caller writes `&p`; lecture 1's `handle(self: *Machine, ...)` worked the same way, with `machine.handle(...)` taking the address automatically.
- **`{*}`** prints a pointer as its type and address; `@typeName(T)` is a type's name as a string, and `@TypeOf(x)` the type of an expression.
- **The pointer types:**
  - `*T`: exactly one `T`. Dereference with `.*`; no indexing, no arithmetic.
  - `*[N]T`: a pointer to an array of N, which is what `&numbers` gives. It knows its length, indexes, and *coerces to a slice*: `const slice: []u32 = array_ptr;`.
  - `[]T`: a *slice*: a pointer plus a length, 16 bytes on a 64-bit machine. `slice.ptr` is the pointer (a `[*]T`), `slice.len` the length. Indexing is bounds-checked in debug and safe builds. Slices are how Zig passes arrays around, and lecture 3 is about them.
  - `[*]T`: a *many-item pointer*: an address with no length, which is what a C pointer is. It indexes, slices (`many[0..3]`) and does arithmetic (`many += 2`), and nothing checks any of it. Zig code uses it at the boundary with C and inside allocators, and slices everywhere else. Subtracting two pointers gives the distance in elements.
  - `[*:0]const u8`: a many-item pointer whose end is marked by a 0 byte: a C string. A string literal is a `*const [5:0]u8`, a pointer to an array with a sentinel, so it coerces to this. `std.mem.span` walks to the sentinel and returns a slice; the sentinel itself can be read, `c_string[5]`, where a plain slice would panic.
- **`@intFromPtr`** turns a pointer into a `usize` (and `@ptrFromInt` back), for arithmetic and for printing addresses. Consecutive `u32`s are 4 bytes apart.

### Code
`lecture_2/src/main.zig`, part 2:
```zig
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
```

## 2.3 Optionals

### Why
Null pointers are the single most common cause of crashes in C programs. Zig's pointers are never null. When "no value" is a real possibility, the type says so with a `?`, and the compiler refuses to let the value be used until the null case has been handled.

### How
- **`?T`** is an *optional*: a `T` or `null`. `?*u32` is an optional pointer; `?u32` an optional integer. `null` has its own type and coerces to any optional.
- **Three ways to unwrap:**
  - `if (opt) |value| { ... }` runs the block with the payload when it's not null, and may have an `else`. `while (opt) |value|` does the same per iteration (lecture 3).
  - `opt orelse fallback` is the value, or the fallback. The fallback can diverge: `orelse return null`, `orelse return error.NotFound`, `orelse unreachable`.
  - `opt.?` asserts it isn't null, and panics with "attempt to use null value" in debug and safe builds if it is. Use it where the code has already established the fact.
- **Capturing a pointer:** `for (numbers) |*n|` gives a pointer to each element instead of a copy, so `n.* % 2` reads the element and `return n` hands out its address. `findFirstEven` returns `?*u32`: a pointer into the caller's array, or null.
- **No cost:** an optional pointer is the same size as a pointer, because address 0 is the null. An optional integer needs an extra byte for the flag, rounded up to alignment: `?u32` is 8 bytes.
- **Lifetime:** the pointer `findFirstEven` returns is only valid as long as the array it points into. That's the caller's responsibility, and the lecture returns to it in 2.5.

### Code
`lecture_2/src/main.zig`, part 3:
```zig
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
```

## 2.4 Layout and alignment

### Why
Memory is bytes, and a type is a rule for reading them. How a struct's fields are placed decides how big it is, whether it can be shared with C, and whether it can be read from a file or a network packet as it is. Zig gives three layouts and makes each one's rules explicit.

### How
- **Alignment:** every type has an alignment, a power of two such that values of the type live at addresses divisible by it: 4 for `u32`, 8 for `u64` and pointers, 1 for `u8`. `@alignOf(T)` reports it. A struct's alignment is its largest field's, and its size is a multiple of that, so a `u8` after a `u32` is followed by padding.
- **Three layouts:**
  - A plain `struct` has no defined layout: the compiler may reorder fields to reduce padding. `struct { a: u8, b: u32, c: u8 }` becomes 8 bytes, with `b` first and `a`, `c` packed after it (the offsets show it). Field order in memory is not source order, so don't read one from a byte buffer.
  - `extern struct` has C's layout: fields in order, padded to their alignment. The same three fields take 12 bytes, like in C. This is the layout for anything shared with C or read from a binary format (lecture 9).
  - `packed struct` is bits in an integer, with no padding: `Flags` has a 1-bit `bool`, a `u2` and a `u5`, 8 bits in all, and `packed struct(u8)` names the *backing integer*, so the compiler checks the fields add up to exactly 8 bits. Fields are placed from the least significant bit up, and `@bitOffsetOf` tells where. `@bitCast` to and from the backing integer reinterprets the bits, which is how a hardware register or a file header's flag byte is read.
- **`@sizeOf`, `@alignOf`, `@offsetOf(T, "field")`, `@bitOffsetOf`** are all compile-time constants, so they can size buffers and check assumptions in `comptime` blocks.
- **`undefined`** leaves a variable uninitialized. In debug and safe builds the compiler fills it with `0xaa` bytes, so a mistaken read shows `0xaaaaaaaa`, a value that's obviously wrong, instead of whatever happened to be there. In fast builds it's really undefined. `_ = &junk;` is how the program tells the compiler that it means to read the variable, which the compiler would otherwise flag as never written.
- **Sizes worth knowing:** a pointer is 8 bytes, a slice 16, an optional pointer 8, and an error (lecture 4) is a `u16`.

### Code
`lecture_2/src/main.zig`, part 4:
```zig
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
```

## 2.5 Where the bytes are: the stack, the heap and allocators

### Why
Every value needs a home. Locals live in the function's stack frame, which disappears when the function returns; constants live in the executable; and anything whose size isn't known until the program runs, or that must outlive the function that made it, lives on the heap. The heap is reached only through an allocator, and Zig makes the choice of allocator part of the function's signature.

### How
- **Three places:**
  - **The global data section:** string literals, `const` values known at compile time, and top-level `var`s. They exist for the whole run.
  - **The stack:** every local `var` and `const` and every parameter, in a frame that's freed when the function returns. Fast and automatic, and the reason `return &local;` is a bug: the compiler accepts it, and the address points at a frame that no longer exists. Reading it is *unchecked* illegal behavior: not a panic, but whatever bytes are there now. Return the value instead, or allocate.
  - **The heap:** memory handed out by an allocator, and kept until that allocator frees it. Its size can be decided at run time, and it can be returned from the function that made it.
- **`std.mem.Allocator`** is an interface, a struct of a pointer and a table of functions (2.7 builds one). Every allocator in `std` produces one with an `.allocator()` method, and every function that allocates takes one:
  - `create(T)` and `destroy(ptr)`: one item.
  - `alloc(T, n)` and `free(slice)`: a slice of `n` items. `alignedAlloc` for a stricter alignment.
  - `realloc(slice, n)`: a different length, moving the memory if it must, so the old slice is dead and the result replaces it. `resize` tries in place and reports whether it could.
  - `dupe(T, slice)`: a copy of a slice in new memory.
  - All of them return `error.OutOfMemory` when they fail; `try` passes it up. `@memset` fills a slice with a value and `@memcpy` copies one slice into another of the same length.
- **Ownership is documentation.** `joinWords` returns memory the *caller owns*: the caller must `free` it with the same allocator. `Person.init` copies its name with `dupe` so the `Person` doesn't depend on the caller's buffer, and `Person.deinit(gpa)` takes the allocator again, because the struct doesn't store it. That's the standard library's convention: containers don't remember their allocator; every call that may allocate or free takes it. The `errdefer gpa.free(out)` in `joinWords` does nothing today, since nothing after the allocation can fail, and it's there so that a `try` added later can't leak.
- **Choosing an allocator** (the language reference has a flowchart; this is it):
  - `init.gpa`, the general-purpose allocator `main` receives: a checking allocator that reports leaks at exit in debug and safe builds, a fast thread-safe one (`std.heap.smp_allocator`) in fast builds. For a program with a start and an end that frees what it allocates. `init.arena` is an arena backed by it, freed at exit, for things that live as long as the process.
  - `std.heap.ArenaAllocator.init(child)`: allocates from a child allocator in chunks, and `deinit` frees everything at once. Nothing inside needs its own `free`. The right tool for work with a natural end: a request, a frame, a parse. The 100 allocations in the demo cost one `deinit`.
  - `std.heap.FixedBufferAllocator.init(&buffer)`: carves a buffer you supply, often a stack array. When it's full, `alloc` returns `error.OutOfMemory`: `{!any}` prints an error union as the value or the error.
  - `std.heap.page_allocator`: asks the operating system directly, in whole pages (4 KiB here, so the address is at least page-aligned; the demo shows the alignment it actually got). For large, long-lived buffers, or as the child of an arena.
  - `std.heap.c_allocator`: `malloc`, when the program links libc anyway (lecture 9).
  - `std.testing.allocator`: in tests. It fails the test on a leak, and 2.7 uses it.
  - A library takes an `Allocator` parameter and never picks.

### Code
`lecture_2/src/main.zig`, part 5:
```zig
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
```

## 2.6 Leak detection

### Why
Without destructors, a forgotten `free` is a leak the compiler can't see. What it can do is make the allocator see it: a checking allocator records every allocation with the stack trace of where it was made, and reports the ones still alive when it's torn down.

### How
- **`std.heap.DebugAllocator(.{})`** is a function that takes a configuration struct and returns an allocator *type*; `.init` is its starting value (the `.{}` takes every default). It's what `init.gpa` is in debug and safe builds, here created by hand so the demo can tear it down early.
- **`deinit()`** returns `.leak` if anything is still allocated, and logs each leak to standard error: the address, the size, and the stack trace of the `alloc` call. The demo frees one allocation and forgets another on purpose, and the trace points at the line of the forgotten one. In a real program, the same report appears at exit for anything leaked through `init.gpa`.
- **`catch unreachable`** says "this can't fail": if it does, it's a safety-checked panic. The demo uses it because handling `OutOfMemory` would be noise here; `try` is the normal choice.
- **The other checks:** the debug allocator also detects a double free, a free with the wrong size, and (with `.safety`, on by default in debug) a write past the end of an allocation, each with a trace. `std.testing.allocator` is the same allocator, and a test that leaks fails.

### Code
`lecture_2/src/main.zig`, part 6:
```zig
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
```

## 2.7 Writing an allocator

### Why
The `Allocator` interface is small enough to implement in a page, and doing so shows how Zig does interfaces without classes: a pointer to the implementation's state, erased to `*anyopaque`, and a table of function pointers that know how to cast it back. The bump allocator is also useful in itself: it's the fastest allocator there is (an addition and a comparison), and the right one for memory that's all freed at the same moment.

### How
- **A file is a struct.** `BumpAllocator.zig` has field declarations at its top level, `buffer: []u8,` and the rest, and no `struct { }` around them. That's because every Zig source file *is* a struct: the compiler treats the file's contents as if wrapped in `struct { ... }`, so top-level fields are the struct's fields, top-level `fn`s are its methods, and `@import("BumpAllocator.zig")` evaluates to the type. `const BumpAllocator = @This();` gives the type a name inside its own file. This file could equally be written as
  ```zig
  pub const BumpAllocator = struct {
      buffer: []u8,
      end: usize = 0,
      // ...
      pub fn init(buffer: []u8) BumpAllocator { ... }
  };
  ```
  inside `main.zig`; the two are the same type with the same behaviour. The one-type-per-file form is the standard library's convention for its bigger types (`std.heap.FixedBufferAllocator` and `std.Io.Writer` are files like this), and the file is named in TitleCase to signal it. `main.zig` has no fields, so it's a struct with only declarations: a namespace.
- **The state:** the buffer (borrowed: the allocator doesn't free it), the number of bytes handed out so far (`end`), and two counters for the demo. Default values on the fields mean `init` only has to set the buffer.
- **`allocator()`** builds the interface value: `.ptr = self` erases `*BumpAllocator` to `*anyopaque` (a pointer to something of unknown type), and `.vtable = &.{ ... }` points at a table of our four functions. The table is a compile-time constant, so `&` of the literal is a pointer into the executable's data, valid forever.
- **The four functions** have the signatures the `VTable` demands, which is why their parameters are the raw `len`, `alignment`, `ret_addr` rather than types:
  - `alloc` returns a `?[*]u8`: the start of `len` bytes at a suitably aligned address, or `null` when out of memory. The `Allocator` methods turn the `null` into `error.OutOfMemory` and the `[*]u8` into a typed slice or pointer. `alignment.forward(address)` rounds up to the next multiple; the result's offset from the buffer's start is where the allocation begins.
  - `resize` changes a length without moving: shrinking is always possible, growing only for the most recent allocation (nothing is after it), and only if the buffer has room. `remap` may move, but a bump allocator has nowhere to move to, so it's `resize` or `null`.
  - `free` can only give back the most recent allocation; anything else stays used until `reset`. A real arena would keep a free list; this one trades that for speed and simplicity.
- **`@ptrCast(@alignCast(ctx))`** undoes the erasure: `@alignCast` asserts the address is aligned enough for a `BumpAllocator` (checked in debug builds), and `@ptrCast` changes the pointer type. The result type comes from the declaration, `const self: *BumpAllocator = ...`.
- **`ret_addr`** is the return address of the allocating call, which a checking allocator records for its traces. We ignore it, and `_ = ret_addr;` says so.
- **The tests:**
  - Two allocations land where the arithmetic says: the `u32` skips a byte to reach a multiple of 4. `std.testing.expectEqual` on two pointers compares addresses.
  - The last allocation grows in place and the earlier one can't, and freeing the last one gives its bytes back.
  - Running out returns `error.OutOfMemory`, and `std.testing.expectError(error.OutOfMemory, expr)` checks for exactly that error; `reset` makes the space available again.
  - `std.heap.testAllocator` and `testAllocatorAligned` are the standard library's own allocator conformance tests, run against every allocator in `std`. Passing them means our allocator can back any `std` container. The backing buffer comes from `std.testing.allocator`, so forgetting the `defer free` would fail the test.

### Code
`lecture_2/src/BumpAllocator.zig`:
```zig
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
```

## 2.8 Using it, and the program

### Why
An allocator that only our code could use would be a toy. Because `BumpAllocator` is a `std.mem.Allocator`, `std.fmt.allocPrint` and `std.ArrayList` use it without knowing, and the demo watches the counters to see what they asked for.

### How
- **`std.fmt.allocPrint(allocator, fmt, args)`** formats into memory the allocator provides, one allocation. **`std.ArrayList(u16)`** is a growable array (lecture 3); `.empty` is a list with nothing in it, and `append(allocator, item)` takes the allocator on every call, as 2.5 described. The list's first append allocates room for several items, and when it runs out, it asks to *resize*; since the list's buffer is the most recent allocation, our `resize` grows it in place, so the demo ends with 3 allocations rather than one per growth. The `u64` is 8-byte aligned, so `alloc` skips to a multiple of 8 for it.
- **`bump.reset()`** forgets everything at once. Nothing was `free`d individually, and nothing needs to be: the greeting, the list and the `u64` were all released by one assignment. The buffer itself goes back to `init.gpa` at the `defer`.
- **The tests live in the allocator's file**, and `zig build test` finds them because of the `test { _ = @import("BumpAllocator.zig"); }` block at the top of `main.zig` (2.1): tests are discovered through what the root file's analysis reaches, and in a test build that doesn't include `main`. Without the block, the four tests would be skipped without a word.
- **`main`** calls each demo in turn, passing `init.gpa` to the ones that allocate. `std.log.info` is the standard library's logging: a level (`err`, `warn`, `info`, `debug`), a scope, a format string, and output to standard error prefixed with `info: `. Logging can be filtered at compile time by level and scope through `std_options` in the root file, and a message below the threshold costs nothing.
- **Debugging with a debugger.** Debug builds carry full debug information, so `gdb` and `lldb` work as they do on C: `gdb zig-out/bin/lecture_2`, `break main.demoPointers` (Zig functions are namespaced by file), `run`, `next`, `step`, `print p` shows the struct with its field names, `print *ptr` dereferences, `finish`. A few things the program can do for itself: `@breakpoint()` stops a debugger at that line; `std.debug.dumpCurrentStackTrace(.{})` prints the call stack; and every safety panic already prints a trace with file and line, which in practice answers most questions. `zig build -Doptimize=safe` keeps the checks with optimization on; `fast` removes them, and a bug that was a clean panic becomes silent corruption, so debug it in debug.

### Code
`lecture_2/src/main.zig`, part 7:
```zig
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
```

## 2.9 Running it

### How
`lecture_2/build.zig` and `build.zig.zon` are lecture 1's with `lecture_1` replaced by `lecture_2` (and the fingerprint the first build suggests). From `lecture_2/`:
```bash
zig build run
```
```text
Scopes and defer:
    [a] init
    [b] init
    end of the inner block
    [b] deinit
    end of the outer block
    [a] deinit
errdefer on failure:
    [x] init
    [x] deinit
    caught SetupFailed
errdefer on success:
    [x] init
Copies:
    p = .{ .x = 10, .y = 2 }, q = .{ .x = 1, .y = 2 }
    big1[0] = 2, big2[0] = 1
Pointers:
    p = .{ .x = 11, .y = 2 } via *main.Point, address main.Point@7ffd7474a110
    slice.len = 4, slice.ptr = u32@7ffd7474a118, numbers[0] = 11
    many[0] after += 2: 30; &numbers[2] - &numbers[0] = 2 elements
    hello is 5 bytes, and byte 5 is the sentinel 0
    &numbers[1] - &numbers[0] in bytes: 4
Optionals:
    numbers = { 7, 9, 112, 15 }
    no even number; fell back to 1
    first.? = 42; an optional u32 takes 8 bytes, an optional pointer 8
Layout:
    struct { u8, u32, u8 }: auto 8 bytes (align 4), extern 12 bytes (align 4)
    extern offsets a=0 b=4 c=8; auto offsets a=4 b=0 c=5
    Flags { ready, mode=2, level=17 } = 0b10001101, 1 byte; level starts at bit 3
    an undefined u32 in a debug build: 0xaaaaaaaa
    sizes: *u8 8, []u8 16, ?*u8 8, anyerror 2
Allocators:
    items = { 7, 7, 7, 7, 8, 9 }
    joined: 'memory is explicit '
    person: ada, 36
    arena handed out 5050 bytes in 100 allocations, freed by one deinit
    fixed buffer of 64 bytes, 60 used, asked for 8 more: error.OutOfMemory
    page_allocator gave 1024 KiB at an address that's a multiple of 65536
Leak detection:
error(DebugAllocator): memory address 0x7806b7c40000 leaked:
/home/.../lecture_2/src/main.zig:270:32: 0x1216b9a in demoLeakDetection (main.zig)
    const forgotten = gpa.alloc(u8, 32) catch unreachable;
                               ^
...
    deinit says: leak (the trace above points at the alloc that was never freed)
A bump allocator:
    'hello, arena!', squares { 0, 1, 4, 9, 16, 25, 36, 49, 64, 81 }, doubled 162
    3 allocations, 152 of 256 bytes used (peak 152); the list grew in place, since it was the last allocation
    after reset: 0 bytes used
info: done; std.process.Init is 80 bytes
```
The addresses change from run to run. `zig build test` runs the four allocator tests (five, counting the discovery block, which is itself a test), and `zig build run -Doptimize=fast` shows what the optimization modes trade: the `undefined` line prints `0x0` (whatever was there; nothing filled it), and `deinit says: ok`, because the debug allocator's bookkeeping follows the build's safety setting, so the leak goes unreported. Leak checking is a debug-build tool; run the debug build before shipping the fast one.

Two experiments: remove `defer gpa.free(sentence);` in `demoAllocators`, and `init.gpa` reports the leak at exit with a trace to `joinWords`. And in `BumpAllocator.alloc`, replace `alignment.forward(base + self.end) - base` with `self.end`, ignoring alignment: the first test fails on the `u32`'s address, and `testAllocatorAligned` fails on its first aligned request. The interface's contract is what the tests check.
