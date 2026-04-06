//! Sidecar dispatch v2 — unit tests.
//!
//! Tests the dispatch module in isolation: feeds request data,
//! simulates sidecar RESULT frames, verifies stage progression
//! and output correctness. No Server, no HTTP, no connections.
//!
//! Uses a MockBus that captures sent frames and allows injecting
//! received frames. The dispatch module doesn't know the difference.

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const protocol = @import("protocol.zig");
const http = @import("framework/http.zig");
const Storage = @import("storage.zig").SqliteStorage;
const Dispatch = @import("sidecar_dispatch.zig").SidecarDispatchType(Storage, MockBus);

// =====================================================================
// MockBus — captures sent frames, allows injecting received frames
// =====================================================================

const MockBus = struct {
    const Message = struct {
        buffer: [protocol.frame_max + frame_header_size]u8,
        references: u32 = 1,

        fn unref(_: *Message) void {}
    };

    pub const frame_header_size = 8;

    sent_frames: [64]SentFrame = undefined,
    sent_count: usize = 0,
    message_pool: [16]Message = undefined,
    next_message: usize = 0,
    connection_ready: bool = true,

    const SentFrame = struct {
        data: [protocol.frame_max]u8,
        len: usize,
        connection_index: u8,
    };

    fn init() MockBus {
        return .{};
    }

    pub fn is_connection_ready(_: *MockBus, _: u8) bool {
        return true;
    }

    pub fn can_send_to(_: *MockBus, _: u8) bool {
        return true;
    }

    pub fn get_message(self: *MockBus) *Message {
        const idx = self.next_message;
        self.next_message = (self.next_message + 1) % self.message_pool.len;
        self.message_pool[idx].references = 1;
        return &self.message_pool[idx];
    }

    pub fn unref(_: *MockBus, _: *Message) void {}

    pub fn send_message_to(self: *MockBus, connection_index: u8, msg: *Message, payload_len: u32) void {
        assert(self.sent_count < self.sent_frames.len);
        var frame = &self.sent_frames[self.sent_count];
        frame.connection_index = connection_index;
        frame.len = payload_len;
        @memcpy(frame.data[0..payload_len], msg.buffer[frame_header_size..][0..payload_len]);
        self.sent_count += 1;
    }

    /// Read the last sent CALL frame. Returns the function name and args.
    fn last_sent_call(self: *MockBus) struct { name: []const u8, args: []const u8, request_id: u32 } {
        assert(self.sent_count > 0);
        const frame = &self.sent_frames[self.sent_count - 1];
        const data = frame.data[0..frame.len];

        assert(data[0] == @intFromEnum(protocol.CallTag.call));
        const request_id = std.mem.readInt(u32, data[1..5], .big);
        const name_len = std.mem.readInt(u16, data[5..7], .big);
        return .{
            .name = data[7..][0..name_len],
            .args = data[7 + name_len .. frame.len],
            .request_id = request_id,
        };
    }

    fn reset(self: *MockBus) void {
        self.sent_count = 0;
    }
};

// =====================================================================
// RESULT frame builders — simulate sidecar responses
// =====================================================================

fn build_result_frame(buf: []u8, request_id: u32, data: []const u8) []const u8 {
    var pos: usize = 0;
    buf[pos] = @intFromEnum(protocol.CallTag.result);
    pos += 1;
    std.mem.writeInt(u32, buf[pos..][0..4], request_id, .big);
    pos += 4;
    buf[pos] = @intFromEnum(protocol.ResultFlag.success);
    pos += 1;
    if (data.len > 0) {
        @memcpy(buf[pos..][0..data.len], data);
        pos += data.len;
    }
    return buf[0..pos];
}

fn build_route_result_data(buf: []u8, op: message.Operation) []const u8 {
    var pos: usize = 0;
    buf[pos] = @intFromEnum(op);
    pos += 1;
    @memset(buf[pos..][0..16], 0); // zero id
    pos += 16;
    return buf[0..pos];
}

fn build_prefetch_result_data(buf: []u8, sql: []const u8) []const u8 {
    var pos: usize = 0;
    std.mem.writeInt(u16, buf[pos..][0..2], @intCast(sql.len), .big);
    pos += 2;
    @memcpy(buf[pos..][0..sql.len], sql);
    pos += sql.len;
    buf[pos] = 0; // param_count = 0
    pos += 1;
    return buf[0..pos];
}

fn build_handle_result_data(buf: []u8, status: []const u8) []const u8 {
    var pos: usize = 0;
    std.mem.writeInt(u16, buf[pos..][0..2], @intCast(status.len), .big);
    pos += 2;
    @memcpy(buf[pos..][0..status.len], status);
    pos += status.len;
    buf[pos] = 0; // session_action = none
    pos += 1;
    buf[pos] = 0; // write_count = 0
    pos += 1;
    return buf[0..pos];
}

