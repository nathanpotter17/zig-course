//! Reflection: code that reads types at compile time and generates the right code for each.

const std = @import("std");
const Writer = std.Io.Writer;

/// Prints any value in a Zig-like notation, by switching on its type's structure. The switch runs at
/// compile time, since @typeInfo is comptime-known, so each instantiation of printAny is straight-line
/// code for one type. The error set is named because the function is recursive.
pub fn printAny(w: *Writer, value: anytype) Writer.Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int, .comptime_int, .float, .comptime_float => try w.print("{d}", .{value}),
        .bool => try w.print("{}", .{value}),
        .void => try w.writeAll("{}"),
        .@"enum" => try w.print(".{t}", .{value}),
        .error_set => try w.print("error.{t}", .{value}),
        .optional => if (value) |inner| try printAny(w, inner) else try w.writeAll("null"),
        .error_union => if (value) |inner| try printAny(w, inner) else |err| try printAny(w, err),
        .array => |info| {
            // A 0-terminated byte array is what a string literal dereferences to; print it as text.
            // Any other array, including a plain [N]u8, is a list of values.
            if (info.child == u8 and info.sentinel() == 0) return w.print("\"{s}\"", .{&value});
            try printList(w, &value);
        },
        .pointer => |info| switch (info.size) {
            // A single-item pointer: print what it points at. For a pointer to an array, that's the array.
            .one => try printAny(w, value.*),
            .slice => if (info.child == u8) try w.print("\"{s}\"", .{value}) else try printList(w, value),
            .many, .c => try w.print("{*}", .{value}),
        },
        .@"struct" => |info| {
            try w.writeAll(if (info.is_tuple) ".{ " else "{ ");
            // inline for unrolls at compile time, once per field, so `name` is a comptime string and
            // @field(value, name) is an ordinary field access in the generated code.
            inline for (info.field_names, 0..) |name, i| {
                if (i > 0) try w.writeAll(", ");
                if (!info.is_tuple) try w.print(".{s} = ", .{name});
                try printAny(w, @field(value, name));
            }
            try w.writeAll(" }");
        },
        .@"union" => |info| {
            if (info.tag_type == null) @compileError("printAny can't print the bare union " ++ @typeName(T) ++ ": it doesn't know which field is active");
            // `inline else` generates a prong per field; `tag` is comptime-known in each.
            switch (value) {
                inline else => |payload, tag| {
                    try w.print(".{{ .{t} = ", .{tag});
                    try printAny(w, payload);
                    try w.writeAll(" }");
                },
            }
        },
        // A type this function doesn't handle is a compile error with a clear message, not a runtime one.
        else => @compileError("printAny doesn't know how to print a " ++ @typeName(T)),
    }
}

fn printList(w: *Writer, items: anytype) Writer.Error!void {
    try w.writeAll("[");
    for (items, 0..) |item, i| {
        if (i > 0) try w.writeAll(", ");
        try printAny(w, item);
    }
    try w.writeAll("]");
}

/// A one-line description of a type, built at compile time by concatenating strings. `text` is a
/// comptime variable, so every assignment to it happens in the compiler, and the switch on a
/// comptime-known value is unrolled too; the caller receives a string literal.
pub fn describe(comptime T: type) []const u8 {
    comptime var text: []const u8 = @typeName(T) ++ ": ";
    switch (@typeInfo(T)) {
        .int => |info| text = text ++ std.fmt.comptimePrint("{t} {d}-bit integer", .{ info.signedness, info.bits }),
        .float => |info| text = text ++ std.fmt.comptimePrint("{d}-bit float", .{info.bits}),
        .@"struct" => |info| {
            text = text ++ std.fmt.comptimePrint("struct of {d} fields (", .{info.field_names.len});
            inline for (info.field_names, info.field_types, 0..) |name, FieldType, i| {
                text = text ++ (if (i > 0) ", " else "") ++ name ++ ": " ++ @typeName(FieldType);
            }
            text = text ++ ")";
        },
        .@"enum" => |info| text = text ++ std.fmt.comptimePrint("enum of {d} values backed by {s}", .{ info.field_names.len, @typeName(info.tag_type) }),
        .@"union" => |info| text = text ++ std.fmt.comptimePrint("{s} union of {d} fields", .{ if (info.tag_type != null) "tagged" else "bare", info.field_names.len }),
        .pointer => |info| text = text ++ std.fmt.comptimePrint("{t} pointer to {s}", .{ info.size, @typeName(info.child) }),
        else => text = text ++ @tagName(@typeInfo(T)),
    }
    return text;
}

