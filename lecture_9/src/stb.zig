//! Image loading and saving through stb_image and stb_image_write, two single-header C libraries.
//! The build script translated their header into the module @import("stb"); this file wraps the
//! C functions in a Zig type with slices, errors and clear ownership, so the rest of the program
//! never sees a C pointer.

const std = @import("std");
const Allocator = std.mem.Allocator;
/// The translated header: every stb function, type and constant, with C types ([*c]u8, c_int).
const c = @import("stb");

pub const Image = struct {
    width: u32,
    height: u32,
    /// RGB, three bytes per pixel, rows from the top. Who frees it depends on `owner`.
    pixels: []u8,
    owner: Owner,

    /// Memory from stb must go back to stb (it used C's malloc); memory from a Zig allocator goes
    /// back to that allocator. The union remembers which, so deinit always does the right thing.
    pub const Owner = union(enum) {
        stb,
        zig: Allocator,
    };

    pub const channels = 3;

    pub const LoadError = error{DecodeFailed};
    pub const EncodeError = error{EncodeFailed} || Allocator.Error;

    /// A black image owned by the allocator.
    pub fn init(gpa: Allocator, width: u32, height: u32) Allocator.Error!Image {
        const pixels = try gpa.alloc(u8, @as(usize, width) * height * channels);
        @memset(pixels, 0);
        return .{ .width = width, .height = height, .pixels = pixels, .owner = .{ .zig = gpa } };
    }

    pub fn deinit(self: *Image) void {
        switch (self.owner) {
            // Accepts ?*anyopaque, C's void*; a [*]u8 coerces to it.
            .stb => c.stbi_image_free(self.pixels.ptr),
            .zig => |gpa| gpa.free(self.pixels),
        }
        self.* = undefined;
    }

    /// Decodes a PNG, JPEG, BMP, GIF, ... file. The path must be 0-terminated: C strings end at a 0
    /// byte, and a [:0]const u8 guarantees one is there. Always 3 channels, whatever the file has.
    pub fn load(path: [:0]const u8) LoadError!Image {
        var width: c_int = undefined;
        var height: c_int = undefined;
        var file_channels: c_int = undefined;
        // stbi_load returns a C pointer, [*c]u8: null on failure. Giving it an optional many-item
        // pointer type turns null into a proper Zig null, and `orelse` handles it.
        const data: ?[*]u8 = c.stbi_load(path.ptr, &width, &height, &file_channels, channels);
        return fromStb(data orelse return error.DecodeFailed, width, height);
    }

    /// The same from bytes already in memory.
    pub fn loadFromMemory(bytes: []const u8) LoadError!Image {
        var width: c_int = undefined;
        var height: c_int = undefined;
        var file_channels: c_int = undefined;
        const data: ?[*]u8 = c.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &width, &height, &file_channels, channels);
        return fromStb(data orelse return error.DecodeFailed, width, height);
    }

    fn fromStb(data: [*]u8, width: c_int, height: c_int) Image {
        const w: u32 = @intCast(width);
        const h: u32 = @intCast(height);
        // A many-item pointer becomes a slice once we know the length; stb told us the dimensions.
        return .{ .width = w, .height = h, .pixels = data[0 .. @as(usize, w) * h * channels], .owner = .stb };
    }

    /// Why the last load failed, as stb describes it. The C string becomes a slice with span.
    pub fn failureReason() []const u8 {
        const reason: ?[*:0]const u8 = c.stbi_failure_reason();
        return std.mem.span(reason orelse return "unknown");
    }

    pub fn writePng(self: Image, path: [:0]const u8) EncodeError!void {
        const stride: c_int = @intCast(self.width * channels);
        if (c.stbi_write_png(path.ptr, @intCast(self.width), @intCast(self.height), channels, self.pixels.ptr, stride) == 0) {
            return error.EncodeFailed;
        }
    }

    /// PNG bytes in memory. stb produces the file in chunks and calls a function of ours for each:
    /// a C callback into Zig. The context pointer is how C hands our own state back to us.
    pub fn encodePng(self: Image, gpa: Allocator) EncodeError![]u8 {
        var context = WriteContext{ .gpa = gpa, .out = .empty, .failed = false };
        errdefer context.out.deinit(gpa);
        const stride: c_int = @intCast(self.width * channels);
        const ok = c.stbi_write_png_to_func(writeChunk, &context, @intCast(self.width), @intCast(self.height), channels, self.pixels.ptr, stride);
        if (ok == 0 or context.failed) return error.EncodeFailed;
        return context.out.toOwnedSlice(gpa);
    }

    const WriteContext = struct {
        gpa: Allocator,
        out: std.ArrayList(u8),
        failed: bool,
    };

    /// Must match stb's `stbi_write_func`: void (*)(void *context, void *data, int size), hence the
    /// C calling convention and the C-shaped parameters. Nothing may escape a callback into C, so
    /// an allocation failure is recorded in the context and reported after stb returns.
    fn writeChunk(context: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void {
        // Back from void* to our type: ptrCast changes the pointee, alignCast restores the alignment.
        const self: *WriteContext = @ptrCast(@alignCast(context.?));
        const bytes: [*]const u8 = @ptrCast(data.?);
        self.out.appendSlice(self.gpa, bytes[0..@intCast(size)]) catch {
            self.failed = true;
        };
    }

    pub fn pixel(self: Image, x: u32, y: u32) *[channels]u8 {
        const index = (@as(usize, y) * self.width + x) * channels;
        return self.pixels[index..][0..channels];
    }
};

// Tests

test "round trip through PNG in memory" {
    const gpa = std.testing.allocator;
    var original = try Image.init(gpa, 4, 3);
    defer original.deinit();
    for (0..3) |y| {
        for (0..4) |x| {
            original.pixel(@intCast(x), @intCast(y)).* = .{ @intCast(x * 60), @intCast(y * 100), 7 };
        }
    }

    const png = try original.encodePng(gpa);
    defer gpa.free(png);
    try std.testing.expect(std.mem.startsWith(u8, png, "\x89PNG\r\n\x1a\n"));

    var decoded = try Image.loadFromMemory(png);
    defer decoded.deinit();
    try std.testing.expectEqual(4, decoded.width);
    try std.testing.expectEqual(3, decoded.height);
    try std.testing.expectEqualSlices(u8, original.pixels, decoded.pixels);
    try std.testing.expect(decoded.owner == .stb);
}

test "garbage is a decode error with a reason" {
    try std.testing.expectError(error.DecodeFailed, Image.loadFromMemory("definitely not an image"));
    try std.testing.expect(Image.failureReason().len > 0);
}

test "the translated constants and types are usable directly" {
    // What translate-c made of `#define STBI_rgb 3` and `typedef unsigned char stbi_uc;`.
    try std.testing.expectEqual(3, c.STBI_rgb);
    try std.testing.expectEqual(u8, c.stbi_uc);
}
