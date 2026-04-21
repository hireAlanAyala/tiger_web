//! Zig sidecar benchmark — measures pure IPC overhead.
//!
//! Standalone binary that speaks the SHM CALL/RESULT protocol as a
//! separate process. No JS, no GC, no JIT, no event loop. Measures
//! the protocol + SHM overhead in isolation.
//!
//! Usage: zig-sidecar <shm-name> <socket-path>
//!
//! The difference between native in-process (70K) and this sidecar
//! tells us the exact IPC cost. The difference between this and the
//! TS sidecar (52K) tells us the exact Node.js runtime cost.

const std = @import("std");
const posix = std.posix;
const assert = std.debug.assert;
const Crc32 = std.hash.crc.Crc32;
const protocol = @import("protocol.zig");
const message = @import("message.zig");

const REGION_HEADER_SIZE = 64;
const SLOT_HEADER_SIZE = 64;

const SlotState = enum(u8) {
    free = 0,
    call_written = 1,
    result_written = 2,
};

pub fn main() !void {
    var args = std.process.args();
    _ = args.next(); // skip binary name
    const shm_name = args.next() orelse {
        std.io.getStdErr().writer().print("Usage: zig-sidecar <shm-name> <socket-path>\n", .{}) catch {};
        std.process.exit(1);
    };
    const socket_path = args.next() orelse {
        std.io.getStdErr().writer().print("Usage: zig-sidecar <shm-name> <socket-path>\n", .{}) catch {};
        std.process.exit(1);
    };

    const stdout = std.io.getStdOut().writer();

    // --- Map SHM region ---
    var shm_path_buf: [128]u8 = undefined;
    const shm_path_len = std.fmt.count("/{s}", .{shm_name});
    _ = std.fmt.bufPrintZ(&shm_path_buf, "/{s}", .{shm_name}) catch unreachable;
    const shm_path_z: [:0]const u8 = shm_path_buf[0..shm_path_len :0];

    const shm_fd = std.c.shm_open(shm_path_z, @as(c_int, 2), 0o600); // O_RDWR = 2
    if (shm_fd < 0) {
        try stdout.print("error: shm_open({s}) failed\n", .{shm_name});
        std.process.exit(1);
    }

    // Read header to get slot_count and frame_max.
    const header_map = posix.mmap(null, REGION_HEADER_SIZE, posix.PROT.READ | posix.PROT.WRITE, .{ .TYPE = .SHARED }, shm_fd, 0) catch {
        try stdout.print("error: mmap header failed\n", .{});
        std.process.exit(1);
    };
    const header_bytes: [*]const u8 = @ptrCast(header_map);
    const slot_count = std.mem.readInt(u16, header_bytes[4..6], .little);
    const frame_max = std.mem.readInt(u32, header_bytes[8..12], .little);
    const slot_pair_size = SLOT_HEADER_SIZE + frame_max * 2;
    const region_size = REGION_HEADER_SIZE + @as(usize, slot_count) * slot_pair_size;

    // Remap full region.
    _ = posix.munmap(header_map);
    const region_map = posix.mmap(null, region_size, posix.PROT.READ | posix.PROT.WRITE, .{ .TYPE = .SHARED }, shm_fd, 0) catch {
        try stdout.print("error: mmap region failed\n", .{});
        std.process.exit(1);
    };
    const region: [*]u8 = @ptrCast(region_map);

    try stdout.print("[zig-sidecar] mapped {s}: {d} bytes, {d} slots\n", .{ shm_name, region_size, slot_count });

    // --- Connect Unix socket + send READY ---
    const sock_fd = try connect_and_ready(socket_path);
    _ = sock_fd; // keep alive
    try stdout.print("[zig-sidecar] READY sent to {s}\n", .{socket_path});

    // Set sidecar_polling flag.
    const polling_ptr: *u32 = @ptrCast(@alignCast(region + 12));
    @atomicStore(u32, polling_ptr, 1, .release);

    // --- Poll loop ---
    var last_seqs: [32]u32 = .{0} ** 32;
    var calls_processed: u64 = 0;

    try stdout.print("[zig-sidecar] polling...\n", .{});

    while (true) {
        for (0..slot_count) |i| {
            const slot_offset = REGION_HEADER_SIZE + i * slot_pair_size;
            const hdr = region + slot_offset;

            const server_seq_ptr: *const u32 = @ptrCast(@alignCast(hdr));
            const server_seq = @atomicLoad(u32, server_seq_ptr, .acquire);
            if (server_seq <= last_seqs[i]) continue;
            last_seqs[i] = server_seq;

            // Read request.
            const request_len_ptr: *const u32 = @ptrCast(@alignCast(hdr + 8));
            const request_len = request_len_ptr.*;
            if (request_len > frame_max) continue;

            const request_area = hdr + SLOT_HEADER_SIZE;

            // Validate CRC.
            const stored_crc_ptr: *const u32 = @ptrCast(@alignCast(hdr + 16));
            const stored_crc = stored_crc_ptr.*;
            if (stored_crc == 0) continue; // sentinel
            var crc = Crc32.init();
            crc.update(std.mem.asBytes(&request_len));
            crc.update(request_area[0..request_len]);
            if (crc.final() != stored_crc) continue;

            // Parse CALL: [tag][request_id: u32 BE][name_len: u16 BE][name][args]
            const payload = request_area[0..request_len];
            if (payload.len < 7 or payload[0] != @intFromEnum(protocol.CallTag.call)) continue;
            const request_id = std.mem.readInt(u32, payload[1..5], .big);
            const name_len = std.mem.readInt(u16, payload[5..7], .big);
            if (7 + name_len > payload.len) continue;
            const name = payload[7..][0..name_len];

            // Build RESULT.
            const response_area = hdr + SLOT_HEADER_SIZE + frame_max;
            var rpos: usize = 0;

            if (std.mem.eql(u8, name, "handle_render") or std.mem.eql(u8, name, "route_prefetch")) {
                // Build RESULT: [tag][request_id][flag][payload]
                const result_data = build_minimal_result(name, payload[7 + name_len ..]);
                rpos = protocol.build_result(
                    response_area[0..frame_max],
                    request_id,
                    .success,
                    &result_data.data,
                ) orelse continue;
            } else {
                rpos = protocol.build_result(
                    response_area[0..frame_max],
                    request_id,
                    .success,
                    "",
                ) orelse continue;
            }

            // Write response metadata.
            const resp_len: u32 = @intCast(rpos);
            const resp_len_ptr: *u32 = @ptrCast(@alignCast(hdr + 12));
            resp_len_ptr.* = resp_len;

            var resp_crc = Crc32.init();
            resp_crc.update(std.mem.asBytes(&resp_len));
            resp_crc.update(response_area[0..resp_len]);
            const resp_crc_ptr: *u32 = @ptrCast(@alignCast(hdr + 20));
            resp_crc_ptr.* = resp_crc.final();

            // slot_state = result_written
            hdr[24] = @intFromEnum(SlotState.result_written);

            // Bump sidecar_seq.
            const sidecar_seq_ptr: *u32 = @ptrCast(@alignCast(hdr + 4));
            @atomicStore(u32, sidecar_seq_ptr, @atomicLoad(u32, sidecar_seq_ptr, .monotonic) + 1, .release);

            calls_processed += 1;
        }
    }
}

