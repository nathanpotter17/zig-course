//! Statistics about a tree of source files: lines and bytes per file extension, the most common
//! identifiers, and the largest files. One struct, filled by walking a directory.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Stats = @This();

pub const Options = struct {
    /// Directory names that are never entered.
    ignore: []const []const u8 = &.{ ".zig-cache", "zig-out", ".git" },
    /// Files larger than this are counted but not read for identifiers.
    max_read_size: usize = 4 * 1024 * 1024,
};

/// Totals for one extension, or for everything.
pub const Totals = struct {
    files: usize = 0,
    lines: usize = 0,
    bytes: u64 = 0,
};

pub const FileInfo = struct {
    path: []const u8,
    lines: usize,
    bytes: u64,
};

pub const WordCount = struct {
    word: []const u8,
    count: u32,
};

gpa: Allocator,
/// Owns every string the stats keep: file paths and identifiers, copied out of buffers that don't
/// outlive the walk. Freed all at once by deinit.
arena: std.heap.ArenaAllocator,
options: Options,
/// Totals per extension, in the order extensions were first seen. An array hash map keeps insertion
/// order and iterates fast, at the cost of slower removal; perfect for a map that only grows.
by_extension: std.array_hash_map.String(Totals) = .empty,
/// Identifier -> occurrences. A plain hash map: fast lookup, unordered iteration.
words: std.StringHashMap(u32),
files: std.ArrayList(FileInfo) = .empty,
/// How many entries of each kind the walk saw, indexed by the kind enum.
kinds: std.EnumArray(Io.File.Kind, usize) = .initFill(0),
total: Totals = .{},

pub fn init(gpa: Allocator, options: Options) Stats {
    return .{
        .gpa = gpa,
        .arena = std.heap.ArenaAllocator.init(gpa),
        .options = options,
        .words = std.StringHashMap(u32).init(gpa),
    };
}

pub fn deinit(self: *Stats) void {
    self.by_extension.deinit(self.gpa);
    self.words.deinit();
    self.files.deinit(self.gpa);
    self.arena.deinit();
    self.* = undefined;
}

/// Walks `dir` recursively and records every regular file. `dir` must have been opened with `.iterate = true`.
pub fn scan(self: *Stats, io: Io, dir: Io.Dir) !void {
    // A selective walker reports each entry and lets us decide which directories to enter, so the
    // ignored ones are never opened. The plain `walk` enters every directory.
    var walker = try dir.walkSelectively(self.gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        self.kinds.getPtr(entry.kind).* += 1;
        switch (entry.kind) {
            .directory => if (!self.isIgnored(entry.basename)) try walker.enter(io, entry),
            .file => try self.addFile(io, entry.dir, entry.basename, entry.path),
            else => {},
        }
    }
}

fn isIgnored(self: Stats, name: []const u8) bool {
    for (self.options.ignore) |ignored| {
        if (std.mem.eql(u8, name, ignored)) return true;
    }
    return false;
}

/// Records one file: its size from the metadata, its lines and identifiers from its contents.
fn addFile(self: *Stats, io: Io, dir: Io.Dir, basename: []const u8, path: []const u8) !void {
    const stat = try dir.statFile(io, basename, .{});
    // The walker's path buffer is reused on the next step; the arena keeps our copy.
    const owned_path = try self.arena.allocator().dupe(u8, path);

    var lines: usize = 0;
    if (stat.size <= self.options.max_read_size) {
        // The whole file in one allocation, freed at the end of this function. The limit guards
        // against a file that grew between the stat and the read.
        const contents = try dir.readFileAlloc(io, basename, self.gpa, .limited(self.options.max_read_size));
        defer self.gpa.free(contents);
        lines = countLines(contents);
        if (isText(contents)) try self.countWords(contents);
    }

    // The extension (".zig", or "" for none) is the key. getOrPut finds the entry or makes a zeroed one.
    const ext = std.fs.path.extension(basename);
    const slot = try self.by_extension.getOrPut(self.gpa, ext);
    if (!slot.found_existing) {
        slot.key_ptr.* = try self.arena.allocator().dupe(u8, ext);
        slot.value_ptr.* = .{};
    }
    slot.value_ptr.files += 1;
    slot.value_ptr.lines += lines;
    slot.value_ptr.bytes += stat.size;
    self.total.files += 1;
    self.total.lines += lines;
    self.total.bytes += stat.size;

    try self.files.append(self.gpa, .{ .path = owned_path, .lines = lines, .bytes = stat.size });
}

/// Lines in a buffer: newlines, plus one for a last line without a newline.
pub fn countLines(contents: []const u8) usize {
    const newlines = std.mem.countScalar(u8, contents, '\n');
    return if (contents.len > 0 and contents[contents.len - 1] != '\n') newlines + 1 else newlines;
}

