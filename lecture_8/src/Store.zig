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
