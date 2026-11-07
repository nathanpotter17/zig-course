# Lecture 8: Threads, tasks and a networked service

Everything so far ran on one thread. This lecture is about doing several things at once: operating-system threads and the trouble they bring (data races), the tools that make shared memory safe (atomics, mutexes, reader/writer locks), and Zig 0.17's higher-level `std.Io` primitives (tasks, futures, groups, queues). The project puts them to work: a small HTTP service with a JSON API for creating, reading, updating and deleting notes, where every client connection is handled as its own task, so many clients can be served at the same time.

- **Threads:** `std.Thread.spawn` and `join`, and a demonstration of what goes wrong when two threads write the same integer.
- **Atomics and mutexes:** `std.atomic.Value(u64)`, `Io.Mutex`, and when each is the right tool.
- **Tasks and futures:** `io.async` returns an `Io.Future`; `Io.Group` runs any number of tasks and waits for all of them.
- **Queues:** `Io.Queue(T)`, a bounded channel between producers and consumers, with back-pressure and a close signal.
- **A reader/writer lock:** `Io.RwLock`, letting many readers share the notes while a writer has them alone.
- **Networking:** `Io.net.IpAddress`, listening, accepting, and reading and writing a TCP stream through the same `Io.Reader`/`Io.Writer` interfaces as files.
- **HTTP by hand and JSON:** request lines, headers, `Content-Length`, and `std.json` for both directions.
- **Testing a server:** a test that runs the server on a thread and plays the client, and one with four clients at once.

The files:
```text
lecture_8/
  build.zig, build.zig.zon       the usual template
  src/main.zig                   the concurrency demos and the program
  src/Store.zig                  the notes, behind a reader/writer lock
  src/Server.zig                 the HTTP server, one task per connection
```

## 8.1 Threads and shared memory

### Why
A thread is the operating system's unit of parallel execution: two threads run on two CPUs at the same time. They share the process's memory, which is both the point and the problem. When two threads modify the same variable without coordination, the result is a *data race*, and the program's behavior is undefined. The classic demonstration is two threads each adding one to a counter a million times. `counter += 1` is three operations (load, add, store), and when the threads interleave, one thread's store overwrites the other's and an increment is lost.

### How
- **`std.Thread.spawn(.{}, function, args)`** starts a new thread running `function(args...)` and returns a `Thread`. **`join()`** waits for it to finish; **`detach()`** lets it run on its own. The first argument is a config struct (stack size, allocator), `.{}` for the defaults. `std.Thread.getCpuCount()` says how many can really run in parallel.
- **Atomics.** `std.atomic.Value(T)` wraps an integer (or pointer, or bool) so every operation on it is indivisible: `fetchAdd(1, .monotonic)` adds and returns the old value as one step that no other thread can interleave with. `load` and `store` take the same *ordering* argument; `.monotonic` is the weakest and is enough for a counter nobody uses to synchronize other memory. (`.acquire`/`.release`/`.seq_cst` also order other memory accesses around the atomic; that's a lecture of its own.) An atomic protects one variable; it can't make two variables change together.
- **Mutexes.** `Io.Mutex` makes a region of code run by one thread at a time: `lock`, do the work, `unlock`. Any amount of work goes between them, and a `defer unlock` guarantees the unlock on every path. In 0.17 the mutex is an `Io` primitive because *waiting* for a lock is an I/O-like operation the `Io` implementation may handle (by parking the thread, or by switching to another task). `lock(io)` is a *cancelation point* and so returns `Cancelable!void`; `lockUncancelable(io)` returns `void`, for code that has no way to handle cancelation.
- **Where the compiler stands.** Zig doesn't detect data races at compile time (there's no borrow checker), and the debug build doesn't detect them either; the race above produces a wrong number silently. The optimizer may also *hide* it: in `-Doptimize=fast` the loop of a million `+= 1` becomes a single `+= 1_000_000`, and the two threads' single additions happen not to collide. A result that looks right in one build mode is not evidence of correctness.

### Code
`src/main.zig`, part 1 of 4:
```zig
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
```
The `test {}` block at the top is the test-discovery trick from lecture 2: referencing the two imported files makes their tests part of `zig build test`.

## 8.2 Tasks, futures and the Io implementation

### Why
Threads are a low-level tool: you create them by hand, pass pointers to shared state, and join them. For "run this function and give me its result later", 0.17 has *tasks*. `io.async(function, args)` starts the function as a task and returns an `Io.Future(T)`; `future.await(io)` waits for and returns the result. How a task runs is decided by the `Io` implementation, not by your code: the standard `Io.Threaded` runs tasks on a pool of threads it grows on demand, a single-threaded `Io` runs them inline, and an event-loop `Io` would interleave them. The same program source works with all of them, which is the whole idea behind the `Io` parameter you've been passing around since lecture 1.