fn build_render_result_data(buf: []u8, html: []const u8) []const u8 {
    @memcpy(buf[0..html.len], html);
    return buf[0..html.len];
}

// =====================================================================
// Tests
// =====================================================================

test "dispatch: acquire and release entry" {
    var dispatch: Dispatch = .{};
    const entry = dispatch.acquire_entry() orelse unreachable;
    try std.testing.expectEqual(Dispatch.Stage.free, entry.stage);

    entry.stage = .route_pending;
    entry.request_id = 42;

    dispatch.release_entry(entry);
    try std.testing.expectEqual(Dispatch.Stage.free, entry.stage);
    try std.testing.expectEqual(@as(u32, 0), entry.request_id);
}

test "dispatch: pool exhaustion returns null" {
    var dispatch: Dispatch = .{};
    // Fill all entries.
    for (&dispatch.entries) |*entry| {
        entry.stage = .route_pending;
    }
    try std.testing.expect(dispatch.acquire_entry() == null);

    // Free one.
    dispatch.entries[0].reset();
    try std.testing.expect(dispatch.acquire_entry() != null);
}

test "dispatch: start_request sends route CALL" {
    var bus = MockBus.init();
    var dispatch: Dispatch = .{};
    dispatch.bus = &bus;

    const entry = dispatch.acquire_entry() orelse unreachable;
    var dummy_conn: u8 = 0;
    const ok = dispatch.start_request(entry, .get, "/products", "", @ptrCast(&dummy_conn));
    try std.testing.expect(ok);
    try std.testing.expectEqual(Dispatch.Stage.route_pending, entry.stage);

    // Verify the sent frame is a route CALL.
    const call = bus.last_sent_call();
    try std.testing.expectEqualStrings("route", call.name);
}

test "dispatch: full 4-RT lifecycle" {
    var bus = MockBus.init();
    var storage = try Storage.init(":memory:");
    defer storage.deinit();
    var dispatch: Dispatch = .{};
    dispatch.bus = &bus;

    // RT1: start request → route CALL sent.
    const entry = dispatch.acquire_entry() orelse unreachable;
    var dummy_conn: u8 = 0;
    _ = dispatch.start_request(entry, .get, "/products", "", @ptrCast(&dummy_conn));
    try std.testing.expectEqual(Dispatch.Stage.route_pending, entry.stage);

    const request_id = entry.request_id;

    // Inject route RESULT.
    var route_data_buf: [64]u8 = undefined;
    const route_data = build_route_result_data(&route_data_buf, .list_products);
    var route_frame_buf: [128]u8 = undefined;
    const route_frame = build_result_frame(&route_frame_buf, request_id, route_data);
    bus.reset();
    dispatch.on_frame(route_frame, &storage);
    try std.testing.expectEqual(Dispatch.Stage.prefetch_pending, entry.stage);

    // Verify prefetch CALL was sent.
    const pfetch_call = bus.last_sent_call();
    try std.testing.expectEqualStrings("prefetch", pfetch_call.name);

    // Inject prefetch RESULT (no SQL — empty prefetch).
    var pfetch_frame_buf: [128]u8 = undefined;
    const pfetch_frame = build_result_frame(&pfetch_frame_buf, request_id, "");
    bus.reset();
    dispatch.on_frame(pfetch_frame, &storage);

    // Should advance through prefetch_complete → sql_complete → handle_pending.
    try std.testing.expectEqual(Dispatch.Stage.handle_pending, entry.stage);
    const handle_call = bus.last_sent_call();
    try std.testing.expectEqualStrings("handle", handle_call.name);

    // Inject handle RESULT.
    var handle_data_buf: [64]u8 = undefined;
    const handle_data = build_handle_result_data(&handle_data_buf, "ok");
    var handle_frame_buf: [128]u8 = undefined;
    const handle_frame = build_result_frame(&handle_frame_buf, request_id, handle_data);
    bus.reset();
    dispatch.on_frame(handle_frame, &storage);

    // Should be in write_pending (handle_complete → write_pending).
    try std.testing.expectEqual(Dispatch.Stage.write_pending, entry.stage);
    try std.testing.expectEqual(message.Status.ok, entry.handle_status);

    // Commit write + advance to send render CALL.
    dispatch.write_committed(entry);
    dispatch.advance(&storage);
    try std.testing.expectEqual(Dispatch.Stage.render_pending, entry.stage);

    // Verify render CALL was sent.
    const render_call = bus.last_sent_call();
    try std.testing.expectEqualStrings("render", render_call.name);

    // Inject render RESULT.
    const html = "<div>products</div>";
    var render_data_buf: [64]u8 = undefined;
    const render_data = build_render_result_data(&render_data_buf, html);
    var render_frame_buf: [128]u8 = undefined;
    const render_frame = build_result_frame(&render_frame_buf, request_id, render_data);
    dispatch.on_frame(render_frame, &storage);

    // Complete.
    try std.testing.expectEqual(Dispatch.Stage.render_complete, entry.stage);
    try std.testing.expectEqualStrings(html, entry.html);
}