const MinimalResult = struct {
    data: [1024]u8,
    len: usize,
};

fn build_minimal_result(name: []const u8, _: []const u8) MinimalResult {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;

    if (std.mem.eql(u8, name, "handle_render")) {
        // [status_len: u16 BE]["ok"][session_action: u8][write_count: u8][dispatch_count: u8][html]
        std.mem.writeInt(u16, buf[pos..][0..2], 2, .big); pos += 2; // status_len
        buf[pos] = 'o'; pos += 1;
        buf[pos] = 'k'; pos += 1;
        buf[pos] = 0; pos += 1; // session_action = none
        buf[pos] = 0; pos += 1; // write_count = 0
        buf[pos] = 0; pos += 1; // dispatch_count = 0
        const html = "<div>zig-sidecar</div>";
        @memcpy(buf[pos..][0..html.len], html);
        pos += html.len;
    } else if (std.mem.eql(u8, name, "route_prefetch")) {
        // Minimal route result: [operation: u8][id: 16 bytes][body_len: u16 BE][query_count: u8][key_count: u8]
        buf[pos] = 1; pos += 1; // operation value (any non-zero)
        @memset(buf[pos..][0..16], 0); pos += 16; // id = zero
        std.mem.writeInt(u16, buf[pos..][0..2], 2, .big); pos += 2; // body_len
        buf[pos] = '{'; pos += 1;
        buf[pos] = '}'; pos += 1;
        buf[pos] = 0; pos += 1; // query_count = 0
        buf[pos] = 0; pos += 1; // key_count = 0
    }

    return .{ .data = buf, .len = pos };
}

fn connect_and_ready(path: []const u8) !posix.fd_t {
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);

    var addr: posix.sockaddr.un = .{ .path = undefined };
    @memcpy(addr.path[0..path.len], path);
    addr.path[path.len] = 0;
    try posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

    // Build READY frame: [len: u32 BE][crc: u32 LE][tag=0x20][version: u16 BE]
    var ready_payload: [3]u8 = undefined;
    ready_payload[0] = @intFromEnum(protocol.CallTag.ready);
    std.mem.writeInt(u16, ready_payload[1..3], protocol.protocol_version, .big);

    var wire_buf: [11]u8 = undefined;
    std.mem.writeInt(u32, wire_buf[0..4], 3, .big); // payload len
    var crc = Crc32.init();
    var len_le: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_le, 3, .big); // CRC convention: BE len bytes
    crc.update(&len_le);
    crc.update(&ready_payload);
    std.mem.writeInt(u32, wire_buf[4..8], crc.final(), .little);
    wire_buf[8] = ready_payload[0];
    wire_buf[9] = ready_payload[1];
    wire_buf[10] = ready_payload[2];

    _ = try posix.write(fd, &wire_buf);
    return fd;
}
