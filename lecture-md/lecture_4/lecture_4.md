# Lecture 4: Errors, optionals and unions

By the end of this lecture we'll have a batch calculator: a program that reads arithmetic expressions one per line, evaluates each with checked 64-bit integer arithmetic, and for every expression it can't evaluate says exactly what went wrong and where. A calculator is a parser, and parsers are mostly about what can go wrong: a token in the wrong place, an expression that ends early, a number too big, a division by zero. That makes it the right program for Zig's approach to errors.

The ideas of this lecture:
- **Errors are values.** An error is a name in an *error set*, a type like an enum; underneath it's a `u16`. A function that can fail returns an *error union*, `E!T`, and the caller must do something with the error: `try` to pass it up, `catch` to handle it, `if ... else |err|` to take it apart. Nothing is thrown, nothing unwinds, and the compiler knows every error a function can return.
- **Error sets compose.** `||` merges two sets; a subset coerces to a superset; a `switch` on an error must handle every member. `!T` lets the compiler infer the set from the function body.
- **Errors carry no data**, by design; a position or a message travels another way. The calculator uses the *diagnostic* pattern the Zig compiler itself uses.
- **Optionals** say "maybe absent" where errors say "failed", and the two combine: `!?T`.
- **Unions** are Zig's sum types: bare, tagged, and `extern`. Lecture 1 used tagged unions; here they hold a syntax tree.

Two files: `lecture_4/src/calc.zig` is the calculator (tokenizer, parser, evaluator, tests), and `lecture_4/src/main.zig` demonstrates the language features, then drives the calculator. The build files are lecture 1's with the name changed.

## 4.1 Errors are values

### Why
Most languages make an error an object thrown through the stack, invisible in function signatures and expensive at run time. Zig makes it a value: a small integer with a name, returned like any other value. The cost of an error path is a comparison, the set of possible errors is part of the type, and the compiler can check that every one is handled.

### How
- **`error{ MissingFile, BadSyntax }`** is an *error set type*. Each name is a value of the type: `error.MissingFile`. Every distinct error name in the whole program gets one integer, so the same name in two sets is the same value, and an error is `@sizeOf(anyerror)` = 2 bytes.
- **`||`** merges sets: `LoadError` has four members. A function that can fail in either way returns `LoadError!u32`: a `LoadError` or a `u32`.
- **Coercion:** a value of a subset coerces to a superset for free (`const widened: LoadError = err;`). Going the other way needs `@errorCast`, which asserts the value is in the smaller set (checked in debug builds).
- **`@errorName(err)`** is the name as a string, and `{t}` in a format string prints it; `@intFromError` is the integer, which is only useful for printing: don't store it.
- **`anyerror`** is the global set, the union of every error in the compilation. Any error coerces to it. Avoid it in signatures: a function that returns `anyerror!T` tells its callers nothing, and a `switch` on an `anyerror` can't be checked for completeness.
- **`load`** uses an enum type written inline as a parameter type, `enum { disk, network }`, a small thing worth knowing: types are expressions, and can be written where they're used.
- **The `test` block at the top of `main.zig`** is lecture 2's discovery idiom: `zig build test` only runs the tests of files the compiler reaches from the root, and in a test build `main` is never called, so without it the tests in `calc.zig` would silently not run.

### Code
`lecture_4/src/main.zig`, part 1:
```zig
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
```

## 4.2 Handling errors

### Why
There are only a few things to do with an error: pass it up, replace it with a value, handle it with logic, or take a different action for each kind. Zig has one piece of syntax for each, and they compose with the rest of the language because an error union is a value and `catch` is an operator.

### How
- **Inferred error sets:** `fn parseAndDouble(...) !u32` has no set named before the `!`; the compiler collects every error the body can return, here `parseInt`'s `InvalidCharacter` and `Overflow` and `std.math.mul`'s `Overflow`. Most code is written this way. The set is still known, which is why the `switch` below can be checked. Inferred sets can't be used by recursive functions (4.6 names its sets for that reason) or taken as function pointers.
- **`try expr`** is `expr catch |err| return err`: the value, or an early return with the error.
- **`expr catch default`** replaces any error with a value of the payload type. **`catch |err| blk: { ...; break :blk value; }`** runs code first, with the error in `err`; the block can also `return`, `break` out of a loop, or `unreachable`.
- **`if (expr) |value| { ... } else |err| switch (err) { ... }`** is the full form: one branch per error, and the `switch` must cover the set, so a new error in `parseAndDouble` is a compile error here until it's handled. `else => |other| return other;` in the switch narrows: it handles some errors and passes the rest up, and the function's error set shrinks accordingly.
- **`{!d}`** formats an error union: the value as `{d}`, or `error.Name`. `{!}` uses the default for the payload.
- **`errdefer`** runs when the block exits with an error, as in lecture 2. `demoHandling` ends with a `try` that fails, so its `errdefer` prints, the function returns `error.InvalidCharacter`, and `main`'s `catch` reports it and carries on. The line after the `try` never runs.
- **`catch unreachable`** is the way to say "this can't fail": a panic in debug and safe builds if it does, and nothing in fast builds. `std.math.maxInt(u32)` here is a `comptime_int` coerced to the block's type.

