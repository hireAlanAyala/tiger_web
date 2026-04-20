//! Write-ahead log — SQL-write WAL with worker dispatch support.
//!
//! Records committed SQL writes and worker dispatch entries. Each entry
//! contains operation, timestamp, SQL writes, and optional worker
//! dispatches. Replay re-executes the SQL — no handlers, no sidecar needed.
//! Worker dispatches rebuild the in-memory pending index on recovery.
//!
//! Entry header: 64 bytes (extern struct, no padding).
//!   [u128 checksum]       Aegis128L over everything after checksum
//!   [u128 parent]         previous entry's checksum (hash chain)
//!   [u64 op]              sequential counter
//!   [i64 timestamp]       wall clock from set_time()
//!   [u64 completes_op]    dispatch op this entry resolves (0 = none)
//!   [u32 entry_len]       total bytes including this header
//!   [u8 operation]        Operation enum value
//!   [u8 write_count]      number of SQL write statements
//!   [u8 dispatch_count]   number of worker dispatch entries
//!   [u8 entry_flags]      0=normal, 1=completion, 2=dead_dispatch
//!
//! Body: variable-size, two sections in order.
//!   [writes...]           write_count × { u16 sql_len, sql, u8 param_count, params }
//!   [dispatches...]       dispatch_count × { u8 name_len, name, u16 args_len, args }
//!
//! Design decisions:
//!
//! **SQL writes, not handler inputs.** The original WAL stored Messages
//! (operation + id + typed body). Replay re-executed handlers. This
//! required the sidecar to serialize typed bodies — bringing per-type
//! serde back into the protocol. SQL-write WAL eliminates the body
//! format question: replay re-executes SQL, no handlers needed.
//!
//! **Dual role: diagnostic log + worker dispatch queue.** The WAL
//! records SQL writes for investigation/replay (diagnostic) AND tracks
//! worker dispatch/completion/dead entries (operational). SQLite is the
//! authority for data; the WAL is the authority for dispatch lifecycle.
//!
//! **No fsync — dispatch is best-effort.** The kernel flushes on its
//! own schedule. If the process crashes after SQLite commits but before
//! the WAL entry reaches disk, the dispatch is lost. The SQL writes
//! survive (SQLite fsyncs), but no worker runs. The application
//! recovers orphans via schema-level checks (e.g., orders stuck in
//! "processing"). See docs/internal/decision-wal-dispatch-crash.md.
//!
//! **Why not input replay?** TigerBeetle stores inputs because replay
//! IS the replication protocol. We don't replicate. SQLite handles
//! crash recovery. Our WAL is for diagnostics and dispatch tracking.
//!
//! **Append ordering:** DB first, then WAL. A missing entry is obvious
//! and safe (detectable gap). A phantom entry is silent and dangerous
//! (WAL lies).

const std = @import("std");
const assert = std.debug.assert;
const cs = @import("checksum.zig");
const pd = @import("pending_dispatch.zig");
const constants = @import("constants.zig");

const log = std.log.scoped(.wal);

/// Maximum WAL entry size: header + worst-case SQL writes.
/// Exported so the server can size its scratch buffer.
/// The actual max depends on protocol constants — but since the WAL
/// is in the framework (no protocol dependency), we use a fixed bound
/// and the server asserts it's sufficient at comptime.
pub const entry_max = 256 * 1024;

/// Entry flags — distinguishes normal mutations from completion/dead-dispatch entries.
pub const EntryFlags = enum(u8) {
    normal = 0, // regular mutation (writes only, or writes + dispatches)
    completion = 1, // completion entry (references dispatch via completes_op)
    dead_dispatch = 2, // deadline expiry (references dispatch via completes_op)
};