/// Lines in a file, read through a buffered reader a line at a time, without loading the whole file.
/// The same answer as countLines; this is how to do it for a file too big to hold.
pub fn countLinesStreaming(io: Io, file: Io.File) !usize {
    var buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    const reader = &file_reader.interface;
    var lines: usize = 0;
    // takeDelimiter returns the next line (without the newline), or null at the end of the stream.
    // A line longer than the buffer would be error.StreamTooLong; discardDelimiterInclusive skips it.
    while (true) {
        const line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                _ = try reader.discardDelimiterInclusive('\n');
                lines += 1;
                continue;
            },
            error.ReadFailed => return err,
        };
        if (line == null) break;
        lines += 1;
    }
    return lines;
}

/// Text files have no zero bytes; anything else is treated as binary and not scanned for words.
fn isText(contents: []const u8) bool {
    return std.mem.findScalar(u8, contents, 0) == null;
}

/// Counts identifiers: runs of letters, digits and underscores that start with a letter, at least
/// three characters long. tokenizeAny splits on everything else.
fn countWords(self: *Stats, contents: []const u8) !void {
    var it = std.mem.tokenizeAny(u8, contents, " \t\r\n.,;:()[]{}<>=+-*/%!&|^~?@#\"'\\`$");
    while (it.next()) |word| {
        if (word.len < 3 or !std.ascii.isAlphabetic(word[0])) continue;
        if (!isIdentifier(word)) continue;
        const slot = try self.words.getOrPut(word);
        if (slot.found_existing) {
            slot.value_ptr.* += 1;
        } else {
            // The key must outlive `contents`: copy it into the arena and point the map at the copy.
            slot.key_ptr.* = try self.arena.allocator().dupe(u8, word);
            slot.value_ptr.* = 1;
        }
    }
}

fn isIdentifier(word: []const u8) bool {
    for (word) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

/// The `n` most frequent identifiers, most frequent first, ties alphabetical. Caller owns the slice.
pub fn topWords(self: Stats, gpa: Allocator, n: usize) ![]WordCount {
    var all: std.ArrayList(WordCount) = .empty;
    defer all.deinit(gpa);
    var it = self.words.iterator();
    while (it.next()) |entry| {
        try all.append(gpa, .{ .word = entry.key_ptr.*, .count = entry.value_ptr.* });
    }
    std.mem.sort(WordCount, all.items, {}, struct {
        fn lessThan(_: void, a: WordCount, b: WordCount) bool {
            if (a.count != b.count) return a.count > b.count;
            return std.mem.lessThan(u8, a.word, b.word);
        }
    }.lessThan);
    return gpa.dupe(WordCount, all.items[0..@min(n, all.items.len)]);
}

/// The `n` files with the most lines, largest first, found with a priority queue that keeps only
/// the n largest seen so far. Caller owns the slice.
pub fn largestFiles(self: Stats, gpa: Allocator, n: usize) ![]FileInfo {
    // A min-heap on line count: the top is the smallest of the kept files, the one to drop next.
    const Queue = std.PriorityQueue(FileInfo, void, struct {
        fn compare(_: void, a: FileInfo, b: FileInfo) std.math.Order {
            return std.math.order(a.lines, b.lines);
        }
    }.compare);
    var queue: Queue = .initContext({});
    defer queue.deinit(gpa);

    for (self.files.items) |file| {
        try queue.push(gpa, file);
        if (queue.count() > n) _ = queue.pop();
    }
    // Popping the min-heap gives smallest first; fill the result from the back.
    const result = try gpa.alloc(FileInfo, queue.count());
    var i = result.len;
    while (queue.pop()) |file| {
        i -= 1;
        result[i] = file;
    }
    return result;
}

/// Extensions sorted by line count, most lines first. Caller owns the slice of keys; the keys themselves
/// belong to the stats.
pub fn extensionsByLines(self: Stats, gpa: Allocator) ![][]const u8 {
    const keys = try gpa.dupe([]const u8, self.by_extension.keys());
    std.mem.sort([]const u8, keys, self, struct {
        fn lessThan(stats: Stats, a: []const u8, b: []const u8) bool {
            return stats.by_extension.get(a).?.lines > stats.by_extension.get(b).?.lines;
        }
    }.lessThan);
    return keys;
}

// The report

/// Everything the JSON report holds. std.json serializes this struct field by field, and parses it back.
pub const Report = struct {
    generated_at_ms: i64,
    scanned_entries: usize,
    total: Totals,
    by_extension: []const ExtensionTotals,
    top_words: []const WordCount,
    largest_files: []const FileInfo,

    pub const ExtensionTotals = struct {
        extension: []const u8,
        totals: Totals,
    };
};

/// Builds the report with `arena` memory; nothing in it needs freeing individually.
pub fn report(self: Stats, arena: Allocator, io: Io, top: usize) !Report {
    const extensions = try self.extensionsByLines(arena);
    const by_extension = try arena.alloc(Report.ExtensionTotals, extensions.len);
    for (extensions, by_extension) |ext, *slot| {
        slot.* = .{ .extension = ext, .totals = self.by_extension.get(ext).? };
    }
    var scanned: usize = 0;
    for (self.kinds.values) |count| scanned += count;
    return .{
        // The real-time clock, as milliseconds since 1970: a timestamp for the file.
        .generated_at_ms = Io.Timestamp.now(io, .real).toMilliseconds(),
        .scanned_entries = scanned,
        .total = self.total,
        .by_extension = by_extension,
        .top_words = try self.topWords(arena, top),
        .largest_files = try self.largestFiles(arena, top),
    };
}

/// Writes the report as text, to any writer.
pub fn writeText(r: Report, w: *Io.Writer) !void {
    try w.print("{d} files, {d} lines, {Bi:.1} in {d} directory entries\n", .{ r.total.files, r.total.lines, r.total.bytes, r.scanned_entries });
    try w.writeAll("\nBy extension:\n");
    for (r.by_extension) |e| {
        try w.print("  {s:<8} {d:>5} files {d:>8} lines {Bi:>10.1}\n", .{ if (e.extension.len == 0) "(none)" else e.extension, e.totals.files, e.totals.lines, e.totals.bytes });
    }
    try w.writeAll("\nMost common identifiers:\n");
    for (r.top_words) |wc| try w.print("  {s:<20} {d}\n", .{ wc.word, wc.count });
    try w.writeAll("\nLargest files:\n");
    for (r.largest_files) |f| try w.print("  {d:>6} lines  {s}\n", .{ f.lines, f.path });
}

// Tests

/// A small tree in a temporary directory under .zig-cache/tmp, deleted by cleanup().
fn makeTree(tmp: std.testing.TmpDir) !void {
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "const std = @import(\"std\");\npub fn main() void {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.md", .data = "# notes\nline two\nlast line without newline" });
    try tmp.dir.createDirPath(io, "src/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/deep/util.zig", .data = "pub fn util() void {}\n" });
    try tmp.dir.createDirPath(io, "zig-out");
    try tmp.dir.writeFile(io, .{ .sub_path = "zig-out/ignored.zig", .data = "should not be counted\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "blob.bin", .data = "\x00\x01\x02binary" });
}

test "scan counts files, lines and bytes per extension" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeTree(tmp);

    var stats = Stats.init(std.testing.allocator, .{});
    defer stats.deinit();
    try stats.scan(io, tmp.dir);

    try std.testing.expectEqual(4, stats.total.files);
    try std.testing.expectEqual(2 + 3 + 1 + 1, stats.total.lines);
    const zig = stats.by_extension.get(".zig").?;
    try std.testing.expectEqual(2, zig.files);
    try std.testing.expectEqual(3, zig.lines);
    try std.testing.expectEqual(1, stats.by_extension.get(".md").?.files);
    try std.testing.expectEqual(1, stats.by_extension.get(".bin").?.files);
    // zig-out was skipped, so the directory count is src, src/deep and zig-out: seen but not entered.
    try std.testing.expectEqual(3, stats.kinds.get(.directory));
    // "std" appears twice in main.zig (the quotes around "std" are delimiters); identifiers in the
    // binary file were not counted.
    try std.testing.expectEqual(2, stats.words.get("std").?);
    try std.testing.expectEqual(null, stats.words.get("binary"));
}

