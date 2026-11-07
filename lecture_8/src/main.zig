//! Lecture 8: threads, the Io concurrency primitives, and a networked service.
//!
//!   zig build run -- [--port N] [--connections N]
//!
//! The demos come first; then the notes server runs until it has handled N connections
//! (or forever, with 0, until Ctrl-C).

const std = @import("std");
const Io = std.Io;
const Store = @import("Store.zig");
const Server = @import("Server.zig");

test {
    _ = Store;
    _ = Server;
}

pub const std_options: std.Options = .{ .log_level = .info };

// Threads and shared memory

const iterations = 1_000_000;

/// Two threads adding to a plain integer: a data race. Each `+= 1` is a read, an add and a write,
/// and when the threads interleave, increments are lost. The result is wrong and different every run.
var racy_counter: u64 = 0;
fn incrementRacy() void {
    for (0..iterations) |_| racy_counter += 1;
}

/// The same with an atomic: fetchAdd is one indivisible operation, so nothing is lost.
var atomic_counter: std.atomic.Value(u64) = .init(0);
fn incrementAtomic() void {
    for (0..iterations) |_| _ = atomic_counter.fetchAdd(1, .monotonic);
}

/// The same with a mutex: slower than the atomic, but a mutex protects any amount of work, not one
/// integer operation. Io.Mutex.lock takes the io because waiting for a lock is an Io operation.
var locked_counter: u64 = 0;
var counter_mutex: Io.Mutex = .init;
fn incrementLocked(io: Io) void {
    for (0..iterations) |_| {
        counter_mutex.lockUncancelable(io);
        defer counter_mutex.unlock(io);
        locked_counter += 1;
    }
}

fn demoThreads(io: Io) !void {
    std.debug.print("Threads and shared memory ({d} increments each, two threads):\n", .{iterations});

    // spawn starts the thread running `function(args...)` at once; join waits for it to finish.
    const r1 = try std.Thread.spawn(.{}, incrementRacy, .{});
    const r2 = try std.Thread.spawn(.{}, incrementRacy, .{});
    r1.join();
    r2.join();
    std.debug.print("    plain u64:   {d} (expected {d}; the race loses increments)\n", .{ racy_counter, 2 * iterations });

    const a1 = try std.Thread.spawn(.{}, incrementAtomic, .{});
    const a2 = try std.Thread.spawn(.{}, incrementAtomic, .{});
    a1.join();
    a2.join();
    std.debug.print("    atomic u64:  {d}\n", .{atomic_counter.load(.monotonic)});

    const l1 = try std.Thread.spawn(.{}, incrementLocked, .{io});
    const l2 = try std.Thread.spawn(.{}, incrementLocked, .{io});
    l1.join();
    l2.join();
    std.debug.print("    with mutex:  {d}\n", .{locked_counter});
    std.debug.print("    this machine has {d} logical CPUs\n", .{try std.Thread.getCpuCount()});
}

// Tasks and futures

/// Any function can be a task. This one sums a range, slowly enough to be worth splitting.
fn sumRange(first: u64, last: u64) u64 {
    var total: u64 = 0;
    var i = first;
    while (i < last) : (i += 1) total += i * i % 7;
    return total;
}

fn demoFutures(io: Io) void {
    std.debug.print("Tasks and futures:\n", .{});
    // io.async runs the function as a task: on the threaded Io, on another thread when one is free.
    // The result comes back through a Future; await blocks until the task is done.
    var halves: [4]Io.Future(u64) = undefined;
    for (&halves, 0..) |*future, i| {
        future.* = io.async(sumRange, .{ i * 25_000_000, (i + 1) * 25_000_000 });
    }
    var total: u64 = 0;
    for (&halves) |*future| total += future.await(io);
    std.debug.print("    four tasks summed 100 million terms: {d}\n", .{total});
}

// A queue between producers and consumers

/// Producers put numbers; consumers take them and add them up. The queue has a fixed buffer, so a
/// producer blocks when it's full and a consumer blocks when it's empty: back-pressure for free.
fn produce(io: Io, queue: *Io.Queue(u32), first: u32, last: u32) void {
    var n = first;
    while (n < last) : (n += 1) queue.putOne(io, n) catch return;
}

fn consume(io: Io, queue: *Io.Queue(u32), total: *std.atomic.Value(u64)) void {
    // getOne returns error.Closed once the queue is closed and drained: the signal to stop.
    while (queue.getOne(io)) |n| {
        _ = total.fetchAdd(n, .monotonic);
    } else |_| {}
}

fn demoQueue(io: Io) !void {
    std.debug.print("A queue between tasks:\n", .{});
    var buffer: [8]u32 = undefined;
    var queue: Io.Queue(u32) = .init(&buffer);
    var total: std.atomic.Value(u64) = .init(0);

    // A group holds any number of tasks and waits for all of them. Consumers first, so they're
    // waiting when the numbers arrive; then two producers; then close the queue once they're done.
    var consumers: Io.Group = .init;
    for (0..3) |_| consumers.async(io, consume, .{ io, &queue, &total });
    var producers: Io.Group = .init;
    producers.async(io, produce, .{ io, &queue, 1, 501 });
    producers.async(io, produce, .{ io, &queue, 501, 1001 });
    try producers.await(io);
    queue.close(io);
    try consumers.await(io);
    std.debug.print("    1 to 1000 through an 8-slot queue, 2 producers, 3 consumers: {d} (expected 500500)\n", .{total.load(.monotonic)});
}

// The program

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    try demoThreads(io);
    demoFutures(io);
    try demoQueue(io);

    // Arguments: --port N (default 8080), --connections N (default 0: serve forever).
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var port: u16 = 8080;
    var connections: usize = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            i += 1;
            port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--connections") and i + 1 < args.len) {
            i += 1;
            connections = try std.fmt.parseInt(usize, args[i], 10);
        } else {
            std.debug.print("usage: lecture_8 [--port N] [--connections N]\n", .{});
            return error.BadArguments;
        }
    }

    // The store and the server share this thread's stack and live until serve returns; every
    // connection task borrows them through pointers.
    var store = Store.init(init.gpa);
    defer store.deinit();
    _ = try store.create(io, .{ .title = "read lecture 8" });
    _ = try store.create(io, .{ .title = "try the API with curl" });

    var server = try Server.init(init.gpa, io, &store, port);
    defer server.deinit();
    std.debug.print(
        \\
        \\Notes API listening on http://{f}  (serving {d} connections; 0 means until Ctrl-C)
        \\    curl http://{f}/notes
        \\    curl -X POST http://{f}/notes -d '{{"title": "new note"}}'
        \\    curl -X PUT  http://{f}/notes/1 -d '{{"title": "read lecture 8", "done": true}}'
        \\    curl -X DELETE http://{f}/notes/2
        \\    curl http://{f}/stats
        \\
    , .{ server.address(), connections, server.address(), server.address(), server.address(), server.address(), server.address() });
    try server.serve(connections);
    std.debug.print("served {d} requests, {d} failed; {d} notes remain\n", .{ server.requests.load(.monotonic), server.errors.load(.monotonic), try store.count(io) });
}