/// WAL entry header. Extern struct, largest-alignment-first to avoid padding.
/// 64 bytes: all fields packed, no tail padding.
pub const EntryHeader = extern struct {
    checksum: u128, // 16 bytes, @0, align 16
    parent: u128, // 16 bytes, @16
    op: u64, // 8 bytes, @32
    timestamp: i64, // 8 bytes, @40
    completes_op: u64, // 8 bytes, @48 — dispatch op this entry resolves (0 = none)
    entry_len: u32, // 4 bytes, @56
    operation: u8, // 1 byte, @60
    write_count: u8, // 1 byte, @61
    dispatch_count: u8 = 0, // 1 byte, @62 — number of worker dispatch entries
    entry_flags: EntryFlags = .normal, // 1 byte, @63

    comptime {
        // Fields: 16+16+8+8+8+4+1+1+1+1 = 64 bytes, no tail padding.
        assert(@sizeOf(EntryHeader) == 64);
    }

    pub fn valid_checksum(self: *const EntryHeader, full_entry: []const u8) bool {
        assert(full_entry.len >= @sizeOf(EntryHeader));
        assert(full_entry.len == self.entry_len);
        // Checksum covers everything after the checksum field.
        const checksum_offset = @offsetOf(EntryHeader, "checksum") + @sizeOf(u128);
        const checksummed = full_entry[checksum_offset..];
        return self.checksum == cs.checksum(checksummed);
    }
};