### How
- **`io.async(function, args)`** returns `Io.Future(ReturnType)`. The function may already have run by the time `async` returns (the implementation is allowed to run it synchronously), or it may be running on another thread; either way the result is only available after **`await(io)`**. Each future must be awaited (or canceled) exactly once.
- **`io.concurrent(function, args)`** is the stricter cousin: it *guarantees* the function runs concurrently with the caller, and fails with `error.ConcurrencyUnavailable` if the implementation can't provide that. Use `async` when you just want parallelism if available (a computation split in parts), and `concurrent` when correctness depends on it (a task that must keep running while the caller waits for it on a channel).
- **`Io.Threaded`'s rules.** The `io` that `main` receives is an `Io.Threaded` created in `std.start`. It allows up to *CPU count minus one* tasks to run at once (its `async_limit`); each `async` beyond that runs inline on the caller's thread. Worker threads are created when needed and reused.
- **A task is just a function.** No special return type, no keyword. Arguments are copied into the task, so pass pointers to anything the task should share, and make sure what they point at outlives the `await`.

### Code
`src/main.zig`, part 2 of 4:
```zig
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
```

## 8.3 Groups and a queue between tasks

### Why
When the number of tasks isn't fixed (one per connection, one per file), holding an array of futures is awkward. `Io.Group` holds any number of tasks and waits for all of them with one call. And when tasks need to hand each other work, a *queue* is the tool: producers put items in, consumers take them out, and the queue does the waiting on both sides. A *bounded* queue (fixed buffer) adds back-pressure: a producer that's too fast blocks until a consumer catches up, so memory use stays constant.

### How
- **`Io.Group`** starts as `.init`. **`group.async(io, function, args)`** adds a task; the function must return `void` (or `Cancelable!void`), since there's nowhere to put a result. **`group.await(io)`** waits for every task; **`group.cancel(io)`** asks the running tasks to stop (at their next cancelation point) and then waits. One of the two must be called before the group goes out of scope, which is what the `defer group.cancel(io)` in the server does.
- **`Io.Queue(T)`** is initialized with a buffer you own: `.init(&buffer)`. **`putOne(io, item)`** blocks while the buffer is full; **`getOne(io)`** blocks while it's empty; both return `error.Closed` after **`close(io)`**, once the remaining items have been drained. Closing is how producers tell consumers "no more work": the consumer loop ends when `getOne` returns the error. Both operations are also cancelation points (`Cancelable`), hence the `catch` in the loops.
- **The pattern:** start the consumers, start the producers, wait for the producers, close the queue, wait for the consumers. Starting consumers first is not required, just natural; a consumer that arrives late finds the items waiting in the buffer.
- **Reading the counters.** The consumers add into a `std.atomic.Value(u64)` shared through a pointer. The total is read with `load` after `await`, when all tasks are done.

### Code
`src/main.zig`, part 3 of 4:
```zig
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
```
The `while (…) |n| { … } else |_| {}` form is the error-union loop from lecture 4: the loop runs while `getOne` succeeds and the `else` branch receives the error that ended it.

## 8.4 The store: a reader/writer lock

### Why
The notes are the shared state of the whole server. Every connection reads or changes them, concurrently. A mutex would work, but it serializes everything, including reads that could happily run side by side. A *reader/writer lock* distinguishes the two: any number of readers may hold it at once, and a writer waits until the readers leave and then holds it alone. For a service that is read far more than written, that's the right trade. The store is a file-struct like lecture 6's `Stats`: the file's top-level fields are the struct's fields, and `@This()` names it.

### How
- **`Io.RwLock`** starts as `.init`. **`lock(io)`/`unlock(io)`** are the exclusive pair, for writers; **`lockShared(io)`/`unlockShared(io)`** the shared pair, for readers. Both `lock` variants are cancelation points, so they return `Cancelable!void` and the methods propagate that in their error sets (`Error = Allocator.Error || Io.Cancelable`).
- **Copy out, don't lend.** `list` and `get` return *copies* of the notes, with the titles duplicated into an arena the caller supplies. Returning slices into the store would be a use-after-free waiting to happen: as soon as the lock is released, another task may update or delete the note, and the caller's slice would point at freed memory. The copies cost an allocation; the alternative costs a crash under load.
- **Allocate before locking.** `create` and `update` duplicate the new title *before* taking the lock, so the slow part (allocation) doesn't happen while every other task waits. Inside the lock only the table changes.
- **`errdefer` is for errors, not for "no".** `update` duplicates the title, then finds the note doesn't exist and returns `false`. That's a successful return, so `errdefer self.gpa.free(title)` does *not* run, and the title would leak. The explicit `free` in the `orelse` block handles it; the testing allocator is what caught the leak when it was missing.
- **`std.AutoArrayHashMapUnmanaged(u32, Note)`** keeps the notes in insertion order (so listings are in creation order) with O(1) lookup by id. `getPtr` returns a pointer into the table for in-place update; `orderedRemove` deletes and preserves the order. The only array hash map in 0.17 is the unmanaged one, so every call takes the allocator.

