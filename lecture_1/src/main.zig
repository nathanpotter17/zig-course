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
