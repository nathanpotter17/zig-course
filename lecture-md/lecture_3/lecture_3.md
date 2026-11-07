# Lecture 3: Contiguous data

By the end of this lecture we'll have Conway's Game of Life running on a wrapping board: a glider crossing it, and the R-pentomino's population counted generation by generation. Life is a program about contiguous memory: a grid is one slice of bytes, every generation reads a neighbourhood of it, and rendering turns bytes into text. Before the board, the program tours the ways Zig lays out and names runs of memory:
- **Arrays**, `[N]T`, whose length is part of the type and known at compile time, so they copy by value and can be built while compiling.
- **Slices**, `[]T`, a pointer and a runtime length, which every function takes so that it works on an array, part of an array, or heap memory alike.
- **Strings**, which are slices of bytes, `[]const u8`, with UTF-8 as the convention and `std.mem` as the toolbox: there's no string type, and no hidden allocation when you compare, split or trim.
- **`std.ArrayList`**, the growable array, and the standard library's convention that a container doesn't remember its allocator.
- **Vectors**, `@Vector(N, T)`, fixed-length groups of numbers that the CPU operates on at once.

The program is `lecture_3/src/main.zig`, plus a pattern file it embeds at compile time. The build files are lecture 1's with the name changed.

## 3.1 Arrays

### Why
An array is the simplest run of memory: N values of one type, next to each other, with N fixed when the program is compiled. Because the length is part of the type, the compiler knows exactly how big every array is, which is what lets it copy them, compare them, index them safely, and build them at compile time.

### How
- **`[4]u8`** is the type of four bytes. `[_]u8{ 3, 1, 4, 1 }` asks the compiler to count. `@splat(0)` fills an array with one value, taking the length from the result type (`const zeros: [4]u8 = @splat(0)`), as it did for `Machine.stock` in lecture 1. `.len` is a compile-time constant.
- **`++`** concatenates two arrays into a new one whose length is the sum; it only works at compile time, because the result's length is a type. It's how string literals are joined: `"hello" ++ " " ++ "world"`.
- **Arrays are values.** `var copy = counts;` copies the four bytes; changing the copy doesn't touch the original. A function can take or return an array by value. `std.meta.eql` compares two values of any type element by element (`==` works on arrays only when both are comptime-known).
- **Destructuring:** `const first, const second, _, _ = counts;` takes an array apart into constants, with `_` for the elements to skip. It works on tuples and vectors too.
- **Multidimensional arrays** are arrays of arrays: `[2][3]u8` is two rows of three, laid out row after row, 6 bytes. `grid[1][2]` indexes the outer array then the inner; `.{ 1, 2, 3 }` builds an inner row where the type is known.
- **Compile-time initialization:** a labeled block that fills an array and `break`s it out runs at compile time when the inputs are compile-time known, so `squares` costs nothing at run time: the executable holds the finished table. `for (&table, 0..) |*slot, i|` iterates the array by pointer, with the index alongside, so each slot can be assigned.

### Code
`lecture_3/src/main.zig`, part 1:
```zig
const std = @import("std");

// Arrays

fn demoArrays() void {
    std.debug.print("Arrays:\n", .{});
    // An array's length is part of its type: [4]u8 and [5]u8 are different types. [_] asks the
    // compiler to count the elements.
    const counts = [_]u8{ 3, 1, 4, 1 };
    const zeros: [4]u8 = @splat(0);
    std.debug.print("    {s} of {d}: {any}; zeros {any}\n", .{ @typeName(@TypeOf(counts)), counts.len, counts, zeros });

    // ++ concatenates two arrays, at compile time only, since the result's length is part of its type.
    const twice = counts ++ [_]u8{ 5, 9 };
    std.debug.print("    counts ++ {{5, 9}} = {any}, a {s}\n", .{ twice, @typeName(@TypeOf(twice)) });

    // Arrays are values: assignment copies, == compares every element, and a function returns one by value.
    var copy = counts;
    copy[0] = 9;
    std.debug.print("    copy {any} == counts {any}? {}\n", .{ copy, counts, std.meta.eql(copy, counts) });

    // Destructuring takes an array apart; `_` skips an element.
    const first, const second, _, _ = counts;
    std.debug.print("    first {d}, second {d}\n", .{ first, second });

    // A two-dimensional array is an array of arrays, laid out row after row.
    const grid = [2][3]u8{
        .{ 1, 2, 3 },
        .{ 4, 5, 6 },
    };
    std.debug.print("    grid[1][2] = {d}; rows of {d}, {d} bytes in all\n", .{ grid[1][2], grid[0].len, @sizeOf(@TypeOf(grid)) });

    // An array can be computed at compile time in a labeled block: this one runs while compiling,
    // and the program only holds the result.
    const squares = blk: {
        var table: [8]u16 = undefined;
        for (&table, 0..) |*slot, i| slot.* = @intCast(i * i);
        break :blk table;
    };
    std.debug.print("    squares, built at compile time: {any}\n", .{squares});
}
```

## 3.2 Slices

### Why
A function that took a `[4]u32` would only accept arrays of exactly four. A *slice* is a pointer plus a length decided at run time, so one `sum` works on any array, any part of one, and anything an allocator returned. Slices are how Zig passes data around, and because they carry their length, every index into one is checked.