### Code
`src/Store.zig`, part 1 of 2:
```zig
//! The notes store: an in-memory table shared by every connection, guarded by a reader/writer lock.
//! Any number of tasks may read at once; a write waits for the readers and excludes everyone.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Store = @This();

/// A note as the API shows it.
pub const Note = struct {
    id: u32,
    title: []const u8,
    done: bool = false,
};

/// What a client sends to create or update a note: everything but the id.
pub const Input = struct {
    title: []const u8,
    done: bool = false,
};

gpa: Allocator,
lock: Io.RwLock = .init,
/// id -> note, in insertion order, so listings come out in the order of creation.
notes: std.AutoArrayHashMapUnmanaged(u32, Note) = .empty,
next_id: u32 = 1,

pub const Error = Allocator.Error || Io.Cancelable;

pub fn init(gpa: Allocator) Store {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Store) void {
    for (self.notes.values()) |note| self.gpa.free(note.title);
    self.notes.deinit(self.gpa);
}

/// Adds a note and returns it with its new id. An exclusive lock: nobody else reads or writes meanwhile.
pub fn create(self: *Store, io: Io, input: Input) Error!Note {
    const title = try self.gpa.dupe(u8, input.title);
    errdefer self.gpa.free(title);

    try self.lock.lock(io);
    defer self.lock.unlock(io);
    const note = Note{ .id = self.next_id, .title = title, .done = input.done };
    try self.notes.put(self.gpa, note.id, note);
    self.next_id += 1;
    return note;
}

/// A copy of every note, with the titles duplicated into `arena`, so the caller can read them after
/// the lock is released and other tasks have changed the store. A shared lock: readers run together.
pub fn list(self: *Store, io: Io, arena: Allocator) Error![]Note {
    try self.lock.lockShared(io);
    defer self.lock.unlockShared(io);
    const copies = try arena.alloc(Note, self.notes.count());
    for (self.notes.values(), copies) |note, *copy| {
        copy.* = .{ .id = note.id, .title = try arena.dupe(u8, note.title), .done = note.done };
    }
    return copies;
}

/// One note by id, copied into `arena`, or null.
pub fn get(self: *Store, io: Io, arena: Allocator, id: u32) Error!?Note {
    try self.lock.lockShared(io);
    defer self.lock.unlockShared(io);
    const note = self.notes.get(id) orelse return null;
    return .{ .id = note.id, .title = try arena.dupe(u8, note.title), .done = note.done };
}

/// Replaces a note's title and state. Returns false if there's no such note.
pub fn update(self: *Store, io: Io, id: u32, input: Input) Error!bool {
    const title = try self.gpa.dupe(u8, input.title);
    errdefer self.gpa.free(title);

    try self.lock.lock(io);
    defer self.lock.unlock(io);
    const note = self.notes.getPtr(id) orelse {
        self.gpa.free(title); // errdefer only runs on an error, and "not found" isn't one
        return false;
    };
    self.gpa.free(note.title);
    note.title = title;
    note.done = input.done;
    return true;
}

/// Removes a note. Returns false if there's no such note.
pub fn remove(self: *Store, io: Io, id: u32) Io.Cancelable!bool {
    try self.lock.lock(io);
    defer self.lock.unlock(io);
    const note = self.notes.get(id) orelse return false;
    self.gpa.free(note.title);
    _ = self.notes.orderedRemove(id);
    return true;
}

pub fn count(self: *Store, io: Io) Io.Cancelable!usize {
    try self.lock.lockShared(io);
    defer self.lock.unlockShared(io);
    return self.notes.count();
}
```

## 8.5 Testing the store, alone and under contention

### Why
The first test is ordinary: create, list, update, delete, check the results. The second is the one that matters for a concurrent data structure: eight threads hammering `create` at once. Without the lock, the hash map would corrupt itself and `next_id` would hand out duplicates. With it, the test asserts exactly 400 notes, `next_id` of 401, and no duplicate id. The test can't prove the absence of races (a race may not show up in a given run), but a test like this fails loudly and often when the locking is wrong, which is as good as testing gets here.

### How
- **`std.testing.io`** is an `Io.Threaded` the test runner provides, the same kind `main` gets.
- **A thread function can't return an error** to anyone, so `createMany` turns a failure into a `std.debug.panic`, which fails the test with a message and a stack trace.
- **Peeking inside.** The second test reads `store.next_id` and `store.notes.keys()` directly, after all the threads have been joined. Tests live in the same file, so nothing is private to them; and once the threads are gone, no lock is needed.

### Code
`src/Store.zig`, part 2 of 2:
```zig
// Tests

test "create, read, update, delete" {
    const io = std.testing.io;
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const milk = try store.create(io, .{ .title = "buy milk" });
    const zig = try store.create(io, .{ .title = "learn zig", .done = true });
    try std.testing.expectEqual(1, milk.id);
    try std.testing.expectEqual(2, zig.id);

    const all = try store.list(io, arena.allocator());
    try std.testing.expectEqual(2, all.len);
    try std.testing.expectEqualStrings("buy milk", all[0].title);

    try std.testing.expect(try store.update(io, 1, .{ .title = "buy oat milk", .done = true }));
    try std.testing.expectEqualStrings("buy oat milk", (try store.get(io, arena.allocator(), 1)).?.title);
    try std.testing.expect(!try store.update(io, 99, .{ .title = "nothing" }));

    try std.testing.expect(try store.remove(io, 1));
    try std.testing.expect(!try store.remove(io, 1));
    try std.testing.expectEqual(null, try store.get(io, arena.allocator(), 1));
    try std.testing.expectEqual(1, try store.count(io));
}

fn createMany(store: *Store, io: Io, how_many: usize) void {
    for (0..how_many) |_| {
        _ = store.create(io, .{ .title = "note" }) catch |err| std.debug.panic("create failed: {t}", .{err});
    }
}

test "concurrent writers never collide" {
    const io = std.testing.io;
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    // Eight threads each create 50 notes. The lock makes the ids unique and the count exact.
    var threads: [8]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, createMany, .{ &store, io, 50 });
    for (threads) |t| t.join();

    try std.testing.expectEqual(400, try store.count(io));
    try std.testing.expectEqual(401, store.next_id);
    var seen = std.AutoHashMap(u32, void).init(std.testing.allocator);
    defer seen.deinit();
    for (store.notes.keys()) |id| {
        const slot = try seen.getOrPut(id);
        try std.testing.expect(!slot.found_existing);
    }
}
```

