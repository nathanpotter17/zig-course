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