### How
- **`[]const u32`** is a slice of integers the function won't write; `[]u32` is one it may. The `const` is part of the type, and a `[]u32` coerces to a `[]const u32`, not the reverse.
- **Making slices:** `&numbers` (a `*[6]u32`) coerces to `[]u32`. `numbers[2..4]` is elements 2 and 3 (the end is excluded), `numbers[start..]` runs to the end. `slice.len` and `slice.ptr` are its two fields.
- **Comptime versus runtime bounds:** `numbers[2..4]` with literal bounds is a `*[2]u32`, a pointer to an array, because the compiler can compute the length; it still coerces to a slice when a function wants one. `numbers[start..]` with a runtime `start` is a `[]u32`. The `_ = &start;` line exists only to make `start` runtime-known for the demonstration; otherwise the compiler would notice it never changes and complain that it should be `const`.
- **Slicing by length:** `numbers[start..][0..3]` is the idiom for "3 elements from `start`": a runtime start, then a comptime length, giving a `*[3]u32` whose length the compiler knows. The language reference recommends it over `[start .. start + 3]`.
- **Iterating by pointer:** `for (values) |*v| v.* *= 2;` captures a pointer to each element so the loop can change it. `double(three)` changes elements 1 to 3 of `numbers` through the pointer.
- **Several things at once:** `for (names, numbers[0..3], 0..) |name, n, i|` walks two slices and a counter in step. The slices must have the same length, and the mismatch is a safety-checked panic in debug builds, not silent truncation.
- **`for` is an expression:** `break value` ends the loop with a value, and `else` gives the value when the loop runs to the end without breaking. `first_big` is the first element over 7, or 0.
- **Bounds checks:** `numbers[6]` in a debug or safe build panics with `index out of bounds: index 6, len 6` and a trace. In a fast build it reads whatever follows, as C would. The check is what the length buys.

### Code
`lecture_3/src/main.zig`, part 2:
```zig
// Slices

/// A slice is a pointer and a length, so a function taking one accepts any array, any part of an array,
/// or anything the allocator returned. `[]const u8` promises not to write through it.
fn sum(values: []const u32) u32 {
    var total: u32 = 0;
    for (values) |v| total += v;
    return total;
}

/// Writes through the slice: the caller's elements change.
fn double(values: []u32) void {
    // |*v| captures a pointer to each element instead of a copy.
    for (values) |*v| v.* *= 2;
}

fn demoSlices() void {
    std.debug.print("Slices:\n", .{});
    var numbers = [_]u32{ 1, 2, 3, 4, 5, 6 };

    // &array coerces to a slice. Slicing with [start..end] excludes end; [start..] goes to the end.
    const all: []u32 = &numbers;
    const middle = numbers[2..4];
    std.debug.print("    sum(all) = {d}, sum(middle) = {d}, middle.len = {d}\n", .{ sum(all), sum(middle), middle.len });

    // With comptime-known bounds the result is a pointer to an array, *[2]u32, which still knows its
    // length at compile time. A runtime bound makes it a real slice.
    var start: usize = 1;
    _ = &start;
    const from_runtime = numbers[start..];
    std.debug.print("    numbers[2..4] is {s}; numbers[start..] is {s}\n", .{ @typeName(@TypeOf(middle)), @typeName(@TypeOf(from_runtime)) });

    // [a..][0..n] slices by length: a runtime start and a comptime length give a *[n]T again.
    const three = numbers[start..][0..3];
    double(three);
    std.debug.print("    after doubling three from {d}: {any}\n", .{ start, numbers });

    // A for over several slices walks them in step; they must be the same length, which is checked.
    // `0..` alongside gives the index.
    const names = [_][]const u8{ "one", "two", "three" };
    for (names, numbers[0..3], 0..) |name, n, i| {
        std.debug.print("    {d}: {s} = {d}\n", .{ i, name, n });
    }

    // for can have an else, which runs if the loop finished without a break; the whole thing is an expression.
    const first_big = for (numbers) |n| {
        if (n > 7) break n;
    } else 0;
    std.debug.print("    first value over 7: {d}\n", .{first_big});

    // Indexing is bounds-checked: numbers[6] panics with "index out of bounds: index 6, len 6" in
    // debug and safe builds, where C would read the next thing in memory.
}
```

## 3.3 Strings

### Why
Zig has no string type. A string is a `[]const u8`: bytes, by convention UTF-8, and everything one does with text is a function in `std.mem`, `std.ascii`, `std.fmt` or `std.unicode` that takes and returns slices. Nothing is copied or allocated unless the function's signature says so by taking an allocator. That takes getting used to after languages with a `String` class, and it's why Zig programs can process text without a single hidden allocation.