## 8.6 Sockets: listen, accept, one task per connection

### Why
A TCP server does three things: bind an address and listen, accept connections one after another, and talk to each connection. The third must not block the second: if the server read a slow client's request to the end before accepting the next connection, one slow client would stall everyone. So each accepted connection is handed to a task in an `Io.Group` and the accept loop goes straight back to waiting. In 0.17, sockets are part of `std.Io`, and a connected socket is a `Stream` whose `reader` and `writer` are the same `Io.Reader`/`Io.Writer` you used on files in lecture 6; the HTTP code never knows it's talking to a socket.

### How
- **`Io.net.IpAddress.parseIp4("127.0.0.1", port)`** builds an address; port 0 means "any free port", and after listening, `listener.socket.address` has the port actually chosen. The tests rely on that to avoid colliding with anything else on the machine.
- **`address.listen(io, .{ .reuse_address = true })`** returns an `Io.net.Server`. `reuse_address` lets the program restart right away instead of waiting for the kernel's timeout on the old socket. **`accept(io)`** blocks until a client connects and returns an `Io.net.Stream`; **`deinit(io)`** closes the listener.
- **`group.async(self.io, handle, .{ self, stream })`** starts the connection's task. The `Stream` is passed by value (it's just a handle) and the server by pointer. Under `Io.Threaded`, up to CPU-count-minus-one connections are handled truly concurrently; past that, `async` runs the handler inline on the accept loop's thread, so on a single-CPU machine this server degrades gracefully to one connection at a time.
- **Termination.** `serve(max_connections)` accepts that many connections and then `await`s the group. The `defer group.cancel(io)` covers the error path: if `accept` fails, the tasks already running are still waited for before the function returns and the `Server` can be torn down. `main` passes `0` for "forever".
- **Per-connection memory.** Each task owns an `ArenaAllocator` for its parsed body and generated JSON, a read buffer big enough for the largest request it accepts (`max_body + 4096` for the headers) and a 4 KiB write buffer, all on the task's stack. The whole request is freed with `arena_state.deinit()` when the task ends.
- **Errors inside a task.** A group task returns `void`, so `handle` is where errors stop: it counts them, logs them with `std.log.warn`, and attempts a `500` response (ignoring a failure to send it, since the connection is probably what failed).
- **Counters** are `std.atomic.Value(u64)` fields because every task increments them; no lock is needed for a counter, as 8.1 showed.

### Code
`src/Server.zig`, part 1 of 4:
```zig
//! An HTTP server with a JSON API over the notes store. Every connection runs as a task in an
//! Io.Group, so connections are handled concurrently and a slow client doesn't block the rest.
//!
//!   GET    /notes        list
//!   POST   /notes        create  {"title": "...", "done": false}
//!   GET    /notes/{id}   read
//!   PUT    /notes/{id}   update  {"title": "...", "done": true}
//!   DELETE /notes/{id}   delete
//!   GET    /stats        counters

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Store = @import("Store.zig");

const Server = @This();

gpa: Allocator,
io: Io,
store: *Store,
listener: Io.net.Server,
started: Io.Timestamp,
/// Touched by every connection at once: atomics need no lock for a counter.
requests: std.atomic.Value(u64) = .init(0),
errors: std.atomic.Value(u64) = .init(0),

/// Bodies larger than this are refused: the whole request must fit the connection's buffer.
const max_body = 8 * 1024;

/// Starts listening on 127.0.0.1. Port 0 asks the system for a free one; `address()` says which.
pub fn init(gpa: Allocator, io: Io, store: *Store, port: u16) !Server {
    const bind_address = try Io.net.IpAddress.parseIp4("127.0.0.1", port);
    return .{
        .gpa = gpa,
        .io = io,
        .store = store,
        .listener = try bind_address.listen(io, .{ .reuse_address = true }),
        .started = Io.Timestamp.now(io, .awake),
    };
}

pub fn deinit(self: *Server) void {
    self.listener.deinit(self.io);
}

pub fn address(self: *const Server) Io.net.IpAddress {
    return self.listener.socket.address;
}

/// Accepts connections and hands each to a task. `max_connections` of 0 means forever.
pub fn serve(self: *Server, max_connections: usize) !void {
    var group: Io.Group = .init;
    // However this function exits, the tasks already running are waited for (cancel also awaits).
    defer group.cancel(self.io);

    var accepted: usize = 0;
    while (max_connections == 0 or accepted < max_connections) : (accepted += 1) {
        const stream = try self.listener.accept(self.io);
        // The task starts now (or as soon as a thread is free) and runs independently of this loop.
        group.async(self.io, handle, .{ self, stream });
    }
    try group.await(self.io);
}

/// One connection, start to finish. A Group task must return void (or Cancelable!void), so errors
/// are dealt with here: logged, counted, and a 500 sent if the connection is still usable.
fn handle(self: *Server, stream: Io.net.Stream) void {
    defer stream.close(self.io);
    _ = self.requests.fetchAdd(1, .monotonic);

    // Everything this request allocates (the parsed body, the JSON it sends back) lives in one arena.
    var arena_state = std.heap.ArenaAllocator.init(self.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var read_buffer: [max_body + 4096]u8 = undefined;
    var reader = stream.reader(self.io, &read_buffer);
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(self.io, &write_buffer);
    const out = &writer.interface;

    self.handleRequest(arena, &reader.interface, out) catch |err| {
        _ = self.errors.fetchAdd(1, .monotonic);
        std.log.warn("request failed: {t}", .{err});
        respond(out, "500 Internal Server Error", "text/plain", "internal error\n") catch {};
    };
}
```
`bind_address`, not `address`: a local may not shadow a declaration in the same scope, and `address` is the method below it. The compiler reports this as "local constant shadows declaration".

