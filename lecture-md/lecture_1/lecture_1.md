# Lecture 1: Fundamentals

By the end of this lecture we'll have a vending machine: a program that takes coins, sells cola, chips and candy, gives change, refunds on request, and runs out of stock. It's a *state machine*: at any moment it's in one state (idle, collecting money, dispensing), and each event (a coin, a button) moves it to the next. Before the machine, the program takes a short tour of Zig's primitive types.

A state machine is the right first program for Zig, because it shows off what Zig does differently from C from the very start:
- **Tagged unions.** A Zig `union(enum)` is a C union with a tag the compiler manages: each field is one case, each case can carry its own data, and the data of a case can only be read after a `switch` has checked that it's the active one. `Event{ .coin = 25 }` carries its value, and `State{ .collecting = 125 }` carries the money inserted so far.
- **Exhaustive `switch`.** `switch` takes values apart and refuses to compile if a case is missing. Add a product, and every `switch` over products stops compiling until it's handled.
- **Everything is an expression.** `if`, `switch`, labeled blocks and loops produce values, so most variables are assigned once, and `const`.
- **Nothing hidden.** There's no hidden control flow (no exceptions, no destructors running behind a `}`), and no hidden allocation: a function that needs memory takes an allocator as a parameter. Lecture 2 is about that. Here, the whole program runs without allocating.
- **`comptime`.** Zig code can run while compiling. The machine checks at compile time that every price is a multiple of its smallest coin.
- **One tool.** The `zig` compiler is also the build system, the test runner, the formatter and a C compiler.

Along the way we cover the basics every later lecture stands on: primitive types and conversions, `const` and `var`, functions, `while` and `for`, structs and methods, `defer`, the standard library's `Writer`, and the `test` block.

The whole program is one file, `lecture_1/src/main.zig`. Each section below explains the next part of it; typed in order, the parts make up the complete file.

## 1.1 The toolchain and the project

### Why
Zig ships as one archive with no dependencies: the compiler, the standard library (as source), the build system, a C and C++ compiler, and the documentation. Every lecture in this course is its own small program, and we want them side by side in one repository, built the same way, without repeating the setup in each one.

### How
- **Installing:** download Zig 0.17.1 for your platform from <https://ziglang.org/download/>, unpack it anywhere, and put the directory on your `PATH`. There's nothing else to install. This course is written against 0.17.1; Zig is still changing between releases, so a different version will reject some of this code.
- **The commands we'll use all course:**
  - `zig init`: a new package in the current directory: `build.zig`, `build.zig.zon`, `src/main.zig` and `src/root.zig`. Every lecture here started from it, trimmed down.
  - `zig build`: run the build script, which compiles the program into `zig-out/bin/`. `zig build run` builds and runs it; `zig build test` builds and runs its tests. `-Doptimize=fast` (or `safe`, `small`) picks an optimization mode; `debug` is the default. `zig build --help` lists the steps and options a build script offers.
  - `zig fmt file.zig`: format a file the one standard way. There are no options, so there's nothing to argue about; the editor runs it on save. `zig fmt --check` only reports.
  - `zig run file.zig` and `zig test file.zig`: compile and run a single file, or its tests, with no build script. Handy for experiments.
  - `zig build-exe`, `zig build-lib`, `zig build-obj`: compile without a build script. The build system calls these for us.
  - `zig std`: serves the standard library's documentation in the browser, generated from the source you have. The language reference is at `doc/langref.html` inside the installation, and online at <https://ziglang.org/documentation/0.17.1/>.
  - `zig cc` and `zig c++`: a C and C++ compiler (clang), which can cross-compile to any target Zig supports. Lecture 9 uses it to build a C library.
- **A package per lecture.** Zig's unit of distribution is a *package*: a directory with a `build.zig` build script and a `build.zig.zon` manifest. Each `lecture_N/` is one, so `zig build` inside it builds that lecture, and each lecture's `build.zig` can grow its own steps (C sources, dependencies) without touching the others. `build.bash` at the root is a menu over them.
- **`build.zig`** is a Zig program. `zig build` compiles it and calls its `build` function with a `*std.Build`. The function doesn't build anything itself: it declares a *graph of steps* (compile this, install that, run the other), and the build runner executes the steps that the requested step depends on, in parallel where it can, caching what hasn't changed.
  - `b.standardTargetOptions` and `b.standardOptimizeOption` add the `-Dtarget` and `-Doptimize` command-line options, and return what the user chose: the host machine and `debug` by default. Cross-compiling is changing one flag.
  - `b.createModule` describes a *module*: a set of Zig source files rooted at one file (`src/main.zig`), plus a target and an optimization mode. Other files are found from it through `@import`, so no list of sources is kept anywhere.
  - `b.addExecutable` makes a compile step whose output is an executable named `lecture_1`, built from that module. `b.installArtifact` makes the default step copy it to `zig-out/bin/`.
  - `b.addRunArtifact` makes a step that runs the executable; `b.step("run", ...)` names a top-level step the user can ask for, and `dependOn` connects them. `addPassthruArgs` forwards anything after `--` on the command line to the program.
  - `b.addTest` makes a compile step that builds every `test` block reachable from the module's root into a test runner; running it is the `test` step.