/// Sets a struct field by name from text, parsing the text according to the field's type. This is how
/// a config-file parser or a command-line parser is written once for every struct.
pub const SetError = error{ UnknownField, InvalidValue };

pub fn setField(target: anytype, name: []const u8, text: []const u8) SetError!void {
    const T = @TypeOf(target.*);
    // One `if` per field, unrolled; the runtime cost is a string comparison per field until the match.
    inline for (@typeInfo(T).@"struct".field_names) |field_name| {
        if (std.mem.eql(u8, name, field_name)) {
            const FieldType = @FieldType(T, field_name);
            @field(target, field_name) = parseAs(FieldType, text) orelse return error.InvalidValue;
            return;
        }
    }
    return error.UnknownField;
}

/// Parses text as a value of T: integers, floats, bools, enums (by name) and strings.
fn parseAs(comptime T: type, text: []const u8) ?T {
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, text, 10) catch null,
        .float => std.fmt.parseFloat(T, text) catch null,
        .bool => if (std.mem.eql(u8, text, "true")) true else if (std.mem.eql(u8, text, "false")) false else null,
        .@"enum" => std.meta.stringToEnum(T, text),
        .pointer => |info| if (info.size == .slice and info.child == u8) text else @compileError("can't parse a " ++ @typeName(T)),
        .optional => |info| if (std.mem.eql(u8, text, "null")) null else parseAs(info.child, text),
        else => @compileError("can't parse a " ++ @typeName(T)),
    };
}

/// Checks at compile time that a type has the public methods an interface needs, with a message that
/// names what's missing. Used as `comptime requireMethods(T, &.{ "area", "name" });`.
pub fn requireMethods(comptime T: type, comptime names: []const []const u8) void {
    inline for (names) |name| {
        if (!@hasDecl(T, name)) @compileError(@typeName(T) ++ " is missing the method '" ++ name ++ "'");
    }
}

// Tests

const Level = enum { low, high };
const Sample = struct {
    name: []const u8,
    level: Level,
    readings: [3]u8,
    note: ?[]const u8 = null,
    pair: struct { u8, bool } = .{ 7, true },
};
const Message = union(enum) { text: []const u8, code: u32 };

fn printToString(gpa: std.mem.Allocator, value: anytype) ![]u8 {
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try printAny(&out.writer, value);
    return out.toOwnedSlice();
}

test "printAny walks structs, arrays, optionals and unions" {
    const sample = Sample{ .name = "probe", .level = .high, .readings = .{ 1, 2, 3 } };
    const text = try printToString(std.testing.allocator, sample);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{ .name = \"probe\", .level = .high, .readings = [1, 2, 3], .note = null, .pair = .{ 7, true } }", text);

    const message = try printToString(std.testing.allocator, Message{ .code = 404 });
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings(".{ .code = 404 }", message);

    const slice = try printToString(std.testing.allocator, @as([]const u16, &.{ 10, 20 }));
    defer std.testing.allocator.free(slice);
    try std.testing.expectEqualStrings("[10, 20]", slice);
}

test "describe builds its text at compile time" {
    try std.testing.expectEqualStrings("u8: unsigned 8-bit integer", describe(u8));
    try std.testing.expectEqualStrings("reflect.Level: enum of 2 values backed by u1", describe(Level));
    try std.testing.expectEqualStrings("[]const u8: slice pointer to u8", describe([]const u8));
    // comptime: the string is a constant, so the comparison itself could run at compile time.
    comptime std.debug.assert(std.mem.startsWith(u8, describe(Sample), "reflect.Sample: struct of 5 fields ("));
}

test "setField parses by field type" {
    const Config = struct { port: u16 = 80, verbose: bool = false, level: Level = .low, name: []const u8 = "", ratio: f32 = 1.0 };
    var config: Config = .{};
    try setField(&config, "port", "8080");
    try setField(&config, "verbose", "true");
    try setField(&config, "level", "high");
    try setField(&config, "name", "server");
    try setField(&config, "ratio", "0.5");
    try std.testing.expectEqual(8080, config.port);
    try std.testing.expect(config.verbose);
    try std.testing.expectEqual(.high, config.level);
    try std.testing.expectEqualStrings("server", config.name);
    try std.testing.expectEqual(0.5, config.ratio);
    try std.testing.expectError(error.InvalidValue, setField(&config, "port", "eighty"));
    try std.testing.expectError(error.UnknownField, setField(&config, "colour", "red"));
}

test "requireMethods passes for a type that has them" {
    const Circle = struct {
        pub fn area(_: @This()) f64 {
            return 0;
        }
    };
    comptime requireMethods(Circle, &.{"area"});
    // comptime requireMethods(Circle, &.{"perimeter"}); would be a compile error naming the method.
}