## 8.7 Parsing HTTP by hand

### Why
HTTP/1.1 is a text protocol simple enough to parse in thirty lines, and doing it once teaches you what the frameworks hide. A request is a *request line* (`POST /notes HTTP/1.1`), *header lines* (`Name: value`) up to an empty line, then a *body* whose length the `Content-Length` header announces. Lines end in `\r\n`. Everything the server needs for this API is the method, the path, and the body.

### How
- **`reader.takeDelimiter('\n')`** returns the next line *without* the delimiter and *consumes* the delimiter, or `null` at the end of the stream. Its sibling **`takeDelimiterExclusive`** also excludes the delimiter but leaves it in the stream: a second call would then return an empty slice at once. Using the wrong one here made every request look like it had no headers and no body; the tests caught it. (`takeDelimiterInclusive` returns the line with its delimiter.) The `\r` is trimmed off separately.
- **Slices into the buffer.** Everything `take*` returns points into the reader's buffer and stays valid until the reader is asked to read more and needs the space. Here the entire request is read once and nothing else is read from the connection afterwards, so the method, path and body remain valid for the whole handler, and no copies are made.
- **`reader.take(n)`** returns exactly `n` bytes, filling the buffer from the socket as needed; it *asserts* the buffer has room for `n`, which is why bodies over `max_body` are rejected before the call.
- **Header names are case-insensitive** (`content-length` and `Content-Length` are the same header): `std.ascii.eqlIgnoreCase`. `std.mem.cutScalar(u8, line, ':')` splits a line at the first colon into a two-element tuple, destructured as `const name, const value`; a line without a colon is skipped.
- **Two local errors**, `BadRequest` and `BodyTooLarge`, are turned into HTTP status codes by the caller; any other error (a connection reset, say) propagates up to `handle`.

### Code
`src/Server.zig`, part 2 of 4:
```zig
const Request = struct {
    method: []const u8,
    path: []const u8,
    body: []const u8,
};

/// Reads the request line, the headers (only Content-Length matters to us) and the body.
fn readRequest(reader: *Io.Reader) !Request {
    // takeDelimiter consumes the newline too and returns null at the end of the stream.
    const request_line = std.mem.trimEnd(u8, try reader.takeDelimiter('\n') orelse return error.BadRequest, "\r");
    var parts = std.mem.tokenizeScalar(u8, request_line, ' ');
    const method = parts.next() orelse return error.BadRequest;
    const target = parts.next() orelse return error.BadRequest;

    var content_length: usize = 0;
    while (true) {
        const line = std.mem.trimEnd(u8, try reader.takeDelimiter('\n') orelse return error.BadRequest, "\r");
        if (line.len == 0) break;
        const name, const value = std.mem.cutScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(usize, std.mem.trim(u8, value, " "), 10) catch return error.BadRequest;
        }
    }
    if (content_length > max_body) return error.BodyTooLarge;

    // The request line and headers are slices into the reader's buffer; the body is too. They stay
    // valid because nothing else is read from this connection.
    const body = try reader.take(content_length);
    return .{ .method = method, .path = target, .body = body };
}
```

## 8.8 Routing, JSON in and JSON out

### Why
With the request parsed, the handler is a dispatch on path and method to the store's five operations, plus a `/stats` page. Bodies come in as JSON and notes go out as JSON, and `std.json` handles both directions against the plain structs in `Store.zig`: parsing fills a `Store.Input`, serializing walks a `Store.Note` or a slice of them. Status codes follow the conventions clients expect: `201 Created` for a new resource, `204 No Content` for a successful delete, `404` for a missing id, `400` for a body that isn't what was asked for, `405` for a method the path doesn't support.