### Code
`lecture_4/src/main.zig`, part 2:
```zig
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
```

## 4.3 Optionals and errors together

### Why
"There is no number in this text" and "the number in this text is malformed" are different outcomes, and a function should be able to report both without inventing a sentinel. Zig's answer is to nest the two types: `!?u32` is an error, or null, or a number, and each layer is unwrapped with its own syntax.

### How
- **`!?u32`** reads outside-in: an error union whose payload is an optional whose payload is a `u32`. `try` strips the error layer, leaving a `?u32` for `if (...) |n|` or `orelse`. `(try firstNumber(...)) orelse 0` does both in one line; the parentheses are needed because `orelse` binds tighter than `try`.
- **`{!?d}`** formats the whole thing: `error.X`, `null`, or the number.
- **`while (it.next()) |word|`** is the loop over an iterator: `next` returns an optional, the capture unwraps it, and the loop ends at `null`. `|_|` discards the payload when only the count matters. The `: (count += 1)` continue expression runs after each iteration.
- **Optional fields** with a `null` default, `port: ?u16 = null`, model "not configured". **`orelse { ...; continue; }`** uses a block that diverges: `orelse` can be followed by any expression of the payload type or of type `noreturn`, and a block that always `continue`s, `return`s or `break`s has type `noreturn`.
- **`std.ascii.isDigit`** and the rest of `std.ascii` work on single bytes.

### Code
`lecture_4/src/main.zig`, part 3:
```zig
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
```

## 4.4 Unions

### Why
A union is one value that can be any of several types, one at a time. C's union is a reinterpretation of bytes with no record of what's in it; Zig has that too, as `extern union`, but its default `union` is safety-checked, and `union(enum)` adds a tag so that `switch` can take it apart. Lecture 1 used tagged unions for events and states; this section shows the three kinds side by side, and the parser's syntax tree in 4.6 is built from one.