### How
- **Literals and bytes:** `"héllo, wörld"` is a `*const [14:0]u8`, 14 bytes for 12 characters, because `é` and `ö` are two bytes each in UTF-8. Indexing gives bytes: `greeting[1]` is the first byte of `é`, not a character. The literal coerces to `[]const u8`. Escapes are `\n`, `\t`, `\\`, `\"`, `\xNN` for a byte and `\u{...}` for a code point.
- **Code points:** `std.unicode.Utf8View.init` validates a slice as UTF-8 (returning an error if it isn't) and `.iterator()` walks it; `nextCodepoint()` returns a `?u21`, one code point at a time. `{u}` prints a code point as its character and `{X}` as hex. Most code never needs this: comparing, splitting and printing work on bytes and are correct for UTF-8 as long as the delimiters are ASCII.
- **`while (it.next()) |x| : (count += 1)`** is the iterator idiom: `next` returns an optional, the capture unwraps it, the loop ends at `null`, and the continue expression runs after each iteration.
- **Comparing and searching:** `==` on two slices compares the pointers, so equality is `std.mem.eql(u8, a, b)`. `std.mem.trim(u8, s, " ")` strips the given bytes from both ends; `startsWith`, `endsWith`, `find` (the position of a substring, as a `?usize`), `findScalar` (of one byte), `count`, `lessThan` and `order` are all there. `{?d}` prints an optional as its value or `null`.
- **Splitting:** `std.mem.cutScalar(u8, s, '=')` splits once at the first `=` into a tuple of the two sides, or `null`. `std.mem.splitScalar` and `tokenizeScalar` return iterators over every piece: `split` keeps empty pieces (`"a,,b"` gives three), `tokenize` skips them. `tokenizeAny` takes a set of delimiters. All of them return slices *into* the original string: no copies.
- **Parsing:** `std.fmt.parseInt(u32, text, 10)` returns the number or `error.InvalidCharacter` / `error.Overflow`. `parseFloat` likewise.
- **Building:** `std.fmt.bufPrint(&buf, fmt, args)` formats into a buffer you own and returns the slice it wrote (or `error.NoSpaceLeft`); `std.fmt.allocPrint(gpa, fmt, args)` allocates exactly enough and the caller frees. `std.ascii.allocUpperString` and `std.mem.join(gpa, sep, slices)` are the same shape: an allocator in, an owned slice out.
- **`std.Io.Writer.Allocating`** is a `Writer` that grows a heap buffer as it's written to: the same `print` as standard output, into memory. `.writer` is the interface, `.writer.buffered()` the bytes so far, `toOwnedSlice()` takes the buffer out, and `deinit` frees it. It's the modern string builder, used in the tests to capture `render`'s output.
- **Sorting:** `std.mem.sort(T, slice, context, lessThan)` sorts in place with a comparison function. The function is declared inline as a method of an anonymous struct, `struct { fn lessThan(...) }.lessThan`, which is Zig's way of writing a small function at the point of use (there are no closures). `std.sort.asc(T)` and `desc(T)` give the comparison for numbers.

### Code
`lecture_3/src/main.zig`, part 3:
```zig
// Strings

fn demoStrings(gpa: std.mem.Allocator) !void {
    std.debug.print("Strings:\n", .{});

    // A string is a []const u8: bytes, by convention UTF-8. A literal is a *const [N:0]u8, a pointer to
    // an array with a 0 after the end, and coerces to a slice. Zig has no string type beyond this.
    const greeting: []const u8 = "héllo, wörld";
    const ascii_only = std.ascii.isAscii(greeting[0]) and !std.ascii.isAscii(greeting[1]);
    std.debug.print("    '{s}' is {d} bytes; byte 0 is ASCII and byte 1 isn't: {}\n", .{ greeting, greeting.len, ascii_only });

    // Code points vs bytes: é is 2 bytes. Utf8View iterates code points; indexing the slice gives bytes.
    var it = (try std.unicode.Utf8View.init(greeting)).iterator();
    var code_points: usize = 0;
    while (it.nextCodepoint()) |cp| : (code_points += 1) {
        if (cp > 127) std.debug.print("    code point U+{X:0>4} ({u}) takes {d} bytes\n", .{ cp, cp, std.unicode.utf8CodepointSequenceLength(cp) catch unreachable });
    }
    std.debug.print("    {d} code points in {d} bytes\n", .{ code_points, greeting.len });

    // Comparing and searching: == on slices compares pointers, so std.mem has the functions.
    const line = "  name = Conway's Life  ";
    const trimmed = std.mem.trim(u8, line, " ");
    std.debug.print("    trimmed '{s}'; starts with 'name': {}; find(\"=\") = {?d}\n", .{ trimmed, std.mem.startsWith(u8, trimmed, "name"), std.mem.find(u8, trimmed, "=") });

    // cut splits at the first needle into a tuple of two slices, or null if it's missing.
    if (std.mem.cutScalar(u8, trimmed, '=')) |parts| {
        const key, const value = parts;
        std.debug.print("    key '{s}', value '{s}'\n", .{ std.mem.trim(u8, key, " "), std.mem.trim(u8, value, " ") });
    }

    // tokenize skips empty pieces (two spaces in a row give none); split keeps them. Both are iterators.
    var words = std.mem.tokenizeAny(u8, "3,  1, 4,1,,5", ", ");
    var total: u32 = 0;
    var count: usize = 0;
    while (words.next()) |word| : (count += 1) {
        // parseInt returns an error for text that isn't a number in the given base.
        total += try std.fmt.parseInt(u32, word, 10);
    }
    std.debug.print("    {d} numbers summing to {d}\n", .{ count, total });

    // Building strings: a fixed buffer with bufPrint, or the heap with allocPrint. Both return the slice written.
    var buf: [32]u8 = undefined;
    const fixed = try std.fmt.bufPrint(&buf, "{d} + {d} = {d}", .{ 2, 3, 5 });
    const upper = try std.ascii.allocUpperString(gpa, "shout");
    defer gpa.free(upper);
    const heap = try std.fmt.allocPrint(gpa, "{s}!", .{upper});
    defer gpa.free(heap);
    std.debug.print("    '{s}' in a stack buffer; '{s}' on the heap\n", .{ fixed, heap });

    // join and concat allocate a new slice from several. The caller owns the result.
    const joined = try std.mem.join(gpa, ", ", &.{ "cola", "chips", "candy" });
    defer gpa.free(joined);
    std.debug.print("    joined: {s}\n", .{joined});

    // An Allocating writer grows a buffer as it's written to: the same print() as stdout, into memory.
    var builder: std.Io.Writer.Allocating = .init(gpa);
    defer builder.deinit();
    for (0..5) |i| try builder.writer.print("{d}{s}", .{ i * i, if (i < 4) " " else "" });
    std.debug.print("    built: '{s}'\n", .{builder.writer.buffered()});

    // Sorting strings: std.mem.sort takes a less-than function; std.mem.lessThan compares lexicographically.
    var fruits = [_][]const u8{ "pear", "apple", "fig" };
    std.mem.sort([]const u8, &fruits, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    std.debug.print("    sorted: {s} {s} {s}\n", .{ fruits[0], fruits[1], fruits[2] });
}
```

## 3.4 `ArrayList`

### Why
An array can't grow and a slice doesn't own anything. `std.ArrayList(T)` is the growable array: a slice of items, a capacity, and the logic to reallocate when the capacity runs out. It's the most used container in Zig, and the model for how the others handle memory.

### How
- **`.empty`** is a list with no items and no buffer: declaring one allocates nothing. `std.ArrayList(u32)` is a type made by a function (lecture 5 writes one), and `.empty` is a constant declared inside it.
- **The allocator on every call.** `append(gpa, x)`, `appendSlice(gpa, ...)`, `insert(gpa, i, x)`, `ensureTotalCapacity(gpa, n)`, `toOwnedSlice(gpa)`, `deinit(gpa)` all take the allocator, and the list doesn't store it. That keeps the struct to three words (pointer, length, capacity), and makes it impossible to free with a different allocator than you allocated with, because you pass the same variable. (`std.ArrayList(T).Managed` is the variant that stores it, for when passing it around is a nuisance.)
- **`items`** is a slice into the list's buffer, of the current length: index it, pass it to functions, iterate it. It's valid until the next call that might grow the buffer, after which it may point at freed memory; take it again. `capacity` is how many fit before the next reallocation.
- **Removing:** `pop()` returns the last item as an optional (`null` when empty). `orderedRemove(i)` removes one and shifts the rest down; `swapRemove(i)` moves the last item into the hole instead, in constant time, when order doesn't matter.
- **Reserving:** `ensureTotalCapacity` reallocates once, and then `appendAssumeCapacity` can't fail and can't move the buffer, which is why it needs no `try` and no allocator. The demo checks that `items.ptr` didn't change across 100 appends.
- **`toOwnedSlice(gpa)`** shrinks the buffer to the exact length, hands it to the caller as a plain slice, and leaves the list empty. It's how a function builds a result in a list and returns a slice. The caller frees it with `gpa.free`.
- **`std.mem.sort(u32, owned, {}, std.sort.desc(u32))`** sorts in place; the `{}` is the empty context for a comparison that needs none.
- **A string builder:** `std.ArrayList(u8)` with `print(gpa, fmt, args)` appends formatted text; `items` is the string. `std.Io.Writer.Allocating` from 3.3 is the same idea behind a `Writer` interface.

### Code
`lecture_3/src/main.zig`, part 4:
```zig
// ArrayList

fn demoArrayList(gpa: std.mem.Allocator) !void {
    std.debug.print("ArrayList:\n", .{});
    // A growable array. It stores a slice (`items`) and a capacity, and takes the allocator on each
    // call that may grow or free, so the struct itself is just three words.
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(gpa);

    try list.append(gpa, 10);
    try list.appendSlice(gpa, &.{ 20, 30, 40 });
    try list.insert(gpa, 1, 15);
    std.debug.print("    items {any}, len {d}, capacity {d}\n", .{ list.items, list.items.len, list.capacity });

    // items is a slice into the list's buffer, valid until the next append might reallocate.
    double(list.items);
    const last = list.pop(); // ?u32: null when empty
    const removed = list.orderedRemove(1); // shifts the rest down; swapRemove moves the last one in instead
    std.debug.print("    popped {?d}, removed {d}, items {any}\n", .{ last, removed, list.items });

    // ensureTotalCapacity reserves once, so the appends in the loop can't fail or move the buffer.
    try list.ensureTotalCapacity(gpa, list.items.len + 100);
    const before = list.items.ptr;
    for (0..100) |i| list.appendAssumeCapacity(@intCast(i));
    std.debug.print("    100 appends without moving: {}\n", .{before == list.items.ptr});

    // toOwnedSlice hands the buffer over, sized exactly, and leaves the list empty.
    const owned = try list.toOwnedSlice(gpa);
    defer gpa.free(owned);
    std.mem.sort(u32, owned, {}, std.sort.desc(u32));
    std.debug.print("    owned slice of {d}, largest three {any}; list now has {d}\n", .{ owned.len, owned[0..3], list.items.len });

    // ArrayList(u8) doubles as a string builder, with print().
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.print(gpa, "{d} items", .{owned.len});
    std.debug.print("    text: '{s}'\n", .{text.items});
}
```

## 3.5 Vectors

### Why
Modern CPUs have instructions that add, compare or shuffle 16 or 32 numbers at once (SIMD: single instruction, multiple data). Most languages reach them through compiler intrinsics or hope the optimizer finds them. Zig has a vector type in the language: a fixed-length group of numbers on which the ordinary operators work element by element, compiled to SIMD instructions where the target has them and to loops where it doesn't.

### How
- **`@Vector(4, u32)`** is four `u32`s operated on together. `V{ 1, 2, 3, 4 }` builds one. Elements, bools, floats and pointers are allowed; the length is any comptime-known number, and small powers of two match the hardware.
- **Operators are element-wise:** `a * b + a` multiplies and adds all four lanes. A scalar can't mix with a vector; `@splat(10)` turns it into a vector of the result type first.
- **Comparisons** give a `@Vector(4, bool)`. **`@select(T, mask, a, b)`** picks each lane from `a` where the mask is true and `b` where it's false, which is how branches are written without branching: `clamped` caps every lane at 30. **`@reduce(.Add, v)`** folds a vector to one number (`.Add`, `.Mul`, `.Min`, `.Max`, and `.And`, `.Or`, `.Xor` for integers and bools). `@shuffle` rearranges lanes, and `v[i]` reads one.
- **Arrays and vectors convert both ways** when the length matches: `const array: [4]u32 = c;` and back. A slice becomes a vector through an array pointer of comptime length: `slice[0..16].*`. That's what `Board.population` does, 16 bytes at a time.

### Code
`lecture_3/src/main.zig`, part 5:
```zig
// Vectors

fn demoVectors() void {
    std.debug.print("Vectors:\n", .{});
    // @Vector(n, T) is n values operated on at once, with SIMD instructions where the CPU has them.
    // Operators work element-wise; a scalar has to be @splat into a vector first.
    const V = @Vector(4, u32);
    const a = V{ 1, 2, 3, 4 };
    const b: V = @splat(10);
    const c = a * b + a;
    std.debug.print("    a * 10 + a = {any}\n", .{c});

    // Comparisons give a vector of bools; @select picks per element; @reduce folds to one value.
    const big = c > @as(V, @splat(30));
    const clamped = @select(u32, big, @as(V, @splat(30)), c);
    std.debug.print("    > 30: {any}, clamped {any}, sum {d}, max {d}, any big? {}\n", .{ big, clamped, @reduce(.Add, c), @reduce(.Max, c), @reduce(.Or, big) });

    // Arrays and vectors convert both ways when the length is comptime-known.
    const array: [4]u32 = c;
    const back: V = array;
    std.debug.print("    as an array {any}, and back {any}\n", .{ array, back });
}
```

## 3.6 The board

### Why
A Life board is a grid of cells, each alive or dead, and a generation is computed from the previous one all at once: every cell looks at its eight neighbours in the *old* grid. So the board needs two buffers, and the edges need a rule; ours wrap around, so a glider that leaves on the right comes back on the left, and no cell is special.

### How
- **One slice for the grid.** `cells` is `width * height` bytes, row after row, so cell (x, y) is `cells[y * width + x]`. Bytes rather than bools, 1 and 0, so that counting neighbours is adding. `scratch` is the second buffer; `step` writes the next generation into it and then swaps the two with `std.mem.swap`, which exchanges two values through pointers. No copying.
- **`init` allocates both buffers.** If the second allocation fails, the `errdefer` frees the first: the function either returns a complete board or nothing. `@memset(cells, 0)` clears the grid; `scratch` is left undefined because `step` writes every byte before reading any.
- **`deinit(self: Board, gpa)`** frees both. It takes the board by value, since it only reads the two slices; the convention is `self: *Board` only when a method changes fields.
- **`fromPattern`** reads the plaintext format used on the Life wiki (conwaylife.com): `O` is alive, `.` is dead, lines starting with `!` are comments. `std.mem.splitScalar(u8, text, '\n')` walks the lines; `std.mem.trimEnd` strips a stray `\r` or trailing spaces. The pattern lands with its corner at (x, y), and a pattern that doesn't fit, or a character that isn't `O` or `.`, is an error. `return error.PatternTooWide` from inside the loop ends the function; the `errdefer board.deinit(gpa)` at the top frees what `init` allocated on that path. Lecture 4 is about these error sets; `!Board` here means "a `Board` or some error".
- **Wrapping with `@mod`.** `at(x, y)` takes signed coordinates so that a neighbour of column 0 can be at column -1. `@mod(x, w)` is the mathematical modulo, always in `0..w-1` even for negative `x`; `@rem` (and C's `%`) would give `-1`. The result is non-negative, so `@intCast` to `usize` is safe.
- **`neighbours`** adds the eight cells around (x, y). The offsets are a literal array of pairs, `[_][2]isize{ ... }`, and iterating a comptime-known array of eight elements compiles to eight additions.
- **`step`** applies the rule: a cell is alive in the next generation if it has exactly three neighbours, or two and is alive now. `@intFromBool` turns the bool into the byte. Everything reads `cells` and writes `scratch`, so the order of the loops doesn't matter.

### Code
`lecture_3/src/main.zig`, part 6:
```zig
// The Game of Life

/// A toroidal board: the right edge wraps to the left, and the bottom to the top. Cells are bytes, 1 for
/// alive and 0 for dead, so that counting neighbours is adding.
const Board = struct {
    width: usize,
    height: usize,
    cells: []u8,
    /// The next generation is computed into a second buffer, then the two are swapped.
    scratch: []u8,

    pub fn init(gpa: std.mem.Allocator, width: usize, height: usize) !Board {
        const cells = try gpa.alloc(u8, width * height);
        errdefer gpa.free(cells);
        const scratch = try gpa.alloc(u8, width * height);
        @memset(cells, 0);
        return .{ .width = width, .height = height, .cells = cells, .scratch = scratch };
    }

    pub fn deinit(self: Board, gpa: std.mem.Allocator) void {
        gpa.free(self.cells);
        gpa.free(self.scratch);
    }

    /// Reads a pattern in the plaintext format of the Life wiki ('O' alive, '.' dead, '!' comments) onto
    /// a board of the given size, with the pattern's top-left corner at (x, y).
    pub fn fromPattern(gpa: std.mem.Allocator, text: []const u8, width: usize, height: usize, x: usize, y: usize) !Board {
        var board = try init(gpa, width, height);
        errdefer board.deinit(gpa);

        var row: usize = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r ");
            if (line.len == 0 or line[0] == '!') continue;
            if (y + row >= height) return error.PatternTooTall;
            for (line, 0..) |ch, col| {
                if (x + col >= width) return error.PatternTooWide;
                board.cells[(y + row) * width + x + col] = switch (ch) {
                    'O' => 1,
                    '.' => 0,
                    else => return error.BadPatternCharacter,
                };
            }
            row += 1;
        }
        return board;
    }

    /// The cell at (x, y), with wrap-around. @mod gives a non-negative result for a negative x, where
    /// @rem (and C's %) would give a negative one.
    fn at(self: Board, x: isize, y: isize) u8 {
        const w: isize = @intCast(self.width);
        const h: isize = @intCast(self.height);
        const wx: usize = @intCast(@mod(x, w));
        const wy: usize = @intCast(@mod(y, h));
        return self.cells[wy * self.width + wx];
    }

    fn neighbours(self: Board, x: usize, y: usize) u8 {
        const cx: isize = @intCast(x);
        const cy: isize = @intCast(y);
        var n: u8 = 0;
        // The eight offsets as a comptime array; the loop over a literal array unrolls to eight additions.
        for ([_][2]isize{ .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 }, .{ -1, 0 }, .{ 1, 0 }, .{ -1, 1 }, .{ 0, 1 }, .{ 1, 1 } }) |d| {
            n += self.at(cx + d[0], cy + d[1]);
        }
        return n;
    }

    /// Advances one generation: a live cell with 2 or 3 neighbours lives, a dead cell with exactly 3 is born.
    pub fn step(self: *Board) void {
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const n = self.neighbours(x, y);
                const alive = self.cells[y * self.width + x] == 1;
                self.scratch[y * self.width + x] = @intFromBool(n == 3 or (alive and n == 2));
            }
        }
        // Swap the buffers: the new generation becomes current, the old one becomes scratch.
        std.mem.swap([]u8, &self.cells, &self.scratch);
    }
```

## 3.7 Counting, drawing and patterns

### Why
Two more methods finish the board: a population count, which is where the vector type earns its place, and a renderer that writes the grid as text. The patterns themselves are data, and Zig has two ways to put data into a program at compile time: a file embedded as bytes, and a multiline string literal.

### How
- **`population`** sums the cells 16 at a time. `rest[0..16]` is a `*[16]u8` (comptime length), `.*` makes it a `[16]u8`, and that coerces to a `@Vector(16, u8)`. Sixteen bytes could overflow a `u8` sum, so `@as(@Vector(16, u16), chunk)` widens every lane first, and `@reduce(.Add, ...)` adds them. The last fewer-than-16 cells are added one by one. On x86-64 the loop body is a handful of instructions per 16 cells.
- **`render`** writes a line per row to any `Writer`: standard output in `main`, an `Allocating` writer in the test. `self.cells[y * self.width ..][0..self.width]` is the row, by the slice-by-length idiom. The glyphs `█` and `·` are three UTF-8 bytes each, which is why a row isn't just a `[width]u8` with two byte values: text goes through a writer.
- **`@embedFile("patterns/glider.cells")`** reads the file at compile time and gives its bytes as a `*const [N:0]u8`, exactly as if the contents were a string literal; the path is relative to the source file. The executable contains the pattern and doesn't open the file at run time. The build system tracks the file, so editing it rebuilds.
- **A multiline string literal** is a run of lines each starting with `\\`; the newlines between them are part of the string, and there are no escapes, so a pattern or a shader (lecture 10) can be written as it is.
- **The patterns:** the glider is the smallest spaceship, five cells that travel one cell diagonally every four generations. The R-pentomino is five cells that take 1103 generations to settle down, the longest of any pattern that small, and a classic test of a Life implementation.

### Code
`lecture_3/src/patterns/glider.cells`:
```text
!Name: Glider
!Author: Richard K. Guy, 1970
!The smallest spaceship: it moves one cell down and right every four generations.
.O.
..O
OOO
```

`lecture_3/src/main.zig`, part 7:
```zig
    /// The number of live cells, summed 16 at a time with a vector, then the remainder one by one.
    pub fn population(self: Board) usize {
        const V = @Vector(16, u8);
        var total: usize = 0;
        var rest = self.cells;
        while (rest.len >= 16) : (rest = rest[16..]) {
            // rest[0..16] is a *[16]u8 (comptime length), which coerces to a vector.
            const chunk: V = rest[0..16].*;
            total += @reduce(.Add, @as(@Vector(16, u16), chunk));
        }
        for (rest) |c| total += c;
        return total;
    }

    /// Draws the board, one line per row. The two glyphs are three UTF-8 bytes each, which is why
    /// the output is text to a Writer rather than a [width]u8 per row.
    pub fn render(self: Board, out: *std.Io.Writer) !void {
        for (0..self.height) |y| {
            const row = self.cells[y * self.width ..][0..self.width];
            for (row) |cell| try out.writeAll(if (cell == 1) "█" else "·");
            try out.writeByte('\n');
        }
    }
};

/// A pattern file, read at compile time: the file's bytes become a string literal in the executable.
const glider = @embedFile("patterns/glider.cells");

/// A multiline string literal: each \\ line is one line of the string, with no escapes.
const r_pentomino =
    \\.OO
    \\OO.
    \\.O.
;
```

## 3.8 Tests

### Why
Life has well-known facts to check against: a blinker oscillates with period two, a glider is itself again four generations later and one cell along, and a board that wraps has every corner touching the opposite one. The parser and the renderer have edge cases, and the vector sum must agree with the obvious loop.

### How
- **`std.testing.allocator`** is the allocator for tests: it detects leaks, so a test that forgets `defer board.deinit(...)` fails with a trace.
- **`std.testing.expectEqualSlices(u8, expected, actual)`** compares two slices element by element and, on a mismatch, prints both with the first differing index marked. `expectEqualStrings` does the same for text, with the strings shown. `expectEqual` compares single values, `expect` takes a bool, and `expectError(error.X, expr)` checks that an expression fails in a particular way.
- **The blinker test** copies the starting grid with `dupe`, steps twice, and expects the copy back; after one step the grid must differ and still hold three cells.
- **The glider test** builds the same pattern twice, once at (0, 0) and once at (1, 1), steps the first four times, and expects the second. That's the definition of a spaceship with period 4 and speed c/4.
- **The wrap test** puts one live cell at (0, 0) on a 3 by 3 board and checks it counts as a neighbour of (2, 2), and that `at(-3, 3)` finds it: -3 wraps to 0 and 3 wraps to 0.
- **The render test** writes a 2 by 2 board into an `Allocating` writer and compares the text, including the trailing newline.
- **The population test** fills a 37 by 11 board (407 cells, not a multiple of 16, so the remainder path runs) with every third cell alive and compares the vector sum with the running total.

### Code
`lecture_3/src/main.zig`, part 8:
```zig
// Tests

test "a blinker has period two" {
    var board = try Board.fromPattern(std.testing.allocator, "OOO", 5, 5, 1, 2);
    defer board.deinit(std.testing.allocator);
    const start = try std.testing.allocator.dupe(u8, board.cells);
    defer std.testing.allocator.free(start);

    board.step();
    try std.testing.expect(!std.mem.eql(u8, start, board.cells));
    try std.testing.expectEqual(3, board.population());
    board.step();
    try std.testing.expectEqualSlices(u8, start, board.cells);
}

test "a glider moves one cell down and right every four generations" {
    var board = try Board.fromPattern(std.testing.allocator, glider, 8, 8, 0, 0);
    defer board.deinit(std.testing.allocator);
    var moved = try Board.fromPattern(std.testing.allocator, glider, 8, 8, 1, 1);
    defer moved.deinit(std.testing.allocator);

    for (0..4) |_| board.step();
    try std.testing.expectEqualSlices(u8, moved.cells, board.cells);
    try std.testing.expectEqual(5, board.population());
}

test "the board wraps around" {
    var board = try Board.fromPattern(std.testing.allocator, "O", 3, 3, 0, 0);
    defer board.deinit(std.testing.allocator);
    // The cell at (0, 0) is a neighbour of (2, 2) through the corner.
    try std.testing.expectEqual(1, board.neighbours(2, 2));
    try std.testing.expectEqual(1, board.at(-3, 3));
}

test "patterns that don't fit are errors" {
    try std.testing.expectError(error.PatternTooWide, Board.fromPattern(std.testing.allocator, "OOOO", 3, 3, 0, 0));
    try std.testing.expectError(error.BadPatternCharacter, Board.fromPattern(std.testing.allocator, "O#", 3, 3, 0, 0));
}

test "render writes one line per row" {
    var board = try Board.fromPattern(std.testing.allocator, "O.\n.O", 2, 2, 0, 0);
    defer board.deinit(std.testing.allocator);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try board.render(&out.writer);
    try std.testing.expectEqualStrings("█·\n·█\n", out.writer.buffered());
}

test "population counts match with and without vectors" {
    var board = try Board.init(std.testing.allocator, 37, 11);
    defer board.deinit(std.testing.allocator);
    var expected: usize = 0;
    for (board.cells, 0..) |*c, i| {
        c.* = @intFromBool(i % 3 == 0);
        expected += c.*;
    }
    try std.testing.expectEqual(expected, board.population());
}
```

## 3.9 The program

### Why
`main` runs the tours, then plays the glider for four generations on a small board so the movement is visible, and follows the R-pentomino's population on a larger one.

### How
- **The glider** starts at (1, 1) on a 10 by 6 board; after generation 4 it's at (2, 2), the shape of generation 0 shifted. `population()` is printed with each frame and stays at 5.
- **The R-pentomino** sits in the middle of a 40 by 40 torus. Thirty generations' populations are collected with `line.print(init.gpa, "{d} ", ...)` into an `ArrayList(u8)` and printed as one line, trimmed of its last space. The published sequence begins 5, 6, 7, 9, 8, 9, 12, 11, 18 and the program agrees; past a few hundred generations the torus's wrap-around would make it diverge from the infinite-plane figures.
- **Buffered output and `defer flush`** as in lecture 1; `render` and `print` both go through `out`, and `std.debug.print` in the demos goes straight to standard error, so the two streams don't interleave badly.

### Code
`lecture_3/src/main.zig`, part 9:
```zig
// The program

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    demoArrays();
    demoSlices();
    try demoStrings(init.gpa);
    try demoArrayList(init.gpa);
    demoVectors();

    // The glider, four generations: it ends where it started, one cell down and right.
    var board = try Board.fromPattern(init.gpa, glider, 10, 6, 1, 1);
    defer board.deinit(init.gpa);
    for (0..5) |generation| {
        try out.print("\nGlider, generation {d} ({d} cells):\n", .{ generation, board.population() });
        try board.render(out);
        board.step();
    }

    // The R-pentomino: five cells that take 1103 generations to settle. We follow the population for
    // the first 30 on a 40 by 40 torus, collected into a line of text with an ArrayList.
    var pentomino = try Board.fromPattern(init.gpa, r_pentomino, 40, 40, 19, 19);
    defer pentomino.deinit(init.gpa);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(init.gpa);
    for (0..30) |_| {
        try line.print(init.gpa, "{d} ", .{pentomino.population()});
        pentomino.step();
    }
    try out.print("\nR-pentomino population, generations 0 to 29:\n  {s}\n", .{std.mem.trimEnd(u8, line.items, " ")});
}
```

## 3.10 Running it

### How
From `lecture_3/`, `zig build run` prints the tours (to standard error) and then the board (to standard output):
```text
Arrays:
    [4]u8 of 4: { 3, 1, 4, 1 }; zeros { 0, 0, 0, 0 }
    counts ++ {5, 9} = { 3, 1, 4, 1, 5, 9 }, a [6]u8
    copy { 9, 1, 4, 1 } == counts { 3, 1, 4, 1 }? false
    first 3, second 1
    grid[1][2] = 6; rows of 3, 6 bytes in all
    squares, built at compile time: { 0, 1, 4, 9, 16, 25, 36, 49 }
Slices:
    sum(all) = 21, sum(middle) = 7, middle.len = 2
    numbers[2..4] is *[2]u32; numbers[start..] is []u32
    after doubling three from 1: { 1, 4, 6, 8, 5, 6 }
    0: one = 1
    1: two = 4
    2: three = 6
    first value over 7: 8
Strings:
    'héllo, wörld' is 14 bytes; byte 0 is ASCII and byte 1 isn't: true
    code point U+00E9 (é) takes 2 bytes
    code point U+00F6 (ö) takes 2 bytes
    12 code points in 14 bytes
    trimmed 'name = Conway's Life'; starts with 'name': true; find("=") = 5
    key 'name', value 'Conway's Life'
    5 numbers summing to 14
    '2 + 3 = 5' in a stack buffer; 'SHOUT!' on the heap
    joined: cola, chips, candy
    built: '0 1 4 9 16'
    sorted: apple fig pear
ArrayList:
    items { 10, 15, 20, 30, 40 }, len 5, capacity 33
    popped 80, removed 30, items { 20, 40, 60 }
    100 appends without moving: true
    owned slice of 103, largest three { 99, 98, 97 }; list now has 0
    text: '103 items'
Vectors:
    a * 10 + a = { 11, 22, 33, 44 }
    > 30: { false, false, true, true }, clamped { 11, 22, 30, 30 }, sum 110, max 44, any big? true
    as an array { 11, 22, 33, 44 }, and back { 11, 22, 33, 44 }

Glider, generation 0 (5 cells):
··········
··█·······
···█······
·███······
··········
··········
...
Glider, generation 4 (5 cells):
··········
··········
···█······
····█·····
··███·····
··········

R-pentomino population, generations 0 to 29:
  5 6 7 9 8 9 12 11 18 11 11 10 13 16 19 19 23 25 35 25 32 27 37 30 46 39 45 30 31 29
```
`zig build test` runs the six tests. Two experiments: change `@mod` to `@rem` in `at`, and the wrap test fails with a panic about a negative value cast to `usize` (the `@intCast` is checked); remove the `defer board.deinit` from a test, and the testing allocator fails it with the allocation's trace. And a third: give `fromPattern` the glider on a board that's 2 wide, and `error.PatternTooWide` comes back with nothing leaked, thanks to the `errdefer`.