### How
- **`std.mem.cutPrefix(u8, path, "/notes/")`** returns the rest of the path if it starts with the prefix, or null: the natural shape for an `if (…) |id_text|` capture. A non-numeric id is a 404, not a 400; the resource simply doesn't exist.
- **`std.json.parseFromSliceLeaky(T, allocator, text, .{})`** parses into `T` and allocates whatever strings it needs from the allocator, without returning a handle to free them with ("leaky"); that's exactly right with an arena that's freed wholesale. The `Input` struct's `done: bool = false` default makes the field optional in the JSON; `title` has no default, so a body without it is a parse error. The `catch null` turns every parse error into "not an input" and thus a 400.
- **`std.json.Stringify.valueAlloc(allocator, value, .{})`** serializes any value `std.json` understands (structs, slices, optionals, integers, strings) to an allocated string. A `[]Note` becomes a JSON array of objects; the field names are the struct's.
- **A response** is the status line, a few headers and the body. `Content-Length` tells the client where the body ends, and `Connection: close` tells it the server will close the socket after this response, so one connection carries exactly one request. (Keeping connections alive and handling several requests on each is the next step a real server would take; here it would only add bookkeeping.) The `flush` matters: the writer is buffered, and nothing reaches the socket until then.
- **Uptime** uses `Io.Timestamp.now(io, .awake)` taken at startup and `untilNow(io, .awake)`, a `Duration` that formats itself with `{f}`.

### Code
`src/Server.zig`, part 3 of 4:
```zig
fn handleRequest(self: *Server, arena: Allocator, reader: *Io.Reader, out: *Io.Writer) !void {
    const req = readRequest(reader) catch |err| switch (err) {
        error.BadRequest => return respond(out, "400 Bad Request", "text/plain", "malformed request\n"),
        error.BodyTooLarge => return respond(out, "413 Content Too Large", "text/plain", "body too large\n"),
        else => return err,
    };
    const method = req.method;
    const path = req.path;
    const io = self.io;

    if (std.mem.eql(u8, path, "/notes")) {
        if (std.mem.eql(u8, method, "GET")) {
            const notes = try self.store.list(io, arena);
            return respondJson(arena, out, "200 OK", notes);
        }
        if (std.mem.eql(u8, method, "POST")) {
            const input = parseInput(arena, req.body) orelse return respond(out, "400 Bad Request", "text/plain", "expected {\"title\": \"...\", \"done\": false}\n");
            const note = try self.store.create(io, input);
            return respondJson(arena, out, "201 Created", note);
        }
        return respond(out, "405 Method Not Allowed", "text/plain", "use GET or POST\n");
    }

    // /notes/{id}: cutPrefix strips the prefix, leaving the id to parse.
    if (std.mem.cutPrefix(u8, path, "/notes/")) |id_text| {
        const id = std.fmt.parseInt(u32, id_text, 10) catch return respond(out, "404 Not Found", "text/plain", "no such note\n");
        if (std.mem.eql(u8, method, "GET")) {
            const note = try self.store.get(io, arena, id) orelse return respond(out, "404 Not Found", "text/plain", "no such note\n");
            return respondJson(arena, out, "200 OK", note);
        }
        if (std.mem.eql(u8, method, "PUT")) {
            const input = parseInput(arena, req.body) orelse return respond(out, "400 Bad Request", "text/plain", "expected {\"title\": \"...\", \"done\": false}\n");
            if (!try self.store.update(io, id, input)) return respond(out, "404 Not Found", "text/plain", "no such note\n");
            const note = (try self.store.get(io, arena, id)) orelse return respond(out, "404 Not Found", "text/plain", "no such note\n");
            return respondJson(arena, out, "200 OK", note);
        }
        if (std.mem.eql(u8, method, "DELETE")) {
            if (!try self.store.remove(io, id)) return respond(out, "404 Not Found", "text/plain", "no such note\n");
            return respond(out, "204 No Content", "text/plain", "");
        }
        return respond(out, "405 Method Not Allowed", "text/plain", "use GET, PUT or DELETE\n");
    }

    if (std.mem.eql(u8, path, "/stats") and std.mem.eql(u8, method, "GET")) {
        const text = try std.fmt.allocPrint(arena, "requests {d}\nerrors {d}\nnotes {d}\nuptime {f}\n", .{
            self.requests.load(.monotonic),
            self.errors.load(.monotonic),
            try self.store.count(io),
            self.started.untilNow(io, .awake),
        });
        return respond(out, "200 OK", "text/plain", text);
    }

    return respond(out, "404 Not Found", "text/plain", "no such page\n");
}

/// A note's fields from a JSON body, or null if the body isn't one. parseFromSliceLeaky allocates
/// from the arena, which the connection frees as a whole.
fn parseInput(arena: Allocator, body: []const u8) ?Store.Input {
    return std.json.parseFromSliceLeaky(Store.Input, arena, body, .{}) catch null;
}

/// A complete HTTP/1.1 response. Content-Length lets the client know where the body ends, and
/// Connection: close means one request per connection, which keeps the server simple.
fn respond(out: *Io.Writer, status: []const u8, content_type: []const u8, body: []const u8) !void {
    try out.print("HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, content_type, body.len });
    try out.writeAll(body);
    try out.flush();
}

/// Any value std.json can serialize, as a JSON response.
fn respondJson(arena: Allocator, out: *Io.Writer, status: []const u8, value: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(arena, value, .{});
    try respond(out, status, "application/json", json);
}
```
One subtlety in the PUT branch: `update` and the following `get` are two separate lock acquisitions, and another task could delete the note between them. That's why the `get` result is still checked for null rather than unwrapped with `.?`. Shared state makes "I just wrote it, so it's there" false.

## 8.9 Testing a server

### Why
A server is tested the same way it's used: start it, connect, send bytes, read bytes. The tests here spawn the server on a `std.Thread` with a fixed connection budget, play the client from the test thread with a ten-line HTTP client, and parse the JSON that comes back with the same `std.json` the server used to make it. The second test is the concurrency check: four client threads, ten requests each, and the store must end with exactly forty notes.