- **`build.zig.zon`** is the manifest, in ZON (Zig Object Notation: a Zig anonymous struct literal as a data format). It names the package, gives it a version, records the oldest Zig it supports, lists the files that belong to it, and (from lecture 7) its dependencies. The *fingerprint* is a random id the compiler generates on the first build; it identifies the package across versions and renames, so it's never edited by hand.
- **`.gitignore`** keeps `zig-out/` (the built programs) and `.zig-cache/` (the compiler's cache) out of git.
- **The editor:** ZLS (the Zig Language Server, <https://github.com/zigtools/zls>) gives completion and diagnostics in any editor with LSP support; the VS Code / VSCodium extension is "Zig Language". ZLS reads `build.zig`, so it needs no configuration.

### Code
At the repo root:
`.gitignore`:
```text
# Build output and the compiler's cache, for every lecture.
zig-out/
.zig-cache/
```

From the repo root:
```bash
mkdir -p lecture_1/src
```

`lecture_1/build.zig`:
```zig
const std = @import("std");

// The build script is a Zig program. `zig build` compiles and runs it, and the build() function
// describes a graph of steps (compile, install, run, test) that the build runner then executes.
pub fn build(b: *std.Build) void {
    // -Dtarget=... and -Doptimize=... on the command line; the host and debug by default.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // One module (a set of Zig source files rooted at main.zig) compiled into one executable.
    const exe = b.addExecutable(.{
        .name = "lecture_1",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // Copy the executable into zig-out/bin/ when the default step runs.
    b.installArtifact(exe);

    // `zig build run [-- args]`: build, install, then run the installed executable.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run the lecture").dependOn(&run_cmd.step);

    // `zig build test`: compile every `test` block reachable from main.zig into a test runner, and run it.
    const tests = b.addTest(.{ .root_module = exe.root_module });
    b.step("test", "Run the lecture's tests").dependOn(&b.addRunArtifact(tests).step);
}
```

`lecture_1/build.zig.zon` (the first `zig build` prints the fingerprint to paste in):
```zig
.{
    .name = .lecture_1,
    .version = "0.1.0",
    .fingerprint = 0x3c5d9eac8387eb83, // Changing this has security and trust implications.
    .minimum_zig_version = "0.17.1",
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

## 1.2 Primitive types

### Why
Every value in Zig has a type, and every type has a fixed representation: a size in bytes and a meaning for each bit. Zig is strict about types: there are no implicit conversions between number types, and integer overflow is a bug. A short tour prints sizes, bits and conversions, and the vending machine relies on all of them.

### How
- **`@import("std")`** brings in the standard library as a value, a struct whose fields are its namespaces: `std.debug`, `std.fmt`, `std.mem`. Every `.zig` file is a struct too (lecture 2 uses that), and `@import` of a file gives that struct. Names beginning with `@` are *builtins*: functions the compiler provides, like `@sizeOf` and `@bitCast`.
- **Functions:** `fn name(params) ReturnType { ... }`. Parameter and return types are always written out. `!void` is an *error union*: the function returns nothing, or an error. Every function here that writes output can fail, because writing can.
- **The primitive types:**
  - `bool`: `true` or `false`. It takes a byte in memory (`@sizeOf`), but carries one bit of information (`@bitSizeOf`).
  - Integers: `u8`, `i32`, `u64` and so on. `i` types are signed, `u` types unsigned, and the number is the width in bits. Any width from 0 to 65535 is a type: `u3` holds 0 to 7, `i7` holds -64 to 63. In memory they round up to whole bytes.
  - `usize` and `isize`: the integer the size of an address, 8 bytes on a 64-bit machine. Lengths and indexes are `usize`.
  - `f16`, `f32`, `f64`, `f80`, `f128`: floating point. `f64` has about 16 significant digits.
  - `comptime_int` and `comptime_float`: the types of literals. A literal `7` has no width; it's exact, and becomes whatever type it's used as. `const x = 7;` is a comptime_int that lives only in the compiler; `const x: u8 = 7;` is a byte.
- **`std.Io.Writer`** is the standard library's output interface. Its `print` takes a *format string* and a tuple of arguments, `.{ a, b }`: each `{...}` is replaced by the next argument. The letter after `{` says how: `{d}` decimal, `{x}` hex, `{s}` a string, `{t}` an enum's tag name, `{any}` anything in its default form, `{}` the default for numbers and bools. After a `:` come fill, alignment, width and precision: `{x:0>8}` is hex, zero-filled, right-aligned in 8 columns; `{d:.2}` is two decimals; `{s:<20}` is left-aligned in 20 columns. `{{` and `}}` print braces. The format string is checked against the arguments while compiling: a `{d}` too many is a compile error.
- **Representation:** every value is bits, and a few builtins show them:
  - `@intFromBool(true)` is `1`.
  - `'A'` is `65`: a character literal is its Unicode *code point*, a `comptime_int`. `'é'` is 233, and the string `"é"` is two bytes long: strings are UTF-8, and a code point above 127 takes several bytes. Lecture 3 covers strings.
  - `std.mem.toBytes(x)` is an array of an integer's bytes, in memory order. 300 is `0x012c`, and x86 and ARM are *little-endian* (lowest byte first), so the array is `{ 44, 1, 0, 0 }`.
  - `@bitCast` reinterprets bits as another type of the same size. `-1` as a `u32` is the largest `u32`: signed integers are stored in *two's complement*, where -1 is all ones. `1.0` as a `u32` is `0x3f800000`: a float is a sign bit, an exponent and a fraction (IEEE 754), nothing like the integer 1.
- **`@as(T, value)`** gives a literal a type without declaring a variable: `@as(i32, 300)`.
- **`const`** declares a constant; **`var`** a variable, which must be changed somewhere or the compiler rejects it. A declared name must be used, or discarded with `_ = name;`, or it's an error too. Types are inferred from the initializer, or written: `const one: f32 = 1.0;`. The two `const` locals here exist so that the casts have a typed, runtime value to work on.

### Code
`lecture_1/src/main.zig`, part 1:
```zig
const std = @import("std");

// Primitive types

/// Prints the size of a few primitive types. @sizeOf is the size in bytes, as the type is laid out in
/// memory; @bitSizeOf is the number of bits that carry information, which differs for bool and the
/// odd-width integers.
fn printSizes(out: *std.Io.Writer) !void {
    try out.print("bool {d} byte ({d} bit), u8 {d}, u3 {d} byte ({d} bits), i32 {d}, u64 {d}, usize {d}, f64 {d}\n", .{
        @sizeOf(bool),  @bitSizeOf(bool),
        @sizeOf(u8),    @sizeOf(u3),
        @bitSizeOf(u3), @sizeOf(i32),
        @sizeOf(u64),   @sizeOf(usize),
        @sizeOf(f64),
    });
}

/// Every value is stored as bits, and a few builtins show them without any special tools.
fn printRepresentation(out: *std.Io.Writer) !void {
    // @intFromBool turns true into 1 and false into 0.
    try out.print("@intFromBool(true) = {d}, @intFromBool(false) = {d}\n", .{ @intFromBool(true), @intFromBool(false) });

    // A character literal is just an integer: its Unicode code point. 'é' is 233, which needs two bytes in UTF-8.
    try out.print("'A' = {d}, 'é' = {d}, \"é\".len = {d}: a code point, and its UTF-8 bytes\n", .{ 'A', 'é', "é".len });

    // std.mem.toBytes copies an integer into an array of its bytes, in memory order. 300 is 0x012c, and this
    // machine is little-endian (lowest byte first), so the bytes are { 44, 1, 0, 0 }.
    try out.print("std.mem.toBytes(@as(i32, 300)) = {any}: lowest byte first\n", .{std.mem.toBytes(@as(i32, 300))});

    // @bitCast keeps the bits and changes the type. Signed integers are two's complement: -1 is all ones.
    const minus_one: i32 = -1;
    try out.print("@bitCast(-1 as i32) as u32 = {d}: two's complement, all bits set\n", .{@as(u32, @bitCast(minus_one))});

    // A float is a sign bit, an exponent and a fraction (IEEE 754), nothing like the integer 1.
    const one: f32 = 1.0;
    try out.print("@bitCast(1.0 as f32) as u32 = 0x{x:0>8}: sign, exponent and fraction\n", .{@as(u32, @bitCast(one))});
}
```

## 1.3 Conversions, overflow and odd integers

### Why
Most surprises in everyday arithmetic come from implicit conversions and silent overflow. Zig has neither: a conversion that can lose information is a named builtin, and an overflow in a debug build stops the program with a message. The vending machine counts cents in a `u32` and stock in a `u8`, so both rules matter to it.

### How
- **Result locations.** Many builtins don't take the target type as an argument. `@floatFromInt(x)` produces "a float", and the compiler reads *which* float from where the value goes: `const as_float: f64 = @floatFromInt(seven);` makes an `f64`. When nothing says, `@as` does: `@as(u8, @truncate(big))`. The language calls this *result location semantics*, and it's how most type inference in Zig works.
- **Coercion** happens only where it can't lose anything: a `u8` becomes an `i32` on its own (`const widened: i32 = byte;`), a literal becomes any type that fits it, a `*const [5:0]u8` string literal becomes a `[]const u8`. Everything else is explicit.
- **Division:** `/` on integers truncates, and only works when the result can't be ambiguous: both operands comptime-known, or unsigned. For runtime signed integers `-7 / 2` doesn't compile; `@divTrunc(-7, 2)` is `-3` (toward zero) and `@divFloor(-7, 2)` is `-4` (toward minus infinity). `%` has the same rule, with `@rem` and `@mod`.
- **Casts:**
  - `@floatFromInt` and `@intFromFloat` convert between integers and floats. `@intFromFloat` truncates toward zero, and a value outside the integer's range is a *safety-checked* bug: a panic in debug and safe builds.
  - `@intCast` narrows an integer, and panics if the value doesn't fit. `@truncate` keeps the low bits instead: `0x12345678` as a `u8` is `0x78`.
  - `@bitCast` reinterprets, as in 1.2.
- **Overflow is a bug.** `x + 1` when `x` is a `u8` holding 255 is *illegal behavior*: a debug or safe build panics with "integer overflow", a fast build does whatever's fastest. Zig calls that *safety-checked illegal behavior*: the check exists, and the optimization mode decides whether it's compiled in. To wrap or clamp on purpose, there are operators for it:
  - `+%`, `-%`, `*%` wrap around: `255 +% 1` is `0`.
  - `+|`, `-|`, `*|` saturate: `255 +| 1` is `255`.
  - `@addWithOverflow(a, b)` returns a tuple of the wrapped result and a `u1` overflow bit, for arithmetic that checks itself.
- **Destructuring:** `const sum, const overflowed = @addWithOverflow(max, 1);` takes a tuple (or array) apart into two constants.
- **Odd widths:** `u3`, `i7`, `u24` are real types, and `std.math.maxInt(T)` is the largest value of any integer type. A literal that doesn't fit, `@as(u3, 8)`, is a compile error. Lecture 2 packs several small integers into one byte with them.
- **Digit separators:** `0x1234_5678`: an underscore anywhere inside a number literal is ignored.

### Code
`lecture_1/src/main.zig`, part 2:
```zig
/// Zig never converts between number types by itself, and every conversion that can lose information
/// is spelled out with a builtin.
fn printConversions(out: *std.Io.Writer) !void {
    // Integer literals are comptime_int: exact, unlimited, and converted to the type they're used as.
    // 7 / 2 on two integers is 3, and only because both are comptime-known and positive: dividing
    // runtime signed integers needs @divTrunc or @divFloor, which say what happens to the sign.
    const seven: i32 = 7;
    const minus_seven: i32 = -7;
    try out.print("7 / 2 = {d}, @divTrunc(-7, 2) = {d}, @divFloor(-7, 2) = {d}\n", .{ 7 / 2, @divTrunc(minus_seven, 2), @divFloor(minus_seven, 2) });

    // Integer to float: @floatFromInt; float to integer: @intFromFloat, which truncates toward zero. The
    // target type comes from the result location, here the type of the variable on the left.
    const as_float: f64 = @floatFromInt(seven);
    const truncated: i32 = @intFromFloat(3.99 * as_float / as_float);
    try out.print("@floatFromInt(7) / 2.0 = {d}, @intFromFloat(3.99) = {d}\n", .{ as_float / 2.0, truncated });

    // Widening coerces for free: a u8 always fits an i32. Narrowing needs @intCast, which is
    // safety-checked: a value that doesn't fit panics in a debug build. @truncate keeps the low bits instead.
    const byte: u8 = 200;
    const widened: i32 = byte;
    const big: u32 = 0x1234_5678;
    try out.print("u8 200 as i32 = {d}, @intCast(300 as u16) = {d}, @truncate(0x12345678) as u8 = 0x{x}\n", .{
        widened, @as(u8, @intCast(@as(u16, 300) - 100)), @as(u8, @truncate(big)),
    });

    // Overflow is a bug: `x + 1` on a u8 holding 255 panics in a debug build. The wrapping (+%) and
    // saturating (+|) operators ask for the other behaviours, and @addWithOverflow reports the carry.
    const max: u8 = 255;
    const sum, const overflowed = @addWithOverflow(max, 1);
    try out.print("255 +% 1 = {d}, 255 +| 1 = {d}, @addWithOverflow(255, 1) = {{ {d}, {d} }}\n", .{ max +% 1, max +| 1, sum, overflowed });

    // Integers come in any width from u0 to u65535. A u3 holds 0..7; the compiler rejects a literal 8.
    const three_bits: u3 = 7;
    try out.print("u3 holds up to {d}; std.math.maxInt(u3) = {d}, maxInt(i7) = {d}\n", .{ three_bits, std.math.maxInt(u3), std.math.maxInt(i7) });
}
```

## 1.4 Modelling with enums and tagged unions

### Why
A vending machine is described by a few kinds of things: the products, the events that happen to it, the states it can be in, and what each event did. Each is a fixed set of cases, and some cases carry data. In C we'd write an `enum` for the kind and a `struct` or `union` for the data, and keep the two in step by hand. In Zig, an `enum` is a set of names with methods, and a `union(enum)` is a union whose active field the compiler tracks for us.

### How
- **Comments:** `//` is a comment for the reader. `///` is a *doc comment*: it documents the declaration below it, and the documentation generator and ZLS pick it up. `//!` at the top of a file documents the file.
- **`pub`:** every declaration is private to its file unless marked `pub`. The types here are `pub` so a test in another file could use them; nothing else in this lecture needs to be.
- **`const Product = enum { ... }`:** a type is a value, declared with `const` like any other. Zig has no `typedef`: `Product` is a constant that holds a type. Types are written in TitleCase, values and functions in camelCase, and that's enforced only by convention.
- **An enum** has named values, `.cola`, `.chips`, `.candy`, and may also hold declarations: a method `price` and a constant `all`. A method is a function whose first parameter is the type (or a pointer to it); `product.price()` and `Product.price(product)` are the same call.
- **Enum literals:** `.cola` on its own has type `@EnumLiteral()`, and becomes a `Product` wherever a `Product` is expected: in a `switch` prong, as an argument, in `== .dispensing`. So the enum's name is rarely repeated.
- **`std.enums.values(Product)`** is an array of every value of the enum, computed at compile time. The `for` loop over it in `main` walks the menu.
- **`switch` as an expression:** `price` returns the value of the `switch`. The prongs must cover every product, or the code doesn't compile: add a `.water` to the enum, and `price` fails to build until it has a price.
- **A `comptime` block** runs while compiling, and only then. The one here loops over the products and asserts each price is a multiple of 5 (the smallest coin). `std.debug.assert` that fails at compile time is a compile error with the location, so a bad price can't be built.
- **Tagged unions.** `union(enum)` declares a union and, with it, an enum of its field names: the *tag*. A value holds one field at a time, and the tag says which. `Event{ .coin = 25 }` holds a `u32` under `.coin`; reading `event.select` while the tag is `.coin` is safety-checked illegal behavior. A field with no type, `cancel,`, has type `void`: a case with no data. Written as a literal it's just `.cancel`, and `.{ .coin = 25 }` builds a case with data when the type is known from context.
- **Struct payloads:** `dispensing: struct { product: Product, change: u32 }` gives a case named fields, declared inline. `State{ .dispensing = .{ .product = .cola, .change = 10 } }` builds one.
- **The tag in memory:** a tagged union is the largest field's bytes plus the tag, usually an integer; `@sizeOf(State)` is 12 here. `switch` reads the tag, and that's the only way code can reach a field.
- **Trailing commas** are the norm: a comma after the last field makes `zig fmt` put each field on its own line.

### Code
`lecture_1/src/main.zig`, part 3:
```zig
// The vending machine

/// What the machine sells. An enum's values are named, not numbers, and a `switch` over one must
/// name every value. Enums hold methods and constants too.
pub const Product = enum {
    cola,
    chips,
    candy,

    /// Every product, for walking the menu with a for loop. std.enums.values returns the
    /// enum's values as an array, computed at compile time.
    pub const all = std.enums.values(Product);

    /// The price in cents. Money is counted in whole cents, so it never rounds.
    pub fn price(self: Product) u32 {
        return switch (self) {
            .cola => 125,
            .chips => 100,
            .candy => 65,
        };
    }
};

// Checked while compiling: the machine only takes nickels and up, so every price must be a multiple
// of 5. A comptime block runs at compile time, and a failed assert there is a compile error.
comptime {
    for (Product.all) |product| {
        std.debug.assert(product.price() % 5 == 0);
    }
}

/// Something that happens to the machine. A tagged union: each field is one kind of event, and
/// the fields can carry data. `coin` carries its value in cents, and `select` a product.
/// `cancel`, `take_item` and `service` carry nothing (their type is void).
pub const Event = union(enum) {
    coin: u32,
    select: Product,
    cancel,
    take_item,
    service,
};

/// What the machine is doing. `credit` exists only while collecting, and the dispensed product
/// only while dispensing: an idle machine has no credit to get wrong.
pub const State = union(enum) {
    idle,
    collecting: u32,
    dispensing: struct { product: Product, change: u32 },
};

/// What an event did, for the program to report.
pub const Outcome = union(enum) {
    accepted: u32,
    rejected: u32,
    need_more: u32,
    sold_out: Product,
    vended: struct { product: Product, change: u32 },
    refunded: u32,
    collected: Product,
    restocked,
    ignored,
};
```

## 1.5 The state machine

### Why
All the machine's behaviour is one function: given the current state and an event, produce the next state and an outcome. With tagged unions and `switch`, that function reads like the rules it implements, and the compiler checks that every combination of event and state has a rule.

### How
- **`struct Machine`** holds the state, the stock of each product, and the takings. Fields can have *default values*: `state: State = .idle` and `takings: u32 = 0` need no mention when a `Machine` is built, and `stock` must be given. Struct fields are always accessible; Zig has no `private`. Declarations without `pub` are private to the file, which is the unit of encapsulation.
- **No constructors:** a struct is created with a struct literal, `.{ .stock = ... }`, and nothing else runs. By convention, a type offers a function named `init` that builds one, and `deinit` to tear one down if it owns resources (lecture 2). `Machine.init(2)` is an ordinary function call.
- **`@splat(count)`** fills an array (or vector) with one value; the array's length and element type come from the result location, the `stock` field.
- **Indexing by enum:** `stock` has one `u8` per product, at index `@backingInt(product)`: the integer behind an enum value, 0, 1, 2 in declaration order. (`@intFromEnum` was the older name; `zig fmt` rewrites it.) `Product.all.len` keeps the array's size in step with the enum.
- **Methods and `self`:** `stockOf(self: Machine, ...)` takes the machine by value: it only reads. `takeOne(self: *Machine, ...)` takes a pointer, because it changes a field; a by-value `self` is a copy, and assigning to its field is a compile error ("cannot assign to constant"), since parameters are constants. `machine.takeOne(.cola)` passes `&machine` automatically when the method wants a pointer. Lecture 2 is about pointers.
- **`self.stock[...] -= 1`** on a `u8` holding 0 would be the overflow bug of 1.3, and a debug build would panic. The sold-out check in `handle` makes sure it never gets here.
- **Multi-value prongs:** `5, 10, 25, 100 => true` matches any of the four; `else` covers the rest. Ranges work too: `0...9` (inclusive on both ends).
- **Switching on a tagged union:** `switch (event)` has one prong per tag, and `|cents|` *captures* the payload of the active field as a constant. A prong with no capture, `.service`, ignores its payload. A prong may list several tags, `.idle, .dispensing =>`, when they share an action.
- **No tuple patterns:** Zig can't switch on two values at once, so `handle` switches on the event, and inside most prongs on the state. The compiler still checks exhaustiveness at both levels.
- **Everything is an expression:**
  - The whole `switch` has a value, a pair `(next state, outcome)` written as a tuple `.{ state, outcome }`, and `const next: State, const outcome: Outcome = switch ...` destructures it. The type annotations tell the tuple literals what to become.
  - `if (cond) a else b` is an expression too, and so is `if ... else if ... else`.
  - A *labeled block*, `blk: { ...; break :blk value; }`, runs statements and then produces a value, where a prong needs to do more than one thing. The label is any name; `blk` is the convention.
- **Reading `self.state` inside the switch** is fine: nothing is written until `self.state = next;` at the end, so every prong sees the state the event arrived in.
- **Exhaustiveness is the safety net.** Add an event to `Event`, and `handle` stops compiling until it says what the event does in every state. A catch-all `else` would silently ignore it, which is why none of the inner switches has one.

### Code
`lecture_1/src/main.zig`, part 4:
```zig
/// The machine: its state, its stock and the money it has taken.
pub const Machine = struct {
    state: State = .idle,
    /// One count per product, indexed by the integer behind the enum value, @backingInt(product).
    stock: [Product.all.len]u8,
    takings: u32 = 0,

    /// A machine holding `count` of each product. Zig has no constructors: init is a plain function,
    /// named by convention. The fields with defaults need no mention.
    pub fn init(count: u8) Machine {
        return .{ .stock = @splat(count) };
    }

    pub fn stockOf(self: Machine, product: Product) u8 {
        return self.stock[@backingInt(product)];
    }

    // *Machine: this method changes the machine, so it takes a pointer. `self.stock[...] -= 1` on a u8
    // holding 0 would be the overflow bug of printConversions, and a debug build would panic; the
    // sold-out check in handle() makes sure it never gets here.
    fn takeOne(self: *Machine, product: Product) void {
        self.stock[@backingInt(product)] -= 1;
    }

    /// Nickels, dimes, quarters and dollars. A switch is an expression; a prong can list several values.
    fn isValidCoin(cents: u32) bool {
        return switch (cents) {
            5, 10, 25, 100 => true,
            else => false,
        };
    }

    /// Handles one event: moves to the next state, and says what happened.
    pub fn handle(self: *Machine, event: Event) Outcome {
        // The switch on the event unwraps its payload with |cents|, |product|; a nested switch on the
        // state does the same. Every prong produces a (state, outcome) pair, which `const next, const outcome`
        // destructures. The compiler checks that every event is handled, and every state inside each event.
        const next: State, const outcome: Outcome = switch (event) {
            // A technician can always reset and refill the machine. This prong never looks at the old
            // state, so any credit in it is lost; only `cancel` reads the credit out and refunds it.
            .service => blk: {
                self.stock = @splat(5);
                break :blk .{ .idle, .restocked };
            },

            .coin => |cents| if (!isValidCoin(cents))
                // Any other coin, or any coin while dispensing, drops into the return tray.
                .{ self.state, .{ .rejected = cents } }
            else switch (self.state) {
                .idle => .{ .{ .collecting = cents }, .{ .accepted = cents } },
                .collecting => |credit| .{ .{ .collecting = credit + cents }, .{ .accepted = credit + cents } },
                .dispensing => .{ self.state, .{ .rejected = cents } },
            },

            .select => |product| switch (self.state) {
                .collecting => |credit| if (self.stockOf(product) == 0)
                    .{ self.state, .{ .sold_out = product } }
                else if (credit < product.price())
                    .{ self.state, .{ .need_more = product.price() - credit } }
                else blk: {
                    self.takeOne(product);
                    self.takings += product.price();
                    const change = credit - product.price();
                    break :blk .{ .{ .dispensing = .{ .product = product, .change = change } }, .{ .vended = .{ .product = product, .change = change } } };
                },
                // Selecting with no money in, or while an item waits to be taken, changes nothing.
                .idle, .dispensing => .{ self.state, .ignored },
            },

            .cancel => switch (self.state) {
                .collecting => |credit| .{ .idle, .{ .refunded = credit } },
                .idle, .dispensing => .{ self.state, .ignored },
            },

            .take_item => switch (self.state) {
                .dispensing => |d| .{ .idle, .{ .collected = d.product } },
                .idle, .collecting => .{ self.state, .ignored },
            },
        };

        self.state = next;
        return outcome;
    }
};
```

## 1.6 Change, and tests

### Why
Change is given in the fewest coins, which is easy to get subtly wrong. And a state machine has many paths through it: exactly the kind of code that needs tests. Zig's tests live next to the code they test, in `test` blocks, and `zig build test` runs them.

### How
- **Parameters are constants.** `cents` can't be decremented, so `var left = cents;` makes a variable copy first. That's the whole story of by-value parameters in Zig: the callee may get a copy or a pointer to the caller's value, whichever is faster, and it can't tell because it can't write to it.
- **`while (cond) : (step)`** runs the step after each iteration, like the third clause of a C `for`. Integer division and remainder do the dimes and nickels in one step each. `%` and `/` have the same precedence and work left to right, so `left % 10 / 5` is `(left % 10) / 5`.
- **Returning a tuple:** `struct { u32, u32, u32 }` is a *tuple type*, a struct whose fields are numbered. `.{ quarters, dimes, nickels }` builds one, and the caller destructures it: `const q, const d, const n = coinsFor(60);`.
- **Tests:**
  - **`test "name" { ... }`** is a test. `zig build test` compiles every test reachable from the module's root file into a test runner and runs each one; a test passes if it returns, and fails if it returns an error. Tests are never compiled into the program.
  - **`std.testing.expectEqual(expected, actual)`** returns an error if they differ, printing both; `try` turns that into the test's failure. It compares tagged unions by tag and payload, structs field by field, and the `expected` argument's type decides the comparison: `Outcome{ .rejected = 3 }` makes the second argument an `Outcome` too. `std.testing.expect(bool)` is the plain form.
  - **`for (0..4) |_|`**: `0..4` is a range, 0 up to but not including 4, and `|_|` ignores each value: "do this four times".
  - **`_ = machine.handle(...)`** discards a return value. Zig doesn't let a value fall on the floor; an unused result is a compile error unless it's assigned to `_`.
  - **What the tests check:** exact change, a rejected coin, a refund, a sold-out product, and the change-making. Each test makes its own machine, so they're independent.

### Code
`lecture_1/src/main.zig`, part 5:
```zig
// Change

/// Splits an amount into quarters, dimes and nickels, largest first, and returns the three counts as a
/// tuple (an anonymous struct whose fields are numbered). Parameters are constants, so `cents` is copied
/// into a `var` before it's changed.
pub fn coinsFor(cents: u32) struct { u32, u32, u32 } {
    var left = cents;
    var quarters: u32 = 0;
    while (left >= 25) : (left -= 25) {
        quarters += 1;
    }

    // Division and remainder do the same in one step each.
    const dimes = left / 10;
    const nickels = left % 10 / 5;
    return .{ quarters, dimes, nickels };
}

// Tests

// A `test` block is compiled only by `zig build test` (or `zig test`), never into the program. Each one
// runs, and passes unless it returns an error. `try` on an expect turns a failed check into an error.
test "exact change vends with nothing back" {
    var machine = Machine.init(1);
    for (0..4) |_| {
        _ = machine.handle(.{ .coin = 25 });
    }
    try std.testing.expectEqual(Outcome{ .vended = .{ .product = .chips, .change = 0 } }, machine.handle(.{ .select = .chips }));
    try std.testing.expectEqual(0, machine.stockOf(.chips));
}

test "bad coins are rejected and credit kept" {
    var machine = Machine.init(1);
    _ = machine.handle(.{ .coin = 10 });
    try std.testing.expectEqual(Outcome{ .rejected = 3 }, machine.handle(.{ .coin = 3 }));
    try std.testing.expectEqual(State{ .collecting = 10 }, machine.state);
}

test "cancel refunds everything" {
    var machine = Machine.init(1);
    _ = machine.handle(.{ .coin = 100 });
    _ = machine.handle(.{ .coin = 5 });
    try std.testing.expectEqual(Outcome{ .refunded = 105 }, machine.handle(.cancel));
    try std.testing.expectEqual(State.idle, machine.state);
}

test "sold out keeps the credit" {
    var machine = Machine.init(0);
    _ = machine.handle(.{ .coin = 100 });
    try std.testing.expectEqual(Outcome{ .sold_out = .candy }, machine.handle(.{ .select = .candy }));
    try std.testing.expectEqual(State{ .collecting = 100 }, machine.state);
}

test "change uses the fewest coins" {
    try std.testing.expectEqual(.{ 0, 0, 0 }, coinsFor(0));
    try std.testing.expectEqual(.{ 2, 1, 0 }, coinsFor(60));
    try std.testing.expectEqual(.{ 3, 2, 0 }, coinsFor(95));
}
```

## 1.7 The program

### Why
`main` runs the tour, prints the menu, then plays out a few customers' visits, printing every event and what it did. It also shows how a Zig program talks to the outside world: through an `Io` and a buffered `Writer`.

### How
- **`main(init: std.process.Init)`:** the standard library's startup code calls `main`. It may take nothing, or a `std.process.Init`: a struct with the things a process starts with: `init.io`, the I/O implementation; `init.gpa`, a general-purpose allocator (lecture 2); `init.arena`, an arena freed at exit; `init.minimal.args`, the command line; `init.environ_map`. `main` may return `void`, `u8` (the exit code), or an error union of either; an error returned from `main` prints an *error return trace* (lecture 4) and exits with 1.
- **Writing output:** `std.Io.File.stdout()` is the standard output as a file, and `.writer(init.io, &buffer)` wraps it in a buffered writer: `print` fills the buffer, and `flush` sends it to the terminal in one system call. The buffer is ours, on the stack: `var stdout_buffer: [4096]u8 = undefined;` reserves 4 KiB without initializing it, which is fine for a buffer that's only ever written before it's read. `&stdout_writer.interface` is the generic `*std.Io.Writer` that every function here takes, so none of them knows or cares that it's writing to a terminal. `std.debug.print` writes to standard error unbuffered, for debugging; the program's real output goes to standard output.
- **`defer`** runs a statement when the enclosing scope exits, however it exits: `defer out.flush() catch {};` flushes at the end of `main`, including when a `try` fails partway. Deferred statements run in reverse order. `catch {}` discards the flush's error, since there's nowhere left to report it.
- **`try`** runs an expression that may fail; if it returns an error, `try` returns that error from the current function, and if not, `try` gives the value. It's why every function here is `!void`: an error from `print` propagates up to `main`, and from `main` to the exit code. Nothing is thrown or caught behind the scenes. Lecture 4 covers errors in full.
- **`dollars`** turns cents into an `f64` for printing only; all the arithmetic stays in whole cents.
- **`press`** sends one event and prints it:
  - **`*Machine`:** the function takes a pointer to the caller's machine, and the caller writes `&machine` to pass one. Functions that change their argument always look like this.
  - **`std.fmt.bufPrint(&buf, fmt, args)`** formats into a slice we own and returns the part it wrote, or `error.NoSpaceLeft`. The event's text is built on the stack, no allocation. `@tagName(event)` is the tag's name as a string; `{t}` prints the same thing.
  - The `switch` on the outcome is a statement here, with `try out.print(...)` in each prong, and an `if` statement with a block in the `.vended` prong.
- **`for (Product.all) |product|`** takes each element of the array in turn. `{t:<6}` left-aligns the tag name in 6 columns.
- **`var machine`:** handling events changes the machine, so it must be `var`; `&machine` of a `const` would be a `*const Machine`, which `press` can't take.
- **A refund, and a loss:** the sold-out scene ends with `cancel`, which hands the dollar back: its prong reads `credit` out of `.collecting`. The next scene inserts a quarter and sends `service`, whose prong moves to `.idle` without looking: the quarter only existed inside the old state, so it's gone. `const before = machine.state;` copies the state first (a union copies like a number), and `{any}` prints it as `.{ .collecting = 25 }`.
- **A loop with a value:** `blk: while (true) { ... break :blk now; }` makes the loop an expression: `const credit = ...` is whatever `break` handed out. A `switch` with `else => {}` ignores every outcome but `.accepted`.
- **Comparing with a tag:** `machine.state == .dispensing` compares a tagged union with an enum literal, and asks only about the tag: is the machine waiting for the cola to be taken?
- **Order doesn't matter:** `press` is used in `main` and defined above it, but could be below. Top-level declarations are order-independent, and the compiler analyzes only what's reachable from `main` (and from the tests, in a test build). A function nobody calls isn't even type-checked, which is why an unused helper with a mistake in it compiles.

### Code
`lecture_1/src/main.zig`, part 6:
```zig
// Reporting

/// Cents as dollars, for printing only: @floatFromInt converts the u32 exactly.
fn dollars(cents: u32) f64 {
    return @as(f64, @floatFromInt(cents)) / 100.0;
}

/// Sends one event to the machine, and prints the event and what happened.
fn press(out: *std.Io.Writer, machine: *Machine, event: Event) !Outcome {
    const outcome = machine.handle(event);

    // The event as text, built into a stack buffer: bufPrint formats into a slice and returns the part it wrote.
    var event_buf: [32]u8 = undefined;
    const event_text = switch (event) {
        .coin => |cents| try std.fmt.bufPrint(&event_buf, "coin({d})", .{cents}),
        .select => |product| try std.fmt.bufPrint(&event_buf, "select({t})", .{product}),
        // {t} prints an enum's or tagged union's tag name; @tagName does the same as a string.
        .cancel, .take_item, .service => @tagName(event),
    };

    // {s:<20} pads the text to 20 columns, left-aligned, so the outcomes line up.
    try out.print("  {s:<20} ", .{event_text});
    switch (outcome) {
        .accepted => |credit| try out.print("credit {d:.2}", .{dollars(credit)}),
        .rejected => |coin| try out.print("{d}-cent coin returned", .{coin}),
        .need_more => |short| try out.print("insert {d:.2} more", .{dollars(short)}),
        .sold_out => |product| try out.print("{t} is sold out", .{product}),
        .vended => |v| if (v.change == 0)
            try out.print("{t} dispensed", .{v.product})
        else {
            const quarters, const dimes, const nickels = coinsFor(v.change);
            try out.print("{t} dispensed, change {d:.2}: {d}x25 {d}x10 {d}x5", .{ v.product, dollars(v.change), quarters, dimes, nickels });
        },
        .refunded => |cents| try out.print("{d:.2} refunded", .{dollars(cents)}),
        .collected => |product| try out.print("{t} taken", .{product}),
        .restocked => try out.writeAll("restocked"),
        .ignored => try out.writeAll("ignored"),
    }
    try out.writeByte('\n');
    return outcome;
}

// The program

// main receives a std.process.Init: the process's allocators, its I/O implementation, arguments and
// environment, set up by the standard library before main runs. `!void` says main can fail with an error.
pub fn main(init: std.process.Init) !void {
    // Output is buffered: print() fills the buffer, and flush() writes it to the terminal in one system call.
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    try printSizes(out);
    try printRepresentation(out);
    try printConversions(out);
    try out.writeByte('\n');

    try out.writeAll("Menu:\n");
    for (Product.all) |product| {
        try out.print("  {t:<6} {d:.2}\n", .{ product, dollars(product.price()) });
    }

    // A machine with 2 of each product. It's `var` because handling events changes it.
    var machine = Machine.init(2);

    try out.writeAll("\nA cola, paid in two goes:\n");
    _ = try press(out, &machine, .{ .coin = 100 });
    _ = try press(out, &machine, .{ .select = .cola });
    _ = try press(out, &machine, .{ .coin = 3 });
    _ = try press(out, &machine, .{ .coin = 25 });
    _ = try press(out, &machine, .{ .select = .cola });
    _ = try press(out, &machine, .{ .coin = 25 });
    _ = try press(out, &machine, .take_item);

    try out.writeAll("\nCandy, with change:\n");
    _ = try press(out, &machine, .{ .coin = 100 });
    _ = try press(out, &machine, .{ .coin = 25 });
    _ = try press(out, &machine, .{ .select = .candy });
    _ = try press(out, &machine, .take_item);

    try out.writeAll("\nChanging our mind:\n");
    _ = try press(out, &machine, .{ .select = .chips });
    _ = try press(out, &machine, .{ .coin = 10 });
    _ = try press(out, &machine, .{ .coin = 5 });
    _ = try press(out, &machine, .cancel);

    try out.writeAll("\nThe last candy, then none, and a refund:\n");
    _ = try press(out, &machine, .{ .coin = 100 });
    _ = try press(out, &machine, .{ .select = .candy });
    _ = try press(out, &machine, .take_item);
    _ = try press(out, &machine, .{ .coin = 100 });
    _ = try press(out, &machine, .{ .select = .candy });
    _ = try press(out, &machine, .cancel);

    // `service` moves to idle without reading the old state, so the credit that only existed inside
    // State.collecting is lost. {any} prints any value with its default format, here the union.
    try out.writeAll("\nService with money inside:\n");
    _ = try press(out, &machine, .{ .coin = 25 });
    const before = machine.state;
    _ = try press(out, &machine, .service);
    try out.print("  {any} became {any}: the quarter is gone\n", .{ before, machine.state });

    // A labeled loop is an expression: `break :blk value` ends it with that value.
    try out.writeAll("\nQuarters until a cola:\n");
    var quarters: u32 = 0;
    const credit = blk: while (true) {
        quarters += 1;
        // A switch prong with a capture reads the accepted credit; `else => {}` ignores the other outcomes.
        switch (machine.handle(.{ .coin = 25 })) {
            .accepted => |now| if (now >= Product.cola.price()) break :blk now,
            else => {},
        }
    };
    try out.print("  {d} quarters make {d:.2}\n", .{ quarters, dollars(credit) });
    _ = try press(out, &machine, .{ .select = .cola });

    // Comparing a tagged union with an enum literal tests its tag: is the machine waiting for the cola to be taken?
    const waiting = machine.state == .dispensing;
    try out.print("\nWaiting to be emptied: {}; takings {d:.2}\n", .{ waiting, dollars(machine.takings) });
}
```

## 1.8 Running it

### How
From `lecture_1/`:
```bash
zig build run
```
builds `zig-out/bin/lecture_1` and runs it. The tour prints first, then the menu and the scenes. And
```bash
zig build test
```
runs the five tests; it prints nothing when they all pass. (`zig test src/main.zig` does the same without the build script, and prints each test's name.) From the repo root, `./build.bash` offers both, in debug, `ReleaseSafe` and `ReleaseFast`.

The output of the tour:
```text
bool 1 byte (1 bit), u8 1, u3 1 byte (3 bits), i32 4, u64 8, usize 8, f64 8
@intFromBool(true) = 1, @intFromBool(false) = 0
'A' = 65, 'é' = 233, "é".len = 2: a code point, and its UTF-8 bytes
std.mem.toBytes(@as(i32, 300)) = { 44, 1, 0, 0 }: lowest byte first
@bitCast(-1 as i32) as u32 = 4294967295: two's complement, all bits set
@bitCast(1.0 as f32) as u32 = 0x3f800000: sign, exponent and fraction
7 / 2 = 3, @divTrunc(-7, 2) = -3, @divFloor(-7, 2) = -4
@floatFromInt(7) / 2.0 = 3.5, @intFromFloat(3.99) = 3
u8 200 as i32 = 200, @intCast(300 as u16) = 200, @truncate(0x12345678) as u8 = 0x78
255 +% 1 = 0, 255 +| 1 = 255, @addWithOverflow(255, 1) = { 0, 1 }
u3 holds up to 7; std.math.maxInt(u3) = 7, maxInt(i7) = 63
```

Two experiments worth doing before moving on. Change `.coin => |cents|` to `.coin =>` and the `switch` stops compiling, because `cents` is used; delete the `.dispensing` prong of the `.coin` switch and it stops compiling because a state isn't handled. And change `Machine.init(2)` to `Machine.init(0)` and `takeOne` to run without the sold-out check: the debug build panics with "integer overflow" and a stack trace pointing at the `-= 1`. That's the safety the optimization modes trade away.
