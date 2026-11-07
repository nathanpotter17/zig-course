# Lecture 6: The standard library: containers, files and JSON

By the end of this lecture we'll have `codestat`: a command-line tool that walks a directory tree, counts lines and bytes per file extension, finds the most common identifiers and the largest files, prints a report, and writes it as JSON. It reads its settings from a JSON file, an environment variable and the command line, logs what it does, and times itself. Run on this repository, it reports on the course.

A tool like this is a tour of the standard library's everyday parts:
- **Containers:** `StringHashMap` for counting, an array hash map that keeps insertion order, `ArrayList`, `PriorityQueue` for the top N, `EnumArray` for counting by kind, and the sorting that turns them into a report.
- **The filesystem through `std.Io.Dir`:** walking a tree while choosing which directories to enter, file metadata, reading a whole file, and a streaming `Reader` for a file too big to hold.
- **`std.json`:** a struct to JSON and back, with defaults for missing fields.
- **The process:** command-line arguments, environment variables, exit codes, `std.log` with scopes, and the two clocks.
- **Tests that touch the filesystem**, in a temporary directory the test runner cleans up.

Two files: `lecture_6/src/Stats.zig`, a file-as-struct (lecture 2) that gathers and reports the statistics, and `lecture_6/src/main.zig`, the command-line program. `lecture_6/codestat.json` is a sample config that points the tool at the repository. The build files are lecture 1's with the name changed.

## 6.1 The statistics

### Why
The tool keeps four kinds of fact: totals per extension, counts per identifier, a list of files, and counts per directory-entry kind. Each wants a different container, and choosing among the standard library's maps is the first decision.

### How
- **The struct** owns a `gpa` for its containers and an `arena` for its strings. Every path and identifier it keeps is copied out of a buffer that won't outlive the walk (the walker reuses its path buffer; a file's contents are freed after counting), and the arena frees all the copies in one `deinit`. The containers that take an allocator per call get `self.gpa`.
- **`std.array_hash_map.String(Totals)`** maps extension to totals. An *array hash map* stores its entries in an array with a hash index beside it: iteration is in insertion order and as fast as a slice (`keys()` and `values()` are slices), removal is slower. For a map that only grows and is read back in order, it's the right one. `.empty` is the unmanaged form, taking `gpa` on each call like `ArrayList`.
- **`std.StringHashMap(u32)`** maps identifier to count. The plain hash map has the fastest lookup and unordered iteration; this one is the *managed* form, initialized with `init(gpa)` and storing the allocator, so `getOrPut(word)` takes no allocator. Both forms exist for every map; the unmanaged ones (`std.StringHashMapUnmanaged`) are the building blocks.
- **`getOrPut`** is the counting idiom: it returns the entry for the key, with `found_existing` saying whether it was already there, so one hash lookup does both the check and the insert. For a new key, the caller fills `key_ptr` and `value_ptr`; here the key is copied into the arena first, because the map stores the slice, not the bytes, and `word` points into a buffer about to be freed. A hash map keyed by strings *always* needs the caller to manage the keys' lifetime.
- **`std.EnumArray(Io.File.Kind, usize)`** counts entries by kind, indexed by the enum, as in lecture 5. `.initFill(0)` zeroes it; `getPtr(kind).* += 1` increments.
- **`Totals`** with zero defaults is what `getOrPut` installs for a new extension, and is also the type of the grand total.

### Code
`lecture_6/src/Stats.zig`, part 1:
```zig
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
```

## 6.2 Walking the tree

### Why
Everything the filesystem offers in Zig goes through `std.Io.Dir`, a handle to an open directory, and every operation takes the `io`. A recursive walk needs a stack of open directories and a path buffer, which the standard library's walker manages; we only need to say which directories to enter and what to do with each file.

