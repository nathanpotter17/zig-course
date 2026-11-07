const std = @import("std");
const calc = @import("calc.zig");

// A test build never calls main, so nothing in it would reach calc.zig, and the compiler only analyzes
// (and only runs the tests of) files it reaches. This block imports the file so its tests are discovered.
test {
    _ = @import("calc.zig");
}

// Errors are values

/// An error set is a type: a list of names. Each name is one value of the global error set, a u16
/// chosen by the compiler, and the same name in two sets is the same value.
const ConfigError = error{ MissingFile, BadSyntax };
const NetworkError = error{ Timeout, Refused };
/// || merges error sets. A function that can fail either way returns this.
const LoadError = ConfigError || NetworkError;

fn load(source: enum { disk, network }) LoadError!u32 {
    return switch (source) {
        .disk => error.BadSyntax,
        .network => error.Timeout,
    };
}

fn demoErrorValues() void {
    std.debug.print("Errors are values:\n", .{});
    const err: ConfigError = error.MissingFile;
    // @errorName is the name as a string; @intFromError the integer behind it; {t} prints the name.
    std.debug.print("    {t} is named '{s}' and numbered {d}; an error is {d} bytes\n", .{ err, @errorName(err), @intFromError(err), @sizeOf(anyerror) });

    // A subset coerces to a superset for free. The other way needs @errorCast, which is checked.
    const widened: LoadError = err;
    const narrowed: ConfigError = @errorCast(widened);
    std.debug.print("    as LoadError: {t}; cast back: {t}; equal: {}\n", .{ widened, narrowed, widened == narrowed });

    // anyerror is the set of every error in the program. Avoid it in signatures: it hides which errors
    // can happen, so a switch over it can't be checked for completeness.
    const any: anyerror = error.Timeout;
    std.debug.print("    anyerror holds {t} too\n", .{any});
}

// Handling errors

/// `!u32` is an inferred error set: the compiler collects every error this function can return. It's
/// convenient, and it's what most code writes; name the set when callers need to switch on it, or when
/// the function is recursive.
fn parseAndDouble(text: []const u8) !u32 {
    const n = try std.fmt.parseInt(u32, text, 10);
    return std.math.mul(u32, n, 2);
}

fn demoHandling() !void {
    std.debug.print("Handling:\n", .{});

    // try: propagate. catch: handle, here with a default value.
    const a = parseAndDouble("21") catch 0;
    const b = parseAndDouble("twenty-one") catch 0;
    std.debug.print("    try/catch default: {d}, {d}\n", .{ a, b });

    // catch with a capture and a block: log, then produce a value (or return, or anything).
    const c = parseAndDouble("4000000000") catch |err| blk: {
        std.debug.print("    caught {t}, using the maximum instead\n", .{err});
        break :blk std.math.maxInt(u32);
    };
    std.debug.print("    c = {d}\n", .{c});

    // if-else with switch: a different action per error. The switch must handle every error in the
    // set, and the compiler knows the set because parseAndDouble's is inferred from its body.
    const inputs = [_][]const u8{ "7", "x7", "70000000000", "9999999999" };
    for (inputs) |input| {
        if (parseAndDouble(input)) |value| {
            std.debug.print("    '{s}' -> {d}\n", .{ input, value });
        } else |err| switch (err) {
            error.InvalidCharacter => std.debug.print("    '{s}' isn't a number\n", .{input}),
            error.Overflow => std.debug.print("    '{s}' is too big, or its double is\n", .{input}),
        }
    }

    // {!d} prints an error union as its value or its error, and {!} with the default format.
    std.debug.print("    as error unions: {!d} and {!d}\n", .{ parseAndDouble("12"), parseAndDouble("") });

    // errdefer runs only if the function exits with an error, which the next `try` makes it do.
    errdefer std.debug.print("    demoHandling is failing, and errdefer saw it\n", .{});
    _ = try parseAndDouble("ok");
    std.debug.print("    not reached\n", .{});
}

// Optionals and errors together

/// Both `null` and an error are possible: the text may not contain a number (null), or the number may
/// not parse (error). `!?u32` reads "an error, or an optional u32".
fn firstNumber(text: []const u8) !?u32 {
    var words = std.mem.tokenizeScalar(u8, text, ' ');
    while (words.next()) |word| {
        if (std.ascii.isDigit(word[0])) return try std.fmt.parseInt(u32, word, 10);
    }
    return null;
}

fn demoOptionals() !void {
    std.debug.print("Optionals and errors:\n", .{});
    // try unwraps the error layer; the optional is left for `if` or `orelse`.
    if (try firstNumber("the answer is 42 of course")) |n| {
        std.debug.print("    found {d}\n", .{n});
    }
    const fallback = (try firstNumber("no digits here")) orelse 0;
    std.debug.print("    none found, fallback {d}\n", .{fallback});
    // The error layer: a word that starts with a digit but isn't a number.
    std.debug.print("    '7up' gives {!?d}\n", .{firstNumber("drink 7up")});

    // while with an optional: `while (it.next()) |x|` loops until next() returns null, unwrapping each time.
    var words = std.mem.splitScalar(u8, "1 + 2", ' ');
    var count: usize = 0;
    while (words.next()) |_| : (count += 1) {}
    std.debug.print("    '1 + 2' is {d} words\n", .{count});

    // Optional fields and orelse-return: a value that may be absent inside a struct.
    const Config = struct { name: []const u8, port: ?u16 = null };
    const configs = [_]Config{ .{ .name = "web", .port = 8080 }, .{ .name = "worker" } };
    for (configs) |config| {
        const port = config.port orelse {
            std.debug.print("    {s}: no port\n", .{config.name});
            continue;
        };
        std.debug.print("    {s}: port {d}\n", .{ config.name, port });
    }
}