### How
- **A fixed budget ends the server.** `serveInThread(&server, 7)` serves exactly seven connections and returns; the test makes exactly seven requests and then `join`s the thread. No signals, no shutdown flag: the simplest possible termination, and it also makes `requests 7` in the stats a checkable fact.
- **The client** connects with `address.connect(io, .{ .mode = .stream })`, writes the request through a buffered `Stream.writer`, flushes, and reads the whole response with `reader.interface.allocRemaining(gpa, .unlimited)`, which reads until the server closes the connection (the `Connection: close` promise at work). `bodyOf` finds the blank line and returns what follows.
- **`std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 201 Created\r\n"))`** checks the status line; the body is parsed into a `Store.Note` (or a `[]Store.Note` for the list) and checked field by field.
- **The concurrent test** joins the server thread with a `defer` and the client threads explicitly; `store.count` after all the joins gives the final tally. If the server mishandled concurrent connections, requests would fail, time out, or produce fewer than forty notes.
- **Shadowing, again:** the client helper is called `request`, so the handler's local in part 3 had to be `req`.

### Code
`src/Server.zig`, part 4 of 4:
```zig
// Tests

/// A minimal HTTP client for the tests: one request, the whole response back. Caller owns the result.
fn request(gpa: Allocator, io: Io, server_address: Io.net.IpAddress, method: []const u8, target: []const u8, body: []const u8) ![]u8 {
    const stream = try server_address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.print("{s} {s} HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n{s}", .{ method, target, body.len, body });
    try writer.interface.flush();

    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    return reader.interface.allocRemaining(gpa, .unlimited);
}

/// The body of a response: everything after the blank line.
fn bodyOf(response: []const u8) []const u8 {
    const start = std.mem.find(u8, response, "\r\n\r\n") orelse return "";
    return response[start + 4 ..];
}

fn serveInThread(server: *Server, max_connections: usize) void {
    server.serve(max_connections) catch |err| std.debug.panic("server failed: {t}", .{err});
}

test "the full CRUD cycle over HTTP" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var store = Store.init(gpa);
    defer store.deinit();
    var server = try Server.init(gpa, io, &store, 0);
    defer server.deinit();

    // The server handles exactly seven connections on its own thread while the test plays the client.
    const thread = try std.Thread.spawn(.{}, serveInThread, .{ &server, 7 });
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const addr = server.address();

    const created = try request(a, io, addr, "POST", "/notes", "{\"title\": \"write lecture 8\"}");
    try std.testing.expect(std.mem.startsWith(u8, created, "HTTP/1.1 201 Created\r\n"));
    const note = try std.json.parseFromSliceLeaky(Store.Note, a, bodyOf(created), .{});
    try std.testing.expectEqual(1, note.id);
    try std.testing.expectEqualStrings("write lecture 8", note.title);
    try std.testing.expect(!note.done);

    const listed = try request(a, io, addr, "GET", "/notes", "");
    const notes = try std.json.parseFromSliceLeaky([]Store.Note, a, bodyOf(listed), .{});
    try std.testing.expectEqual(1, notes.len);

    const updated = try request(a, io, addr, "PUT", "/notes/1", "{\"title\": \"write lecture 8\", \"done\": true}");
    try std.testing.expect(std.mem.startsWith(u8, updated, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect((try std.json.parseFromSliceLeaky(Store.Note, a, bodyOf(updated), .{})).done);

    const bad = try request(a, io, addr, "POST", "/notes", "this is not json");
    try std.testing.expect(std.mem.startsWith(u8, bad, "HTTP/1.1 400 Bad Request\r\n"));

    const deleted = try request(a, io, addr, "DELETE", "/notes/1", "");
    try std.testing.expect(std.mem.startsWith(u8, deleted, "HTTP/1.1 204 No Content\r\n"));

    const missing = try request(a, io, addr, "GET", "/notes/1", "");
    try std.testing.expect(std.mem.startsWith(u8, missing, "HTTP/1.1 404 Not Found\r\n"));

    const stats = try request(a, io, addr, "GET", "/stats", "");
    thread.join();
    try std.testing.expect(std.mem.find(u8, bodyOf(stats), "requests 7\n") != null);
    try std.testing.expect(std.mem.find(u8, bodyOf(stats), "notes 0\n") != null);
    try std.testing.expectEqual(0, server.errors.load(.monotonic));
}

fn postMany(gpa: Allocator, io: Io, addr: Io.net.IpAddress, how_many: usize) void {
    for (0..how_many) |_| {
        const response = request(gpa, io, addr, "POST", "/notes", "{\"title\": \"concurrent\"}") catch |err| std.debug.panic("request failed: {t}", .{err});
        defer gpa.free(response);
        if (!std.mem.startsWith(u8, response, "HTTP/1.1 201")) std.debug.panic("unexpected: {s}", .{response});
    }
}

test "many clients at once" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var store = Store.init(gpa);
    defer store.deinit();
    var server = try Server.init(gpa, io, &store, 0);
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, serveInThread, .{ &server, 4 * 10 });
    defer thread.join();

    // Four client threads, ten requests each, all creating notes concurrently.
    var clients: [4]std.Thread = undefined;
    for (&clients) |*c| c.* = try std.Thread.spawn(.{}, postMany, .{ gpa, io, server.address(), 10 });
    for (clients) |c| c.join();
    try std.testing.expectEqual(40, try store.count(io));
}
```