### How
- **`dir.walkSelectively(gpa)`** returns a walker that reports each entry and waits to be told to `enter` a directory; the plain `walk` enters every one. The selective form is how to skip `.zig-cache` without opening it. `walker.next(io)` returns `?Entry` with the containing `dir`, the `basename`, the full relative `path` (valid only until the next call) and the `kind`. `deinit` closes whatever it left open. The directory handed to it must have been opened with `.iterate = true`.
- **`switch (entry.kind)`** over `std.Io.File.Kind`: directories are entered unless ignored, files are recorded, and symlinks, pipes, devices and the rest are counted and skipped.
- **Metadata:** `dir.statFile(io, name, .{})` returns a `File.Stat` with `size`, kind, times and more, without opening the file. Using the entry's `dir` and `basename` rather than the full path avoids long-path problems and is faster.
- **Reading a whole file:** `dir.readFileAlloc(io, name, gpa, .limited(max))` returns the contents in one allocation, or `error.StreamTooLong` if the file exceeds the limit. The limit matters: the size came from `stat`, and the file could have grown since. The contents are freed at the end of the function, after the counts are taken.
- **`std.fs.path.extension(name)`** returns `".zig"` or `""`. `std.fs.path` also has `basename`, `dirname`, `stem` and `join`, and knows the platform's separators.
- **Lines:** `countLines` counts `\n` with `std.mem.countScalar` and adds one for a last line with no newline. **Words:** `tokenizeAny` with every punctuation character as a delimiter yields candidate identifiers; `std.ascii.isAlphabetic` and `isAlphanumeric` filter them. A file with a 0 byte in it is treated as binary and not scanned for words.

### Code
`lecture_6/src/Stats.zig`, part 2:
```zig
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
```

## 6.3 Streaming reads

### Why
`readFileAlloc` is right for source files, and wrong for a log that's larger than memory. The `Reader` interface reads through a fixed buffer, a piece at a time, and `countLinesStreaming` counts lines that way. It's also the shape of every reader in Zig: standard input (lecture 1 wrote to its twin), a network connection (lecture 8), a decompressor.

### How
- **`file.reader(io, &buffer)`** makes a `File.Reader` over a buffer we provide; `&file_reader.interface` is the generic `*std.Io.Reader`. The buffer's size is the most the reader holds at once: 4 KiB here, so a 300-line file of 30 KB is read in eight refills.
- **`takeDelimiter('\n')`** returns the next line without its newline, as a slice *into the buffer* (valid until the next call), or `null` at the end of the stream. `takeDelimiterExclusive` is the same but returns `error.EndOfStream` instead of null; `takeDelimiterInclusive` keeps the delimiter. **`error.StreamTooLong`** means a line longer than the buffer; `discardDelimiterInclusive` skips to the end of it, so the count stays right. `ReadFailed` is the I/O error, passed up.
- **The other readers:** `std.Io.Reader.fixed(bytes)` reads from a slice in memory, for parsing a buffer with the same code that parses a file. `Writer.Allocating` (lecture 3) is the writing counterpart.
- **The test** writes 300 lines of 100 bytes to a temporary file and checks that the streaming count agrees with `countLines` on the same bytes; `main` does the same on the largest file it found.

## 6.4 Sorting and the top N

### Why
A report orders things: extensions by lines, words by count, files by size. Two tools: `std.mem.sort` with a comparison function for whole lists, and a `PriorityQueue` for the N largest of many without sorting them all.

### How
- **`topWords`** copies the map's entries into an `ArrayList` (a hash map has no order to sort in place), sorts with a comparison that puts larger counts first and breaks ties alphabetically with `std.mem.lessThan`, and returns a copy of the first `n` with `gpa.dupe`. The caller owns the result; the words themselves still belong to the arena.
- **`std.mem.sort(T, slice, context, lessThan)`** is a stable sort. The context is passed to every comparison: `extensionsByLines` passes the `Stats` itself so the comparison can look up each extension's totals; `topWords` passes `{}` (a void value) because the comparison needs nothing. The comparison is written inline as a method of an anonymous struct, lecture 3's idiom.
- **`std.PriorityQueue(T, Context, compareFn)`** is a binary heap ordered by `compareFn`, which returns a `std.math.Order` (`.lt`, `.eq`, `.gt`); `std.math.order(a, b)` compares two numbers. With `.lt` meaning "comes out first", the queue is a *min-heap*, and the top is the smallest element kept. `largestFiles` pushes every file and pops whenever there are more than `n`: what's popped is always the smallest, so what remains is the `n` largest, in O(files × log n). Popping the rest gives them smallest first, and the result is filled from the back.
- **`.initContext({})`** makes an empty queue with a void context; `push` and `deinit` take the allocator, `pop` returns `?T`, `count` the length.
- **Ownership:** every function that returns a slice here allocates it with the `gpa` it's given and documents "caller owns". `report` passes an arena, so the caller frees nothing.

### Code
`lecture_6/src/Stats.zig`, part 3:
```zig
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
```

## 6.5 The report, as text and as JSON