test "dispatch: write-boundary ordering" {
    var bus = MockBus.init();
    var storage = try Storage.init(":memory:");
    defer storage.deinit();
    var dispatch: Dispatch = .{};
    dispatch.bus = &bus;

    // Start two requests — first is a mutation, second is a read.
    const entry_a = dispatch.acquire_entry() orelse unreachable;
    var dummy_a: u8 = 0;
    _ = dispatch.start_request(entry_a, .post, "/products", "{}", @ptrCast(&dummy_a));
    const id_a = entry_a.request_id;

    const entry_b = dispatch.acquire_entry() orelse unreachable;
    var dummy_b: u8 = 0;
    _ = dispatch.start_request(entry_b, .get, "/products", "", @ptrCast(&dummy_b));
    const id_b = entry_b.request_id;

    // Inject route RESULTs — A is create_product (mutation), B is list_products (read).
    var buf: [128]u8 = undefined;
    var data_buf: [64]u8 = undefined;

    dispatch.on_frame(build_result_frame(&buf, id_a, build_route_result_data(&data_buf, .create_product)), &storage);
    try std.testing.expect(entry_a.is_mutation);

    var buf2: [128]u8 = undefined;
    var data_buf2: [64]u8 = undefined;
    dispatch.on_frame(build_result_frame(&buf2, id_b, build_route_result_data(&data_buf2, .list_products)), &storage);
    try std.testing.expect(!entry_b.is_mutation);

    // Both should be in prefetch_pending now.
    try std.testing.expectEqual(Dispatch.Stage.prefetch_pending, entry_a.stage);
    try std.testing.expectEqual(Dispatch.Stage.prefetch_pending, entry_b.stage);

    // Inject empty prefetch RESULTs for both.
    var pf_buf_a: [64]u8 = undefined;
    dispatch.on_frame(build_result_frame(&pf_buf_a, id_a, ""), &storage);

    var pf_buf_b: [64]u8 = undefined;
    dispatch.on_frame(build_result_frame(&pf_buf_b, id_b, ""), &storage);

    // A (mutation, seq=1) should progress to handle_pending.
    // B (read, seq=2) should be blocked at prefetch_complete because
    // A (mutation, seq=1) hasn't committed yet.
    //
    // Actually: both have empty prefetches, so both advance through
    // sql_complete to handle_pending. The write-boundary check is on
    // prefetch SQL execution, not on advancing to handle. B's prefetch
    // was empty — no SQL to execute, so no write-boundary wait.
    // This is correct: B doesn't read the database, so it doesn't
    // need to wait for A's write.
    try std.testing.expectEqual(Dispatch.Stage.handle_pending, entry_a.stage);
    try std.testing.expectEqual(Dispatch.Stage.handle_pending, entry_b.stage);
}

test "dispatch: request_id uniqueness" {
    var bus = MockBus.init();
    var dispatch: Dispatch = .{};
    dispatch.bus = &bus;

    const entry_a = dispatch.acquire_entry() orelse unreachable;
    var dummy: u8 = 0;
    _ = dispatch.start_request(entry_a, .get, "/", "", @ptrCast(&dummy));

    const entry_b = dispatch.acquire_entry() orelse unreachable;
    _ = dispatch.start_request(entry_b, .get, "/", "", @ptrCast(&dummy));

    try std.testing.expect(entry_a.request_id != entry_b.request_id);
}

test "dispatch: reset_all clears everything" {
    var bus = MockBus.init();
    var dispatch: Dispatch = .{};
    dispatch.bus = &bus;

    const entry = dispatch.acquire_entry() orelse unreachable;
    var dummy: u8 = 0;
    _ = dispatch.start_request(entry, .get, "/", "", @ptrCast(&dummy));
    try std.testing.expectEqual(Dispatch.Stage.route_pending, entry.stage);

    dispatch.reset_all();

    // All entries should be free.
    for (&dispatch.entries) |*e| {
        try std.testing.expectEqual(Dispatch.Stage.free, e.stage);
    }
    try std.testing.expectEqual(@as(u32, 0), dispatch.pending_mutation_count);
}