## 8.10 The program

### Why
`main` runs the three demos, parses two options, seeds the store with a couple of notes so the first `GET` has something to show, prints the `curl` commands to try, and serves. The store and server are local variables on `main`'s stack, shared with every connection task through pointers; they outlive the tasks because `serve` doesn't return until the group has been awaited.

### How
- **`--connections N`** gives the run a definite end, so the lecture's own runs (and `build.bash`) terminate on their own; `0`, the default, serves until Ctrl-C.
- **`{f}` on an `IpAddress`** prints `127.0.0.1:8080`: the address type has a `format` method, as the `Duration` did. The curly braces in the JSON examples are doubled (`{{"title"…}}`) because the text is a format string.
- **Arguments are parsed into `init.arena`**, the arena that lives for the whole program, as in lecture 6.

### Code
`src/main.zig`, part 4 of 4:
```zig
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
```

## 8.11 Running it

### How
From `lecture_8/`, in one terminal:
```bash
zig build run -- --port 8089 --connections 12
```
```text
Threads and shared memory (1000000 increments each, two threads):
    plain u64:   1050214 (expected 2000000; the race loses increments)
    atomic u64:  2000000
    with mutex:  2000000
    this machine has 24 logical CPUs
Tasks and futures:
    four tasks summed 100 million terms: 199999997
A queue between tasks:
    1 to 1000 through an 8-slot queue, 2 producers, 3 consumers: 500500 (expected 500500)

Notes API listening on http://127.0.0.1:8089  (serving 12 connections; 0 means until Ctrl-C)
    curl http://127.0.0.1:8089/notes
    curl -X POST http://127.0.0.1:8089/notes -d '{"title": "new note"}'
    curl -X PUT  http://127.0.0.1:8089/notes/1 -d '{"title": "read lecture 8", "done": true}'
    curl -X DELETE http://127.0.0.1:8089/notes/2
    curl http://127.0.0.1:8089/stats
```
The racy counter came out as 1050214, 1196057 and 1017822 in three runs: wrong every time, and differently wrong. In another terminal:
```bash
curl http://127.0.0.1:8089/notes
```
```text
[{"id":1,"title":"read lecture 8","done":false},{"id":2,"title":"try the API with curl","done":false}]
```
```bash
curl -i -X POST http://127.0.0.1:8089/notes -d '{"title": "new note"}'
```
```text
HTTP/1.1 201 Created
Content-Type: application/json
Content-Length: 40
Connection: close

{"id":3,"title":"new note","done":false}
```
```bash
curl -X PUT http://127.0.0.1:8089/notes/1 -d '{"title": "read lecture 8", "done": true}'
```
```text
{"id":1,"title":"read lecture 8","done":true}
```
`curl -i -X DELETE …/notes/2` answers `HTTP/1.1 204 No Content`, and `curl -i …/notes/2` afterwards `HTTP/1.1 404 Not Found`; `curl -i -X POST …/notes -d 'oops'` gets `HTTP/1.1 400 Bad Request`. Four clients at once, each a background process:
```bash
for i in 1 2 3 4; do curl -s -X POST http://127.0.0.1:8089/notes -d "{\"title\": \"parallel $i\"}" & done; wait
```
```text
{"id":4,"title":"parallel 4","done":false}{"id":5,"title":"parallel 2","done":false}{"id":6,"title":"parallel 3","done":false}{"id":7,"title":"parallel 1","done":false}
```
The four requests arrived in whatever order the kernel scheduled them (id 4 went to "parallel 4", id 7 to "parallel 1") and every one got a distinct id: the writer lock did its job. Then:
```bash
curl http://127.0.0.1:8089/stats
```
```text
requests 12
errors 0
notes 6
uptime 1.338s
```
That was the twelfth connection, so the server returns and the first terminal finishes with:
```text
served 12 requests, 0 failed; 6 notes remain
```
The tests:
```bash
zig build test --summary all
```
```text
Build Summary: 3/3 steps succeeded; 5/5 tests passed
test success
+- run test 5 pass (5 total) 13ms MaxRSS:7M
   +- compile test debug native success 257ms MaxRSS:163M
```
Two of the five run a server and talk to it over real sockets; the whole suite takes 13 milliseconds.

Experiments. Run the program with `-Doptimize=fast` and watch the racy counter come out as exactly 2000000: the optimizer collapsed each thread's loop into one addition, so there's one race per thread instead of a million. Correct output is not proof of a correct program. Then remove the two lock lines from `Store.create` (and add `_ = io;`, or the compiler rejects the unused parameter) and run `zig build test`: "concurrent writers never collide" crashes on every run with `panic: reached unreachable code` from an assertion inside the hash map, and sometimes a second test crashes or leaks with it. That is what an unprotected shared data structure looks like; a wrong count would have been the lucky outcome. Change `takeDelimiter` back to `takeDelimiterExclusive` in `readRequest` and run the tests to see every POST come back as `400`. Finally, add a `GET /notes?done=true` filter: `std.mem.cutScalar(u8, path, '?')` splits the query off the path, and `list` already returns copies you can filter in the handler.