### Why
The same data goes to the terminal and to a file for other programs. Zig's `std.json` works from types: give it a struct and it writes JSON with the field names as keys, and give it the same struct type and JSON and it fills the struct back in. No annotations, no schema file; the struct is the schema (lecture 5 explained how a library can do that).

### How
- **`Report`** is a plain struct of plain data: integers, nested structs, slices of structs, strings. That's the whole contract with `std.json`. `report()` fills it from the stats, allocating from an arena, so there's nothing to free piecemeal.
- **Clocks.** `Io.Timestamp.now(io, .real)` is the wall clock, nanoseconds since 1970 in an `i96`; `toMilliseconds` makes a familiar number for the file. `.awake` (used in `main`) is the monotonic clock, which never jumps backwards and is the one to measure with. `durationTo` and `untilNow` give an `Io.Duration`, which has a `format` method, so `{f}` prints it with the right unit.
- **`writeText`** prints the report to any writer. `{Bi:.1}` formats a byte count in binary units (`247.3KiB`); `{B}` would use decimal units. `{d:>5}` right-aligns.
- **`std.json.Stringify.valueAlloc(gpa, value, options)`** serializes to a new string; `.{ .whitespace = .indent_2 }` pretty-prints, the default is compact. `Stringify.value(v, options, writer)` writes to a writer instead, with no intermediate string. Strings become JSON strings, slices become arrays, optionals become `null` or the value, enums their names.
- **`std.json.parseFromSlice(T, gpa, json, options)`** parses into a `T`, allocating what the result needs, and returns a `Parsed(T)` whose `deinit` frees it all; `.value` is the struct. A field missing from the JSON takes the struct's default value if it has one, and is an error otherwise; an unknown key is an error unless `.ignore_unknown_fields = true`. `parseFromSliceLeaky` (used in `main`) allocates from an arena and returns the bare value.
- **The round-trip test** serializes a report, checks a fragment of the text, parses it back into a `Report`, and compares.

### Code
`lecture_6/src/Stats.zig`, part 4:
```zig
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
```

## 6.6 Tests on the filesystem

### Why
Code that reads directories has to be tested against directories. `std.testing.tmpDir` creates a fresh directory under `.zig-cache/tmp` with a random name, and `cleanup` deletes it, so tests can create whatever tree they need and leave nothing behind.

### How
- **`std.testing.tmpDir(.{ .iterate = true })`** returns a `TmpDir` whose `.dir` is an open `Io.Dir`; the options are the directory's open options, and the walker needs `.iterate`. `defer tmp.cleanup()` removes the tree. **`std.testing.io`** is the test runner's `Io`, the test-time equivalent of `init.io`.
- **`makeTree`** builds the fixture with `writeFile` (create and write in one call, taking `.sub_path` and `.data`) and `createDirPath` (which makes intermediate directories, like `mkdir -p`). It includes an ignored directory, a file without a trailing newline, a nested file and a binary file, so the tests exercise each rule.
- **The scan test** checks totals, per-extension counts, that the ignored directory was seen but not entered (`kinds.get(.directory)` is 3), and that a word inside the binary file wasn't counted. The `std` count is 2 because `@import("std")` tokenizes to `std` twice: the quotes are delimiters.
- **The ordering test** checks `largestFiles` and `topWords`, including the alphabetical tie-break: four words appear twice each.
- **The streaming test** is 6.3's. **The JSON test** is 6.5's.

### Code
`lecture_6/src/Stats.zig`, part 5:
```zig
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
```

## 6.7 The program

### Why
A command-line tool has a shape: parse arguments, read configuration, do the work, report, exit with a status. `main.zig` is that shape in Zig, with the standard library's pieces for each step.