pub fn WalType(comptime Operation: type) type {
    return struct {
        const Wal = @This();
        fd: std.posix.fd_t,
        op: u64,
        parent: u128,
        disabled: bool,

        // Root entry — deterministic sentinel at op 0.
        // Operation .root, zero writes. Checksum anchors the chain.
        pub fn root_entry() EntryHeader {
            var hdr = EntryHeader{
                .entry_len = @sizeOf(EntryHeader),
                .checksum = 0,
                .parent = 0,
                .op = 0,
                .timestamp = 0,
                .completes_op = 0,
                .operation = @intFromEnum(@as(Operation, .root)),
                .write_count = 0,
            };
            const checksum_offset = @offsetOf(EntryHeader, "checksum") + @sizeOf(u128);
            const bytes = std.mem.asBytes(&hdr);
            hdr.checksum = cs.checksum(bytes[checksum_offset..]);
            return hdr;
        }

        pub const PendingIndex = pd.PendingIndexType(constants.max_in_flight_workers);

        /// Static recovery buffer — avoids heap allocation during init.
        /// Sized to entry_max (256KB). Used only during recovery scan.
        var recovery_buffer: [entry_max]u8 align(@alignOf(EntryHeader)) = undefined;

        /// Recovery state returned by scan_entries.
        const RecoveryResult = struct {
            op: u64,
            parent: u128,
        };

        /// Initialize a WAL from the given path. If `pending` is non-null,
        /// the recovery scan populates the pending dispatch index.
        pub fn init(path: [:0]const u8, pending: ?*PendingIndex) Wal {
            const fd = std.posix.open(
                path,
                .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
                0o644,
            ) catch |err| {
                log.err("open failed: {}", .{err});
                @panic("wal: failed to open file");
            };

            const stat = std.posix.fstat(fd) catch |err| {
                log.err("fstat failed: {}", .{err});
                @panic("wal: failed to stat file");
            };
            const file_size: u64 = @intCast(stat.size);

            const result = if (file_size > 0)
                recover(path, fd, file_size, pending)
            else
                create_new(fd);

            var wal = Wal{
                .fd = fd,
                .op = result.op,
                .parent = result.parent,
                .disabled = false,
            };
            wal.invariants();
            return wal;
        }

        /// Create a new WAL file — write the root entry.
        fn create_new(fd: std.posix.fd_t) RecoveryResult {
            const root_hdr = root_entry();
            if (!write_all(fd, std.mem.asBytes(&root_hdr))) {
                log.err("root write failed", .{});
                @panic("wal: failed to write root entry");
            }
            log.info("created new WAL", .{});
            return .{ .op = 1, .parent = root_hdr.checksum };
        }

        /// Recover an existing WAL — verify root, scan entries.
        fn recover(
            path: [:0]const u8,
            fd: std.posix.fd_t,
            file_size: u64,
            pending: ?*PendingIndex,
        ) RecoveryResult {
            const read_fd = std.posix.open(
                path,
                .{ .ACCMODE = .RDONLY },
                0,
            ) catch |err| {
                log.err("open for recovery failed: {}", .{err});
                @panic("wal: failed to open file for recovery");
            };
            defer std.posix.close(read_fd);

            if (!verify_root(read_fd)) {
                log.warn("stale WAL — root invalid, deleting", .{});
                std.posix.close(fd);
                std.fs.cwd().deleteFile(path) catch {};
                return init(path, pending).to_result();
            }

            return scan_entries(read_fd, fd, file_size, pending);
        }

        /// Verify the root entry matches the expected deterministic sentinel.
        fn verify_root(read_fd: std.posix.fd_t) bool {
            var root_buf: [@sizeOf(EntryHeader)]u8 align(@alignOf(EntryHeader)) = undefined;
            const root_n = std.posix.pread(read_fd, &root_buf, 0) catch 0;
            if (root_n < @sizeOf(EntryHeader)) return false;

            const root_hdr: *const EntryHeader = @ptrCast(@alignCast(&root_buf));
            const expected = root_entry();
            return root_hdr.checksum == expected.checksum;
        }

        /// Forward-scan all entries, verify checksums + parent chain,
        /// rebuild pending dispatch index, truncate corrupt tail.
        fn scan_entries(
            read_fd: std.posix.fd_t,
            write_fd: std.posix.fd_t,
            file_size: u64,
            pending: ?*PendingIndex,
        ) RecoveryResult {
            const expected_root = root_entry();
            var scan_offset: u64 = 0;
            var last_valid_checksum: u128 = expected_root.checksum;
            var last_valid_op: u64 = 0;
            var last_valid_end: u64 = @sizeOf(EntryHeader);
            var entries_read: u64 = 0;
            const entry_buf = &recovery_buffer;

            while (scan_offset < file_size) {
                const n = std.posix.pread(read_fd, entry_buf[0..@sizeOf(EntryHeader)], scan_offset) catch break;
                if (n < @sizeOf(EntryHeader)) break;

                const hdr: *const EntryHeader = @ptrCast(@alignCast(entry_buf.ptr));
                if (hdr.entry_len < @sizeOf(EntryHeader) or hdr.entry_len > entry_max) break;
                if (scan_offset + hdr.entry_len > file_size) break;

                const full_n = std.posix.pread(read_fd, entry_buf[0..hdr.entry_len], scan_offset) catch break;
                if (full_n != hdr.entry_len) break;

                if (hdr.parent != last_valid_checksum and entries_read > 0) break;

                const checksum_offset = @offsetOf(EntryHeader, "checksum") + @sizeOf(u128);
                const computed = cs.checksum(entry_buf[checksum_offset..hdr.entry_len]);
                if (computed != hdr.checksum) break;

                if (pending) |idx| {
                    recover_dispatches(idx, hdr, entry_buf[0..hdr.entry_len]);
                }

                last_valid_checksum = hdr.checksum;
                last_valid_op = hdr.op;
                entries_read += 1;
                last_valid_end = scan_offset + hdr.entry_len;
                scan_offset += hdr.entry_len;
            }

            if (last_valid_end < file_size) {
                log.warn("truncating {d} corrupt bytes at tail", .{file_size - last_valid_end});
                std.posix.ftruncate(write_fd, last_valid_end) catch {};
            }
            log.info("recovered: entries={d} next_op={d}", .{ entries_read, last_valid_op + 1 });

            return .{ .op = last_valid_op + 1, .parent = last_valid_checksum };
        }

        /// Convert a Wal to RecoveryResult (for recursive init after delete).
        fn to_result(wal: Wal) RecoveryResult {
            return .{ .op = wal.op, .parent = wal.parent };
        }

        /// Parse dispatch/completion/dead entries and update the pending index.
        /// Called during init() recovery scan for each valid entry.
        fn recover_dispatches(
            idx: *PendingIndex,
            hdr: *const EntryHeader,
            entry_data: []const u8,
        ) void {
            // Switch on raw u8 — entry_flags is read from disk (untrusted).
            // Exhaustive enum switch would be UB on corrupt values outside 0/1/2.
            switch (@intFromEnum(hdr.entry_flags)) {
                @intFromEnum(EntryFlags.normal) => {
                    if (hdr.dispatch_count == 0) return;
                    // Skip past the writes section to reach dispatches.
                    const body = entry_data[@sizeOf(EntryHeader)..hdr.entry_len];
                    const dispatch_start = skip_writes_section(body, hdr.write_count) orelse return;
                    // Parse each dispatch entry and add to the index.
                    var pos = dispatch_start;
                    for (0..hdr.dispatch_count) |_| {
                        const parsed = pd.parse_one_dispatch(body, &pos) orelse break;
                        var dispatch = pd.PendingDispatch{
                            .op = hdr.op,
                            .operation = hdr.operation,
                            .name = undefined,
                            .name_len = @intCast(parsed.name.len),
                            .args = undefined,
                            .args_len = @intCast(parsed.args.len),
                            .dispatched_at = hdr.timestamp,
                            .state = .pending,
                        };
                        @memcpy(dispatch.name[0..parsed.name.len], parsed.name);
                        @memcpy(dispatch.args[0..parsed.args.len], parsed.args);
                        if (!idx.add(dispatch)) {
                            log.warn("recovery: skipping dispatch op={d} (full or duplicate)", .{hdr.op});
                            break;
                        }
                    }
                },
                @intFromEnum(EntryFlags.completion) => {
                    // Validate — recovery reads from disk (untrusted).
                    if (hdr.completes_op == 0) {
                        log.warn("corrupt completion entry at op={d}: completes_op=0, skipping", .{hdr.op});
                        return;
                    }
                    idx.resolve(hdr.completes_op, .completed);
                },
                @intFromEnum(EntryFlags.dead_dispatch) => {
                    if (hdr.completes_op == 0) {
                        log.warn("corrupt dead_dispatch entry at op={d}: completes_op=0, skipping", .{hdr.op});
                        return;
                    }
                    idx.resolve(hdr.completes_op, .dead);
                },
                else => {
                    log.warn("unknown entry_flags={d} at op={d}, skipping", .{ @intFromEnum(hdr.entry_flags), hdr.op });
                    return;
                },
            }
        }

        /// Skip past write_count SQL write entries in the body, returning the
        /// offset where the dispatch section begins. Returns null on malformed data.
        pub fn skip_writes_section(body: []const u8, write_count: u8) ?usize {
            var pos: usize = 0;
            for (0..write_count) |_| {
                // sql: [u16 BE sql_len][sql_bytes]
                if (pos + 2 > body.len) return null;
                const sql_len = std.mem.readInt(u16, body[pos..][0..2], .big);
                pos += 2 + sql_len;
                if (pos >= body.len) return null;

                // params: [u8 param_count][params...]
                const param_count = body[pos];
                pos += 1;
                for (0..param_count) |_| {
                    if (pos >= body.len) return null;
                    const tag = body[pos];
                    pos += 1;
                    switch (tag) {
                        0x01, 0x02 => pos += 8, // integer, float
                        0x03, 0x04 => { // text, blob
                            if (pos + 2 > body.len) return null;
                            const vlen = std.mem.readInt(u16, body[pos..][0..2], .big);
                            pos += 2 + vlen;
                        },
                        0x05 => {}, // null
                        else => return null,
                    }
                }
            }
            return pos;
        }

        pub fn deinit(wal: *Wal) void {
            std.posix.close(wal.fd);
            wal.* = undefined;
        }

        /// Append a mutation entry to the WAL (writes + optional dispatches).
        pub fn append_writes(
            wal: *Wal,
            operation: Operation,
            timestamp: i64,
            writes_data: []const u8,
            write_count: u8,
            dispatches_data: []const u8,
            dispatch_count: u8,
            buf: []u8,
        ) void {
            assert(operation.is_mutation());
            var hdr = EntryHeader{
                .entry_len = undefined, // set by append_entry
                .checksum = 0,
                .parent = wal.parent,
                .op = wal.op,
                .timestamp = timestamp,
                .completes_op = 0,
                .operation = @intFromEnum(operation),
                .write_count = write_count,
                .dispatch_count = dispatch_count,
                .entry_flags = .normal,
            };
            wal.append_entry(&hdr, writes_data, dispatches_data, buf);
        }

        /// Append a completion entry — resolves a dispatch op with handler writes.
        pub fn append_completion(
            wal: *Wal,
            operation: Operation,
            timestamp: i64,
            writes_data: []const u8,
            write_count: u8,
            completes_op: u64,
            buf: []u8,
        ) void {
            assert(operation.is_mutation());
            assert(completes_op > 0);
            assert(completes_op < wal.op);
            var hdr = EntryHeader{
                .entry_len = undefined,
                .checksum = 0,
                .parent = wal.parent,
                .op = wal.op,
                .timestamp = timestamp,
                .completes_op = completes_op,
                .operation = @intFromEnum(operation),
                .write_count = write_count,
                .dispatch_count = 0,
                .entry_flags = .completion,
            };
            wal.append_entry(&hdr, writes_data, "", buf);
        }

        /// Append a dead-dispatch entry — marks a dispatch resolved-dead (deadline).
        pub fn append_dead_dispatch(
            wal: *Wal,
            operation: Operation,
            timestamp: i64,
            completes_op: u64,
            buf: []u8,
        ) void {
            assert(completes_op > 0);
            assert(completes_op < wal.op);
            var hdr = EntryHeader{
                .entry_len = undefined,
                .checksum = 0,
                .parent = wal.parent,
                .op = wal.op,
                .timestamp = timestamp,
                .completes_op = completes_op,
                .operation = @intFromEnum(operation),
                .write_count = 0,
                .dispatch_count = 0,
                .entry_flags = .dead_dispatch,
            };
            wal.append_entry(&hdr, "", "", buf);
        }

        /// Shared entry assembly: header + body sections → checksum → write.
        fn append_entry(
            wal: *Wal,
            hdr: *EntryHeader,
            section_a: []const u8,
            section_b: []const u8,
            buf: []u8,
        ) void {
            assert(wal.op > 0);
            assert(!wal.disabled);
            defer wal.invariants();

            const body_len = section_a.len + section_b.len;
            const entry_len: u32 = @intCast(@sizeOf(EntryHeader) + body_len);
            assert(entry_len <= buf.len);
            hdr.entry_len = entry_len;

            // Assemble entry in buf: header + sections.
            @memcpy(buf[0..@sizeOf(EntryHeader)], std.mem.asBytes(hdr));
            if (section_a.len > 0) {
                @memcpy(buf[@sizeOf(EntryHeader)..][0..section_a.len], section_a);
            }
            if (section_b.len > 0) {
                @memcpy(buf[@sizeOf(EntryHeader) + section_a.len ..][0..section_b.len], section_b);
            }

            // Compute checksum over everything after the checksum field.
            const checksum_offset = @offsetOf(EntryHeader, "checksum") + @sizeOf(u128);
            hdr.checksum = cs.checksum(buf[checksum_offset..entry_len]);

            // Write checksum back into buf.
            @memcpy(buf[@offsetOf(EntryHeader, "checksum")..][0..@sizeOf(u128)], std.mem.asBytes(&hdr.checksum));

            // Write entry to file.
            if (!write_all(wal.fd, buf[0..entry_len])) {
                log.warn("write failed, disabling WAL", .{});
                wal.disabled = true;
                return;
            }

            wal.parent = hdr.checksum;
            wal.op += 1;
        }

        pub fn invariants(wal: *const Wal) void {
            assert(wal.fd > 0);
            assert(wal.op > 0);
            if (wal.disabled) return;
            assert(wal.parent != 0);
        }

        fn write_all(fd: std.posix.fd_t, bytes: []const u8) bool {
            var written: usize = 0;
            while (written < bytes.len) {
                const n = std.posix.write(fd, bytes[written..]) catch return false;
                if (n == 0) return false;
                written += n;
            }
            return true;
        }
    };
}