// Unions

/// A bare union: one of these at a time, and no record of which. Reading the wrong field is
/// safety-checked illegal behavior (a panic in debug builds), so bare unions are for when the code
/// around them already knows the case. Tagged unions (union(enum), lecture 1) are the usual choice.
const Bare = union {
    int: i64,
    float: f64,
};

/// An extern union has C's layout: every field starts at offset 0, and reading a field other than the
/// one written reinterprets the bytes. The classic use is looking at a float's bits.
const Bits = extern union {
    float: f32,
    bits: u32,
};

/// A tagged union whose tag is a named enum, so the tag type can be used on its own, and the union
/// coerces to it. `std.meta.Tag(Shape)` gets the enum back from the union.
const ShapeKind = enum { circle, square };
const Shape = union(ShapeKind) {
    circle: f64,
    square: f64,

    fn area(self: Shape) f64 {
        return switch (self) {
            .circle => |r| std.math.pi * r * r,
            .square => |side| side * side,
        };
    }
};

fn demoUnions() void {
    std.debug.print("Unions:\n", .{});
    var bare = Bare{ .int = 7 };
    bare = .{ .float = 2.5 }; // switching the active field means assigning the whole union
    std.debug.print("    bare is {d} bytes, holding {d}\n", .{ @sizeOf(Bare), bare.float });

    const view = Bits{ .float = 1.0 };
    std.debug.print("    1.0f as bits: 0x{x} (an extern union reinterprets, like @bitCast)\n", .{view.bits});

    var shapes = [_]Shape{ .{ .circle = 1.0 }, .{ .square = 2.0 } };
    for (shapes) |shape| {
        // A tagged union coerces to its tag; {t} prints the tag name.
        std.debug.print("    {t} with area {d:.2}; tag as enum: {t}\n", .{ shape, shape.area(), @as(ShapeKind, shape) });
    }

    // Capturing by pointer in a switch changes the payload in place.
    for (&shapes) |*shape| {
        switch (shape.*) {
            .circle => |*r| r.* *= 2,
            .square => |*s| s.* += 1,
        }
    }
    std.debug.print("    after doubling the radius and growing the square: {d:.2}, {d:.2}\n", .{ shapes[0].area(), shapes[1].area() });
    std.debug.print("    active tag of the first: {t}; a Shape is {d} bytes (payload plus tag)\n", .{ std.meta.activeTag(shapes[0]), @sizeOf(Shape) });
}

// The calculator

/// Expressions to evaluate, one per line, including some that fail on purpose.
const batch =
    \\1 + 2 * 3
    \\(1 + 2) * 3
    \\2 ^ 10 - 24
    \\-7 % 5
    \\max(3, 1 + 1, abs(-9))
    \\gcd(84, 36)
    \\9223372036854775807 + 1
    \\1 / (3 - 3)
    \\2 +
    \\sqrt(2)
    \\(1 + 2
    \\99999999999999999999
;

/// Evaluates one line and prints the result or the error. Every error the calculator can produce comes
/// back as a value; this function decides what each means to the user and never lets one through.
fn evaluateLine(out: *std.Io.Writer, arena: *std.heap.ArenaAllocator, line: []const u8) !void {
    // The tokenizer wants a 0 sentinel after the text; dupeSentinel copies the line into the arena with one.
    const source = try arena.allocator().dupeSentinel(u8, line, 0);
    var diagnostic: ?calc.Parser.Diagnostic = null;

    if (calc.evaluate(arena.allocator(), source, &diagnostic)) |value| {
        try out.print("  {s:<28} = {d}\n", .{ line, value });
    } else |err| switch (err) {
        // The arena is backed by init.gpa; running out is not something a calculator can fix, so it propagates.
        error.OutOfMemory => return err,
        // Parse errors have a position; point at it.
        error.UnexpectedToken, error.UnexpectedEnd, error.InvalidNumber, error.UnknownFunction => {
            const d = diagnostic.?;
            try out.print("  {s:<28}   error.{t} at column {d}: {s}\n", .{ line, err, d.position + 1, d.message });
        },
        // Evaluation errors have a description.
        error.Overflow, error.DivisionByZero, error.WrongArgumentCount, error.NegativeArgument => {
            try out.print("  {s:<28}   error.{t}: {s}\n", .{ line, err, calc.describe(err) });
        },
    }

    // Everything the parse allocated is freed at once, and the arena keeps its memory for the next line.
    _ = arena.reset(.retain_capacity);
}

/// Three functions deep, for the error return trace: run the program with --fail to see it.
fn fail() !void {
    return innerFail();
}

fn innerFail() !void {
    return error.RequestedFailure;
}

// The program

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    demoErrorValues();
    demoHandling() catch |err| std.debug.print("    main saw {t} from demoHandling and carries on\n", .{err});
    try demoOptionals();
    demoUnions();

    // One arena for all the expression trees, reset after each line.
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    try out.writeAll("\nThe batch:\n");
    var lines = std.mem.splitScalar(u8, batch, '\n');
    while (lines.next()) |line| try evaluateLine(out, &arena, line);

    // Expressions from the command line: `zig build run -- "2 ^ 20" "gcd(9, 6)"`. toSlice gives the
    // arguments as slices; args[0] is the program itself.
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1) {
        try out.writeAll("\nFrom the command line:\n");
        for (args[1..]) |arg| {
            // An error returned from main prints an error return trace and exits with status 1.
            if (std.mem.eql(u8, arg, "--fail")) return fail();
            try evaluateLine(out, &arena, arg);
        }
    }
}
