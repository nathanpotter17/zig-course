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