### How
- **`pub const std_options: std.Options`** in the root file configures the standard library; `.log_level = .info` makes `std.log.info` visible in every build (the default hides it in release builds). It's a compile-time setting: filtered messages cost nothing.
- **`std.log.scoped(.codestat)`** returns a logger whose messages are prefixed `info(codestat): `; `.err`, `.warn`, `.info` and `.debug` are its functions. Logs go to standard error, so they interleave with the report's standard output on a terminal but separate cleanly when either is redirected. A library should use its own scope so an application can silence it (`std.Options.log_scope_levels`).
- **`Config`** has defaults, and `std.json.parseFromSliceLeaky` fills whatever the file provides. `catch |err| switch (err)` on `readFileAlloc` treats a missing file as "use the defaults" and passes any other error up: the lecture 4 pattern. The arena is `init.arena`, the process arena freed at exit, which is right for data that lives the whole run.
- **Arguments** come from `init.minimal.args.toSlice(arena)`; `args[0]` is the program. The loop handles `--flag value` by advancing `i`, and anything that isn't a flag is the root. A bad command line prints the usage and returns 2.
- **`main` returns `!u8`:** the exit status. `0` is success, `1` is "couldn't open the root" after an `err`-level log, `2` is a usage error. An error returned with `try` is also possible, and gives status 1 with an error return trace.
- **The environment:** `init.environ_map.get("CODESTAT_TOP")` returns `?[]const u8`. The layering (defaults, file, environment, command line) is the usual convention.
- **Timing:** `Io.Timestamp.now(io, .awake)` before the scan, `start.untilNow(io, .awake)` after, printed with `{f}`.
- **Opening the root:** `Io.Dir.cwd().openDir(io, path, .{ .iterate = true })`; `defer root_dir.close(io)`. **Writing the JSON:** `Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json })` creates or truncates. Paths are relative to the process's working directory: `zig build run` runs the program where you ran `zig build`, so from `lecture_6/` the sample `codestat.json` is found and its `"root": ".."` points at the repository.

### Code
`lecture_6/codestat.json`:
```json
{
    "root": "..",
    "top": 8,
    "ignore": [".zig-cache", "zig-out", ".git"],
    "report_path": "codestat-report.json"
}
```

`lecture_6/src/main.zig`:
```zig
//! codestat: statistics about a tree of source files.
//!
//!   zig build run -- [root] [--config file.json] [--top N] [--no-json]
//!
//! Settings come from, in increasing priority: the defaults below, codestat.json (or --config),
//! the CODESTAT_TOP environment variable, and the command line.

const std = @import("std");
const Io = std.Io;
const Stats = @import("Stats.zig");

test {
    _ = Stats;
}

/// std.log looks this up in the root file. Here: show info and above (the default hides info in
/// release builds), and keep the default output format.
pub const std_options: std.Options = .{
    .log_level = .info,
};

/// A scoped logger prefixes every message with the scope: "info(codestat): ...".
const log = std.log.scoped(.codestat);

/// The settings, with defaults. std.json fills this from the config file: fields missing from the
/// file keep their defaults, and unknown keys are rejected unless asked to be ignored.
const Config = struct {
    root: []const u8 = ".",
    top: usize = 5,
    ignore: []const []const u8 = &.{ ".zig-cache", "zig-out", ".git" },
    report_path: ?[]const u8 = "codestat-report.json",
};

/// Reads the config file if it exists. `arena` keeps the parsed strings alive for the whole run.
fn loadConfig(io: Io, arena: std.mem.Allocator, path: []const u8) !Config {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => {
            log.info("no {s}; using the defaults", .{path});
            return .{};
        },
        else => return err,
    };
    // parseFromSliceLeaky allocates everything from the arena and never frees: the arena does.
    const config = try std.json.parseFromSliceLeaky(Config, arena, bytes, .{ .ignore_unknown_fields = true });
    log.info("loaded {s}", .{path});
    return config;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    // The process arena: freed at exit, for things that live the whole run (the config, the report).
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    // Arguments, by hand: a flag takes the next argument as its value.
    const args = try init.minimal.args.toSlice(arena);
    var config_path: []const u8 = "codestat.json";
    var root_arg: ?[]const u8 = null;
    var top_arg: ?usize = null;
    var write_json = true;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i == args.len) return usage(out, "--config needs a path");
            config_path = args[i];
        } else if (std.mem.eql(u8, arg, "--top")) {
            i += 1;
            if (i == args.len) return usage(out, "--top needs a number");
            top_arg = std.fmt.parseInt(usize, args[i], 10) catch return usage(out, "--top needs a number");
        } else if (std.mem.eql(u8, arg, "--no-json")) {
            write_json = false;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return usage(out, "unknown flag");
        } else {
            root_arg = arg;
        }
    }

    // Layer the settings: file, then environment, then command line.
    var config = try loadConfig(io, arena, config_path);
    if (init.environ_map.get("CODESTAT_TOP")) |value| {
        config.top = std.fmt.parseInt(usize, value, 10) catch config.top;
        log.info("CODESTAT_TOP={s}", .{value});
    }
    if (root_arg) |root| config.root = root;
    if (top_arg) |top| config.top = top;

    // The scan, timed with the monotonic clock: it never jumps, unlike the real-time one.
    const start = Io.Timestamp.now(io, .awake);
    var root_dir = Io.Dir.cwd().openDir(io, config.root, .{ .iterate = true }) catch |err| {
        log.err("can't open {s}: {t}", .{ config.root, err });
        return 1;
    };
    defer root_dir.close(io);

    var stats = Stats.init(init.gpa, .{ .ignore = config.ignore });
    defer stats.deinit();
    try stats.scan(io, root_dir);
    const scan_time = start.untilNow(io, .awake);

    // The text report to stdout.
    const report = try stats.report(arena, io, config.top);
    try out.print("codestat: {s}\n\n", .{config.root});
    try Stats.writeText(report, out);

    // The largest file, counted again through a streaming reader, to show the two agree.
    if (report.largest_files.len > 0) {
        const largest = report.largest_files[0];
        const file = try root_dir.openFile(io, largest.path, .{});
        defer file.close(io);
        const streamed = try Stats.countLinesStreaming(io, file);
        try out.print("\n{s} re-counted through a 4 KiB buffer: {d} lines ({s})\n", .{ largest.path, streamed, if (streamed == largest.lines) "same" else "different!" });
    }

    // The JSON report to a file, with std.json doing the formatting.
    if (write_json) {
        if (config.report_path) |path| {
            const json = try std.json.Stringify.valueAlloc(arena, report, .{ .whitespace = .indent_2 });
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
            log.info("wrote {s} ({Bi:.1})", .{ path, json.len });
        }
    }

    // Durations print with {f}: the format method picks the unit.
    log.info("scanned {d} entries in {f}", .{ report.scanned_entries, scan_time });
    return 0;
}

/// Prints the usage and returns the exit code for a bad command line: main returns a u8.
fn usage(out: *Io.Writer, problem: []const u8) !u8 {
    try out.print("error: {s}\nusage: codestat [root] [--config file.json] [--top N] [--no-json]\n", .{problem});
    return 2;
}
```

