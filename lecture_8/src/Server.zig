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
