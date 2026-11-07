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