### How
- **A bare `union`** holds one of its fields and, in debug and safe builds, secretly remembers which: reading a field other than the active one panics with "access of union field 'float' while field 'int' is active". To change the active field, assign a whole new union value. Its size is the largest field's (plus the hidden tag in safe builds). Bare unions are for code that knows the case from elsewhere; they can't be switched on.
- **An `extern union`** has C's layout: every field at offset 0, no tag, and reading another field reinterprets the bytes. `Bits{ .float = 1.0 }` read as `.bits` is `0x3f800000`, the same as lecture 1's `@bitCast`. It's the type for C APIs that use unions (lecture 9).
- **A tagged union with a named tag:** `union(ShapeKind)` ties the union to an existing enum, so the enum can be used alone (a field that's "which shape", without the payload), and the union *coerces to it*: `@as(ShapeKind, shape)` is the tag. `union(enum)` from lecture 1 is the same with the enum made up on the spot; `std.meta.Tag(Shape)` recovers it, and `std.meta.activeTag(value)` reads a value's tag.
- **Methods on unions:** `area` switches on `self`, with a capture per prong. Unions can hold declarations like structs and enums.
- **Capturing by pointer:** `switch (shape.*) { .circle => |*r| r.* *= 2, ... }` gives a pointer to the payload, so the prong can change it in place. That needs a pointer to the union, which `for (&shapes) |*shape|` provides.
- **Size:** a `Shape` is 16 bytes, an `f64` plus a tag padded to 8.

### Code
`lecture_4/src/main.zig`, part 4:
```zig
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
```

## 4.5 The tokenizer

### Why
A parser works on tokens, not characters: `12`, `+`, `max`, `(`. The tokenizer turns text into a stream of them, and it's a small state machine: in the middle of a number, keep going while the bytes are digits. Zig has a construct made for exactly this, the labeled `switch`, and the standard library's own Zig tokenizer is written with it.

### How
- **`Token`** is a tag and two offsets into the source. The text of a token is a slice of the source, `source[start..end]`, so the tokenizer never copies and tokens are 24 bytes whatever the input's size. `Tag` is an enum declared inside the struct: `Token.Tag`.
- **A sentinel-terminated source.** `Tokenizer` takes a `[:0]const u8`: a slice with a guaranteed 0 byte at index `len`. That lets `next` read `self.source[self.index]` without checking the length first: at the end, it reads the 0 and stops. String literals are already sentinel-terminated, and `main` copies each line with `dupeSentinel` to get the same guarantee.
- **The labeled switch.** `state: switch (State.start) { ... }` runs the `.start` prong; a prong that ends with `continue :state .number` jumps to the `.number` prong, as if the switch were evaluated again with that value. The compiler compiles each `continue` to a direct jump, so this is a hand-written state machine with no loop variable and no dispatch loop; a prong that falls off its end leaves the switch. In `.start`, whitespace advances and restarts; a digit sets the tag and continues to `.number`, which consumes digits until it sees something else; an operator sets the tag and advances one byte; anything unknown becomes `.invalid`.
- **Ranges in prongs:** `'0'...'9'` and `'a'...'z', 'A'...'Z', '_'` match character ranges, inclusive.
- **The sentinel prong:** `0 =>` means the end of the input, unless the 0 appears before `len`, which makes it an invalid token. `result.tag = if (...) .eof else .invalid` is an `if` expression assigning an enum literal.
- **`next` on a finished tokenizer** keeps returning `.eof`, because `index` stays at `len` and the sentinel is read again. The parser relies on that.

### Code
`lecture_4/src/calc.zig`, part 1:
```zig
//! A calculator: text in, an i64 out, or an error that says what went wrong and where.
//! Three stages, each a struct in this file: the Tokenizer cuts the text into tokens, the Parser turns
//! tokens into a tree of Nodes, and eval() walks the tree.

const std = @import("std");
const Allocator = std.mem.Allocator;

// Tokens

pub const Token = struct {
    tag: Tag,
    start: usize,
    end: usize,

    pub const Tag = enum {
        number,
        identifier,
        plus,
        minus,
        star,
        slash,
        percent,
        caret,
        l_paren,
        r_paren,
        comma,
        eof,
        invalid,
    };

    /// The token's text, as a slice into the source.
    pub fn slice(self: Token, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

/// Cuts a sentinel-terminated string into tokens, one call to next() at a time. The 0 sentinel means
/// the loop can look at "the next byte" without checking the length: at the end it sees a 0.
pub const Tokenizer = struct {
    source: [:0]const u8,
    index: usize = 0,

    const State = enum { start, number, identifier };

    pub fn init(source: [:0]const u8) Tokenizer {
        return .{ .source = source };
    }

    pub fn next(self: *Tokenizer) Token {
        var result: Token = .{ .tag = undefined, .start = self.index, .end = undefined };

        // A labeled switch is a state machine: `continue :state .number` jumps to the .number prong,
        // as if the switch were run again with that value. The compiler turns it into direct jumps.
        state: switch (State.start) {
            .start => switch (self.source[self.index]) {
                // The sentinel. A 0 byte before the end would be an invalid token instead.
                0 => result.tag = if (self.index == self.source.len) .eof else .invalid,
                ' ', '\t', '\r' => {
                    self.index += 1;
                    result.start = self.index;
                    continue :state .start;
                },
                '0'...'9' => {
                    result.tag = .number;
                    continue :state .number;
                },
                'a'...'z', 'A'...'Z', '_' => {
                    result.tag = .identifier;
                    continue :state .identifier;
                },
                '+' => {
                    result.tag = .plus;
                    self.index += 1;
                },
                '-' => {
                    result.tag = .minus;
                    self.index += 1;
                },
                '*' => {
                    result.tag = .star;
                    self.index += 1;
                },
                '/' => {
                    result.tag = .slash;
                    self.index += 1;
                },
                '%' => {
                    result.tag = .percent;
                    self.index += 1;
                },
                '^' => {
                    result.tag = .caret;
                    self.index += 1;
                },
                '(' => {
                    result.tag = .l_paren;
                    self.index += 1;
                },
                ')' => {
                    result.tag = .r_paren;
                    self.index += 1;
                },
                ',' => {
                    result.tag = .comma;
                    self.index += 1;
                },
                else => {
                    result.tag = .invalid;
                    self.index += 1;
                },
            },
            .number => {
                self.index += 1;
                switch (self.source[self.index]) {
                    '0'...'9', '_' => continue :state .number,
                    else => {},
                }
            },
            .identifier => {
                self.index += 1;
                switch (self.source[self.index]) {
                    'a'...'z', 'A'...'Z', '0'...'9', '_' => continue :state .identifier,
                    else => {},
                }
            },
        }

        result.end = self.index;
        return result;
    }
};
```

## 4.6 The syntax tree and the parser

### Why
`2 + 3 * 4` is a tree: an addition whose right operand is a multiplication. Building the tree first and evaluating it second keeps the grammar (precedence, associativity, parentheses) in one place and the arithmetic in another. The tree is a recursive data structure of tagged unions and pointers, which is where arenas shine: hundreds of small nodes, all freed at once.

### How
- **`Node`** is a tagged union: a number, a negation of a node, a binary operation on two nodes, or a call with a slice of argument nodes. The children are `*const Node`, pointers into the arena, because a union can't contain itself by value (it would have infinite size). The operator and function names are enums declared inside `Node`, with small methods: `precedence` and `fromToken` (which returns `?Op`: null for a token that isn't an operator).
- **`std.meta.stringToEnum(Node.Function, text)`** looks a string up among an enum's field names and returns the value or `null`. Adding a function to the calculator is adding a field to the enum and a prong to `eval`; the parser needs no change.
- **Explicit error sets for recursion.** `parseExpression` calls `parseUnary`, which calls `parsePrimary`, which calls `parseExpression`. An inferred error set (`!T`) is computed from the body, and the body's errors include the callee's, which include the caller's: the compiler can't resolve the cycle, and refuses. So `Parser.Error` names the set, and every parsing function returns `Error!*const Node`. (It's the same reason the language reference gives for naming sets: recursion, function pointers, and documentation.)
- **The diagnostic.** An error value is a name and nothing else. The parser stores *where* and *why* in `self.diagnostic`, an optional struct, right before returning the error; `fail()` does both in one call, and because it returns the error, a prong can read `return self.fail(token, error.X, "...")`. The caller gets the error through the normal channel and reads the diagnostic from the parser. This is how the Zig compiler and the standard library's `std.json` report positions.
- **One token of lookahead.** `current` is the token being considered; `advance` returns it and reads the next. `init` reads the first token so `current` is always valid.
- **Precedence climbing.** `parseExpression(min)` parses an operand, then loops: if the next token is an operator binding at least as tightly as `min`, consume it, parse the right operand with a *higher* minimum, and combine. `2 + 3 * 4`: after `2`, `+` (precedence 1) is taken, and the right side is parsed with minimum 2, which absorbs `* 4` before returning. For `^`, the right side is parsed with the *same* minimum, so `2 ^ 3 ^ 2` is `2 ^ (3 ^ 2)`: right-associative. `while (Node.Op.fromToken(...)) |op|` is a while-with-optional: it ends when the token isn't an operator.
- **Unary minus** binds tighter than any binary operator and nests: `--3` is fine. **Parentheses** parse an inner expression and demand the `)`. **Calls** parse comma-separated arguments into an `ArrayList` that lives in the arena; `args.items` becomes the node's slice, and since the arena frees everything, the list is never `deinit`ed. **`parseInt`** failing on a 20-digit number becomes `error.InvalidNumber` through a `catch` that returns `self.fail(...)`.
- **`parse`** is the entry point: one expression, then `.eof`, or "expected the end of the expression" (for input like `1 2`).

### Code
`lecture_4/src/calc.zig`, part 2:
```zig
// The syntax tree

/// One node of an expression. A tagged union: a node is a number, or a negation of another node, or an
/// operator with two operands, or a function call with any number of arguments. Child nodes are pointers
/// into an arena, so the whole tree is freed at once.
pub const Node = union(enum) {
    number: i64,
    negate: *const Node,
    binary: struct { op: Op, lhs: *const Node, rhs: *const Node },
    call: struct { function: Function, args: []const *const Node },

    pub const Op = enum {
        add,
        sub,
        mul,
        div,
        rem,
        pow,

        /// Binding strength: higher binds tighter. Exponentiation is also right-associative (see parseExpression).
        fn precedence(op: Op) u8 {
            return switch (op) {
                .add, .sub => 1,
                .mul, .div, .rem => 2,
                .pow => 3,
            };
        }

        /// The operator a token stands for, or null if the token isn't one.
        fn fromToken(tag: Token.Tag) ?Op {
            return switch (tag) {
                .plus => .add,
                .minus => .sub,
                .star => .mul,
                .slash => .div,
                .percent => .rem,
                .caret => .pow,
                else => null,
            };
        }
    };

    /// The functions the calculator knows. Their names are the enum's field names, which is what
    /// std.meta.stringToEnum matches against.
    pub const Function = enum { min, max, abs, gcd };
};

// The parser

/// A recursive-descent parser with precedence climbing. Every function declares its error set
/// explicitly, because the functions call each other recursively, and an inferred error set
/// (a bare `!`) can't be used in a recursive function.
pub const Parser = struct {
    arena: Allocator,
    source: [:0]const u8,
    tokenizer: Tokenizer,
    /// The token being looked at. The parser always holds one token of lookahead.
    current: Token,
    /// Where and why the last error happened. An error value carries no data, so the parser puts
    /// the details here, and the caller reads them after an error comes back.
    diagnostic: ?Diagnostic = null,

    pub const Diagnostic = struct {
        position: usize,
        message: []const u8,
    };

    /// Everything parsing can fail with. The parser's own errors, merged (||) with the allocator's.
    pub const Error = error{
        UnexpectedToken,
        UnexpectedEnd,
        InvalidNumber,
        UnknownFunction,
    } || Allocator.Error;

    pub fn init(arena: Allocator, source: [:0]const u8) Parser {
        var tokenizer = Tokenizer.init(source);
        return .{
            .arena = arena,
            .source = source,
            .current = tokenizer.next(),
            .tokenizer = tokenizer,
        };
    }

    /// Parses the whole source as one expression.
    pub fn parse(self: *Parser) Error!*const Node {
        const root = try self.parseExpression(0);
        if (self.current.tag != .eof) return self.fail(self.current, error.UnexpectedToken, "expected the end of the expression");
        return root;
    }

    /// Records the diagnostic and returns the error, so a prong can read `return self.fail(...)`.
    fn fail(self: *Parser, at: Token, err: Error, message: []const u8) Error {
        self.diagnostic = .{ .position = at.start, .message = message };
        return err;
    }

    /// Moves to the next token and returns the one that was current.
    fn advance(self: *Parser) Token {
        const token = self.current;
        self.current = self.tokenizer.next();
        return token;
    }

    fn makeNode(self: *Parser, node: Node) Allocator.Error!*const Node {
        const ptr = try self.arena.create(Node);
        ptr.* = node;
        return ptr;
    }

    /// Precedence climbing: parse an operand, then keep absorbing operators that bind at least as
    /// tightly as `min_precedence`. The right operand is parsed with a higher minimum, so that
    /// `2 + 3 * 4` groups as 2 + (3 * 4); `^` passes the same minimum, so `2 ^ 3 ^ 2` is 2 ^ (3 ^ 2).
    fn parseExpression(self: *Parser, min_precedence: u8) Error!*const Node {
        var lhs = try self.parseUnary();
        while (Node.Op.fromToken(self.current.tag)) |op| {
            const precedence = op.precedence();
            if (precedence < min_precedence) break;
            _ = self.advance();
            const rhs = try self.parseExpression(if (op == .pow) precedence else precedence + 1);
            lhs = try self.makeNode(.{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs } });
        }
        return lhs;
    }

    fn parseUnary(self: *Parser) Error!*const Node {
        if (self.current.tag == .minus) {
            _ = self.advance();
            return self.makeNode(.{ .negate = try self.parseUnary() });
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) Error!*const Node {
        const token = self.advance();
        switch (token.tag) {
            .number => {
                // parseInt fails on digits that don't fit an i64; `catch` turns that into our error.
                const value = std.fmt.parseInt(i64, token.slice(self.source), 10) catch
                    return self.fail(token, error.InvalidNumber, "number doesn't fit in 64 bits");
                return self.makeNode(.{ .number = value });
            },
            .l_paren => {
                const inner = try self.parseExpression(0);
                if (self.current.tag != .r_paren) return self.fail(self.current, error.UnexpectedToken, "expected ')'");
                _ = self.advance();
                return inner;
            },
            .identifier => {
                // stringToEnum returns null when no field has that name: an unknown function.
                const function = std.meta.stringToEnum(Node.Function, token.slice(self.source)) orelse
                    return self.fail(token, error.UnknownFunction, "unknown function");
                if (self.current.tag != .l_paren) return self.fail(self.current, error.UnexpectedToken, "expected '(' after the function name");
                _ = self.advance();

                // The argument list grows in the arena; its memory is freed with the tree, so no deinit.
                var args: std.ArrayList(*const Node) = .empty;
                while (self.current.tag != .r_paren) {
                    try args.append(self.arena, try self.parseExpression(0));
                    switch (self.current.tag) {
                        .comma => _ = self.advance(),
                        .r_paren => {},
                        else => return self.fail(self.current, error.UnexpectedToken, "expected ',' or ')'"),
                    }
                }
                _ = self.advance();
                return self.makeNode(.{ .call = .{ .function = function, .args = args.items } });
            },
            .eof => return self.fail(token, error.UnexpectedEnd, "the expression ends too soon"),
            else => return self.fail(token, error.UnexpectedToken, "unexpected token"),
        }
    }
};
```

## 4.7 Evaluation, and the whole pipeline

### Why
Evaluating the tree is a recursive walk with one rule per node kind. The arithmetic is where integers bite: `9223372036854775807 + 1` doesn't fit, `1 / 0` has no answer, and `abs` of the most negative number is one too many. Each is an error value, not a wrapped result or a crash, and the standard library's checked functions do the detecting.

### How
- **`EvalError`** is explicit too, so that `evaluate`'s callers can switch on the merged set. **`std.math.add`, `sub`, `mul`** return `error{Overflow}!T`, using `@addWithOverflow` and friends from lecture 1 underneath; `std.math.negate` is `sub(0, x)`; `divTrunc` adds `DivisionByZero` (and `Overflow` for `minInt / -1`); `powi` has its own set, `Overflow` and `Underflow`, and the `catch |err| switch (err)` maps both onto our `Overflow`: translating a callee's errors into the caller's vocabulary is what that form is for.
- **`@rem`** is the remainder with the sign of the dividend, like C's `%` and Zig's `%` on known-sign operands; `-7 % 5` is `-2`. (`@mod`, lecture 3, would give 3.) The explicit `rhs == 0` check avoids `@rem`'s own safety panic on zero.
- **`@abs`** returns an unsigned type, `u64` for an `i64`, so `abs(minInt(i64))` is representable there and not as an `i64`. `std.math.cast(i64, x)` converts if the value fits and returns `null` if not; `orelse error.Overflow` turns the null into our error. That's the three-way idiom: a builtin that can't fail, a cast that may return null, an `orelse` that names the failure.
- **Switching on a union inside a switch on an enum:** `.call => |c| switch (c.function) { ... }` is a switch expression as a prong body, with `@min`/`@max` doing the comparison and `std.math.gcd` requiring unsigned arguments, hence `NegativeArgument`.
- **`EvaluateError = Parser.Error || EvalError`** is every error the pipeline can produce. It can't be named `Error`, because `Parser` already declares an `Error` inside the same file and Zig forbids shadowing: a name can't hide a name from an enclosing scope, even a type's declaration hiding a file's. The rule removes a whole class of confusion at the cost of a longer name.
- **`evaluate`** wires the stages: build a parser, parse, evaluate. `defer diagnostic.* = parser.diagnostic;` copies the parser's diagnostic to the caller's variable on every exit, success or failure, so a success leaves `null` there.
- **`describe`** switches on the merged set and must name every member. Add an error to either set and this function stops compiling until it has a sentence; that's the exhaustiveness check working across files.

### Code
`lecture_4/src/calc.zig`, part 3:
```zig
// Evaluation

/// Everything evaluation can fail with. Arithmetic is checked: the standard library's add, sub, mul and
/// powi return error.Overflow instead of wrapping.
pub const EvalError = error{
    Overflow,
    DivisionByZero,
    WrongArgumentCount,
    NegativeArgument,
};

pub fn eval(node: *const Node) EvalError!i64 {
    switch (node.*) {
        .number => |n| return n,
        .negate => |inner| return std.math.negate(try eval(inner)),
        .binary => |b| {
            const lhs = try eval(b.lhs);
            const rhs = try eval(b.rhs);
            return switch (b.op) {
                .add => std.math.add(i64, lhs, rhs),
                .sub => std.math.sub(i64, lhs, rhs),
                .mul => std.math.mul(i64, lhs, rhs),
                .div => if (rhs == 0) error.DivisionByZero else std.math.divTrunc(i64, lhs, rhs),
                .rem => if (rhs == 0) error.DivisionByZero else @rem(lhs, rhs),
                // powi has its own error set; the switch maps every member onto ours.
                .pow => std.math.powi(i64, lhs, rhs) catch |err| switch (err) {
                    error.Overflow, error.Underflow => return error.Overflow,
                },
            };
        },
        .call => |c| switch (c.function) {
            .abs => {
                if (c.args.len != 1) return error.WrongArgumentCount;
                const value = try eval(c.args[0]);
                // @abs of the most negative i64 doesn't fit back into an i64.
                return std.math.cast(i64, @abs(value)) orelse error.Overflow;
            },
            .min, .max => {
                if (c.args.len == 0) return error.WrongArgumentCount;
                var result = try eval(c.args[0]);
                for (c.args[1..]) |arg| {
                    const value = try eval(arg);
                    result = if (c.function == .min) @min(result, value) else @max(result, value);
                }
                return result;
            },
            .gcd => {
                if (c.args.len != 2) return error.WrongArgumentCount;
                const a = try eval(c.args[0]);
                const b = try eval(c.args[1]);
                if (a < 0 or b < 0) return error.NegativeArgument;
                if (a == 0 and b == 0) return 0;
                return @intCast(std.math.gcd(@as(u64, @intCast(a)), @as(u64, @intCast(b))));
            },
        },
    }
}

// The whole pipeline

/// Every error the calculator can produce: the parser's set merged with the evaluator's. (It can't be
/// called `Error`: Zig forbids shadowing, and Parser already declares an `Error` inside this file.)
pub const EvaluateError = Parser.Error || EvalError;

/// Parses and evaluates one expression. `diagnostic` receives the position and message when parsing
/// fails, and is left null otherwise. Nodes are allocated from `arena`, which the caller resets or frees.
pub fn evaluate(arena: Allocator, source: [:0]const u8, diagnostic: *?Parser.Diagnostic) EvaluateError!i64 {
    var parser = Parser.init(arena, source);
    // Runs on every exit, so the diagnostic is handed back whether or not parsing succeeded.
    defer diagnostic.* = parser.diagnostic;
    const root = try parser.parse();
    return eval(root);
}

/// A sentence for each error. A switch on an error set must cover every member, so adding an error to
/// Parser.Error or EvalError without a sentence here is a compile error.
pub fn describe(err: EvaluateError) []const u8 {
    return switch (err) {
        error.UnexpectedToken => "a token appears where the grammar doesn't allow it",
        error.UnexpectedEnd => "the expression ends too soon",
        error.InvalidNumber => "a number literal doesn't fit in 64 bits",
        error.UnknownFunction => "the function isn't one of min, max, abs, gcd",
        error.OutOfMemory => "the arena couldn't allocate a node",
        error.Overflow => "a result doesn't fit in 64 bits",
        error.DivisionByZero => "division or remainder by zero",
        error.WrongArgumentCount => "the function was given the wrong number of arguments",
        error.NegativeArgument => "gcd needs non-negative arguments",
    };
}
```

## 4.8 Tests

### Why
A parser's tests are a list of inputs with their expected trees or values, plus a list of inputs with their expected errors. `std.testing.expectError` makes the second list as short as the first.

### How
- **`run`** is a helper that builds an arena on the testing allocator, evaluates, and frees. Returning `EvaluateError!i64` lets `try run(...)` and `expectError(..., run(...))` both work.
- **The tokens test** walks an expected sequence of tags with a `for` over an array literal of enum literals, and checks that `.eof` repeats.
- **Precedence** tests pin the grammar: multiplication over addition, parentheses, right-associative `^`, left-associative `-`, unary minus, and the sign of `%`.
- **Error tests** use `expectError(error.X, expr)`: it fails if the expression succeeds or fails with a different error. The `abs` case constructs `minInt(i64)` as `-9223372036854775807 - 1`, because the literal `9223372036854775808` doesn't fit an `i64` before the minus is applied.
- **Diagnostics** are checked by position: `foo` in `1 + foo(2)` starts at column 4 (0-based), and the missing `)` in `(1 + 2` is reported at position 6, where the `eof` token is. The success case checks the diagnostic was reset to `null`; `expectEqual(null, diagnostic)` compares an optional with null.
- **The last test** checks what 4.1 claimed: the name of an error is a string, and a value of a subset is equal to the same name in the superset.

### Code
`lecture_4/src/calc.zig`, part 4:
```zig
// Tests

test "tokens" {
    var tokenizer = Tokenizer.init("12 + max(x_1, 3)");
    const expected = [_]Token.Tag{ .number, .plus, .identifier, .l_paren, .identifier, .comma, .number, .r_paren, .eof };
    for (expected) |tag| {
        try std.testing.expectEqual(tag, tokenizer.next().tag);
    }
    // After the end, next() keeps returning eof.
    try std.testing.expectEqual(.eof, tokenizer.next().tag);
}

/// Evaluates with a fresh arena, for the tests.
fn run(source: [:0]const u8) EvaluateError!i64 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?Parser.Diagnostic = null;
    return evaluate(arena.allocator(), source, &diagnostic);
}

test "precedence and associativity" {
    try std.testing.expectEqual(14, try run("2 + 3 * 4"));
    try std.testing.expectEqual(20, try run("(2 + 3) * 4"));
    try std.testing.expectEqual(512, try run("2 ^ 3 ^ 2"));
    try std.testing.expectEqual(1, try run("10 - 4 - 5"));
    try std.testing.expectEqual(-10, try run("-(2 + 3) * 2"));
    try std.testing.expectEqual(-2, try run("-7 % 5")); // % truncates like C: @rem, not @mod
}

test "functions" {
    try std.testing.expectEqual(5, try run("max(1, 2 + 3, 4)"));
    try std.testing.expectEqual(-3, try run("min(-3, 0)"));
    try std.testing.expectEqual(3, try run("abs(-3)"));
    try std.testing.expectEqual(6, try run("gcd(12, 18)"));
    try std.testing.expectEqual(7, try run("gcd(0, 7)"));
}

test "evaluation errors" {
    try std.testing.expectError(error.DivisionByZero, run("1 / (2 - 2)"));
    try std.testing.expectError(error.Overflow, run("9223372036854775807 + 1"));
    try std.testing.expectError(error.Overflow, run("2 ^ 64"));
    try std.testing.expectError(error.Overflow, run("abs(-9223372036854775807 - 1)"));
    try std.testing.expectError(error.WrongArgumentCount, run("abs(1, 2)"));
    try std.testing.expectError(error.NegativeArgument, run("gcd(-4, 6)"));
}

test "parse errors come with a position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?Parser.Diagnostic = null;

    try std.testing.expectError(error.UnknownFunction, evaluate(arena.allocator(), "1 + foo(2)", &diagnostic));
    try std.testing.expectEqual(4, diagnostic.?.position);
    try std.testing.expectEqualStrings("unknown function", diagnostic.?.message);

    try std.testing.expectError(error.UnexpectedEnd, evaluate(arena.allocator(), "1 +", &diagnostic));
    try std.testing.expectError(error.InvalidNumber, evaluate(arena.allocator(), "99999999999999999999", &diagnostic));
    try std.testing.expectError(error.UnexpectedToken, evaluate(arena.allocator(), "(1 + 2", &diagnostic));
    try std.testing.expectEqual(6, diagnostic.?.position);

    // A success leaves no diagnostic behind.
    try std.testing.expectEqual(3, try evaluate(arena.allocator(), "1 + 2", &diagnostic));
    try std.testing.expectEqual(null, diagnostic);
}

test "errors are values with names" {
    const err: EvaluateError = error.DivisionByZero;
    try std.testing.expectEqualStrings("DivisionByZero", @errorName(err));
    // An EvalError coerces to the merged set, which is a superset.
    const widened: EvaluateError = @as(EvalError, error.Overflow);
    try std.testing.expectEqual(error.Overflow, widened);
}
```

## 4.9 The program

### Why
The driver is where the policy lives: which errors are reported to the user and how, and which end the program. `evaluateLine` handles every error the calculator can produce, except the one it can't do anything about.

### How
- **The batch** is a multiline literal with a dozen expressions, half of them wrong on purpose. `main` splits it on newlines and evaluates each.
- **`dupeSentinel(u8, line, 0)`** copies a line into the arena with a 0 byte after it, which is what the tokenizer requires. The copy lives in the arena along with the tree.
- **The three-way switch.** `if (calc.evaluate(...)) |value| ... else |err| switch (err)` handles the whole `EvaluateError` set: `OutOfMemory` is returned (the `return err` inside the prong propagates it from `evaluateLine`, and `main`'s `try` ends the program), parse errors print the diagnostic's position (`diagnostic.?` asserts it was set, which the parser guarantees for those four errors) as a 1-based column, and evaluation errors print `describe`'s sentence. A new error in either set is a compile error here. That's the lecture in one function: the compiler knows every way this can fail, and makes the program say what it does about each.
- **`arena.reset(.retain_capacity)`** frees every node from this line and keeps the memory for the next: one allocation for the first line, none after. `_ =` discards its `bool` result (whether the reset succeeded in shrinking).
- **Command-line arguments:** `init.minimal.args.toSlice(init.arena.allocator())` gives the arguments as slices, allocated in the process arena that's freed at exit. `zig build run -- "2 ^ 20"` passes arguments through the build system. `--fail` calls a function three frames deep that returns an error, and `return fail();` passes it out of `main`.
- **Error return traces.** An error returned from `main` prints the error's name, the *error return trace* (every `return error` and `try` the error passed through, with file and line), and exits with status 1. It's not a stack trace: it shows the path the error took, including through functions that have already returned. Debug builds record it; release builds don't, and `std.debug.dumpErrorReturnTrace` can print it from a `catch` while debugging.

### Code
`lecture_4/src/main.zig`, part 5:
```zig
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
```

## 4.10 Running it

### How
From `lecture_4/`:
```bash
zig build run -- "2 ^ 20" "gcd(9, 6)" "min()"
```
```text
Errors are values:
    MissingFile is named 'MissingFile' and numbered 179; an error is 2 bytes
    as LoadError: MissingFile; cast back: MissingFile; equal: true
    anyerror holds Timeout too
Handling:
    try/catch default: 42, 0
    caught Overflow, using the maximum instead
    c = 4294967295
    '7' -> 14
    'x7' isn't a number
    '70000000000' is too big, or its double is
    '9999999999' is too big, or its double is
    as error unions: 24 and error.InvalidCharacter
    demoHandling is failing, and errdefer saw it
    main saw InvalidCharacter from demoHandling and carries on
Optionals and errors:
    found 42
    none found, fallback 0
    '7up' gives error.InvalidCharacter
    '1 + 2' is 3 words
    web: port 8080
    worker: no port
Unions:
    bare is 16 bytes, holding 2.5
    1.0f as bits: 0x3f800000 (an extern union reinterprets, like @bitCast)
    circle with area 3.14; tag as enum: circle
    square with area 4.00; tag as enum: square
    after doubling the radius and growing the square: 12.57, 9.00
    active tag of the first: circle; a Shape is 16 bytes (payload plus tag)

The batch:
  1 + 2 * 3                    = 7
  (1 + 2) * 3                  = 9
  2 ^ 10 - 24                  = 1000
  -7 % 5                       = -2
  max(3, 1 + 1, abs(-9))       = 9
  gcd(84, 36)                  = 12
  9223372036854775807 + 1        error.Overflow: a result doesn't fit in 64 bits
  1 / (3 - 3)                    error.DivisionByZero: division or remainder by zero
  2 +                            error.UnexpectedEnd at column 4: the expression ends too soon
  sqrt(2)                        error.UnknownFunction at column 1: unknown function
  (1 + 2                         error.UnexpectedToken at column 7: expected ')'
  99999999999999999999           error.InvalidNumber at column 1: number doesn't fit in 64 bits

From the command line:
  2 ^ 20                       = 1048576
  gcd(9, 6)                    = 3
  min()                          error.WrongArgumentCount: the function was given the wrong number of arguments
```
The error number (179) depends on how many errors the whole program declares, and changes as code changes; it's shown only to make the point that it is a number. `zig build run -- --fail` ends with:
```text
error: RequestedFailure
.../lecture_4/src/main.zig:239:5: 0x... in innerFail (main.zig)
    return error.RequestedFailure;
    ^
.../lecture_4/src/main.zig:235:5: 0x... in fail (main.zig)
    return innerFail();
    ^
.../lecture_4/src/main.zig:270:49: 0x... in main (main.zig)
            if (std.mem.eql(u8, arg, "--fail")) return fail();
                                                ^
```
and exit status 1, which `zig build` reports as the run step failing.

`zig build test` runs the seven tests (six in `calc.zig`, plus the discovery block). Two experiments: add `.mod` to `Node.Op` and the compiler lists every `switch` that stops being exhaustive, `precedence`, `fromToken` and `eval`; add `error.TooDeep` to `Parser.Error` and `describe` and `evaluateLine` both refuse to compile until they say what to do with it. Then remove the explicit `Error!` from `parseExpression` and watch the compiler explain why a recursive function can't infer its error set.