test "largest files and top words are ordered" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeTree(tmp);
    var stats = Stats.init(std.testing.allocator, .{});
    defer stats.deinit();
    try stats.scan(io, tmp.dir);

    const largest = try stats.largestFiles(std.testing.allocator, 2);
    defer std.testing.allocator.free(largest);
    try std.testing.expectEqual(2, largest.len);
    try std.testing.expectEqualStrings("notes.md", largest[0].path);
    try std.testing.expectEqualStrings("main.zig", largest[1].path);

    const words = try stats.topWords(std.testing.allocator, 3);
    defer std.testing.allocator.free(words);
    // "line", "pub", "std" and "void" appear twice each; ties are alphabetical.
    try std.testing.expectEqualStrings("line", words[0].word);
    try std.testing.expectEqual(2, words[0].count);
    try std.testing.expectEqualStrings("pub", words[1].word);
    try std.testing.expectEqualStrings("std", words[2].word);
}

test "streaming line count matches the buffer count" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 300 lines of 100 bytes: more than the reader's 4 KiB buffer, so it refills many times.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    for (0..300) |i| try text.print(std.testing.allocator, "{d:0>99}\n", .{i});
    try tmp.dir.writeFile(io, .{ .sub_path = "big.txt", .data = text.items });

    const file = try tmp.dir.openFile(io, "big.txt", .{});
    defer file.close(io);
    try std.testing.expectEqual(300, countLines(text.items));
    try std.testing.expectEqual(300, try countLinesStreaming(io, file));
}

test "the report round-trips through JSON" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeTree(tmp);
    var stats = Stats.init(std.testing.allocator, .{});
    defer stats.deinit();
    try stats.scan(io, tmp.dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try stats.report(arena.allocator(), io, 3);

    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, r, .{});
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.find(u8, json, "\"total\":{\"files\":4") != null);

    const parsed = try std.json.parseFromSlice(Report, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(r.total, parsed.value.total);
    try std.testing.expectEqual(r.by_extension.len, parsed.value.by_extension.len);
    try std.testing.expectEqualStrings(r.top_words[0].word, parsed.value.top_words[0].word);
}