## 6.8 Running it

### How
From `lecture_6/`, where the sample config is:
```bash
zig build run -- --top 6
```
```text
info(codestat): loaded codestat.json
info(codestat): wrote codestat-report.json (2.0KiB)
info(codestat): scanned 66 entries in 42.968ms
codestat: ..

33 files, 7864 lines, 403.1KiB in 66 directory entries

By extension:
  .md          5 files     4094 lines   247.3KiB
  .zig        18 files     3610 lines   151.2KiB
  .bash        1 files       99 lines     2.8KiB
  .zon         6 files       42 lines     1.4KiB
  (none)       1 files        7 lines       169B
  .json        1 files        6 lines       127B
  .cells       1 files        6 lines       138B

Most common identifiers:
  the                  2142
  std                  1136
  and                  1039
  const                936
  try                  829
  self                 506

Largest files:
    1009 lines  lecture-md/lecture_5/lecture_5.md
     988 lines  lecture-md/lecture_4/lecture_4.md
     735 lines  lecture-md/lecture_2/lecture_2.md
     681 lines  lecture-md/lecture_1/lecture_1.md
     681 lines  lecture-md/lecture_3/lecture_3.md
     469 lines  lecture_4/src/calc.zig

lecture-md/lecture_5/lecture_5.md re-counted through a 4 KiB buffer: 1009 lines (same)
```
The numbers are a snapshot of the repository at the time of writing. The three `info` lines come first because standard error is unbuffered and standard output is flushed at the end. `codestat-report.json` appears next to where the program ran (it's in `.gitignore`), and starts:
```json
{
  "generated_at_ms": 1794076950683,
  "scanned_entries": 66,
  "total": {
    "files": 33,
    "lines": 7864,
    "bytes": 412752
  },
  "by_extension": [
    {
      "extension": ".md",
      ...
```
`zig build run -- /nonexistent` logs `error(codestat): can't open /nonexistent: FileNotFound` and exits with 1; `zig build run -- --bogus` prints the usage and exits with 2, which the build runner reports as the run step failing. `CODESTAT_TOP=3 zig build run -- --no-json` takes the count from the environment and writes nothing. `zig build test` runs the five tests (four in `Stats.zig`, in temporary directories under `.zig-cache/tmp`, plus the discovery block).

Two experiments: switch `by_extension` to `std.StringHashMap(Totals)` (managed, `init(gpa)`, no allocator per call) and watch what else must change, then notice the report's order no longer follows first appearance; and change the reader buffer in `countLinesStreaming` to 64 bytes, so every line in the streaming test is `StreamTooLong`, and the count still comes out at 300.
