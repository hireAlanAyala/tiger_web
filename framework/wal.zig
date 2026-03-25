//! Write-ahead log — SQL-write WAL.
//!
//! Records committed SQL writes (not handler inputs). Each entry contains
//! operation, id, timestamp, and the SQL statements that were executed.
//! Replay re-executes the SQL — no handlers, no sidecar needed.
//!
//! Entry format: variable-size, length-prefixed.
//!   [u32 entry_len]     total bytes including this header
//!   [u128 checksum]     Aegis128L over everything after checksum
//!   [u128 parent]       previous entry's checksum (hash chain)
//!   [u64 op]            sequential counter
//!   [i64 timestamp]     wall clock from set_time()
//!   [u8 operation]      Operation enum value
//!   [u8 write_count]    number of SQL write statements
//!   [writes...]         write_count × { u16 sql_len, sql, u8 param_count, params }
//!
//! No fsync — the kernel flushes on its own schedule. SQLite is the
//! authority; the WAL is a diagnostic notebook.
//!
//! Append ordering: DB first, then WAL. A missing entry is obvious and
//! safe; a phantom entry is silent and dangerous.
//! See the previous version's module doc for the full reasoning.

const std = @import("std");
const assert = std.debug.assert;
const cs = @import("checksum.zig");

const log = std.log.scoped(.wal);

/// Maximum WAL entry size: header + worst-case SQL writes.
/// Exported so the server can size its scratch buffer.
/// The actual max depends on protocol constants — but since the WAL
/// is in the framework (no protocol dependency), we use a fixed bound
/// and the server asserts it's sufficient at comptime.
pub const entry_max = 256 * 1024;

/// WAL entry header. Extern struct, largest-alignment-first to avoid padding.
pub const EntryHeader = extern struct {
    checksum: u128,     // 16 bytes, align 16
    parent: u128,       // 16 bytes
    op: u64,            // 8 bytes
    timestamp: i64,     // 8 bytes
    entry_len: u32,     // 4 bytes
    operation: u8,      // 1 byte
    write_count: u8,    // 1 byte
    reserved: [2]u8 = .{ 0, 0 }, // 2 bytes

    comptime {
        // Fields: 16+16+8+8+4+1+1+2 = 56 bytes + 8 tail padding (u128 align) = 64.
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
                .operation = @intFromEnum(@as(Operation, .root)),
                .write_count = 0,
            };
            const checksum_offset = @offsetOf(EntryHeader, "checksum") + @sizeOf(u128);
            const bytes = std.mem.asBytes(&hdr);
            hdr.checksum = cs.checksum(bytes[checksum_offset..]);
            return hdr;
        }

        pub fn init(path: [:0]const u8) Wal {
            const fd = std.posix.open(
                path,
                .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
                0o644,
            ) catch |err| {
                log.err("open failed: {}", .{err});
                @panic("wal: failed to open file");
            };

            var op: u64 = 0;
            var parent: u128 = 0;

            const stat = std.posix.fstat(fd) catch |err| {
                log.err("fstat failed: {}", .{err});
                @panic("wal: failed to stat file");
            };
            const file_size: u64 = @intCast(stat.size);

            if (file_size > 0) {
                // Recovery: read existing entries.
                const read_fd = std.posix.open(
                    path,
                    .{ .ACCMODE = .RDONLY },
                    0,
                ) catch |err| {
                    log.err("open for recovery failed: {}", .{err});
                    @panic("wal: failed to open file for recovery");
                };
                defer std.posix.close(read_fd);

                // Verify root.
                var root_buf: [@sizeOf(EntryHeader)]u8 align(@alignOf(EntryHeader)) = undefined;
                const root_n = std.posix.pread(read_fd, &root_buf, 0) catch 0;
                if (root_n < @sizeOf(EntryHeader)) {
                    log.warn("stale WAL — too small for root, deleting", .{});
                    std.posix.close(fd);
                    std.fs.cwd().deleteFile(path) catch {};
                    return init(path);
                }

                const root_hdr: *const EntryHeader = @ptrCast(@alignCast(&root_buf));
                const expected = root_entry();
                if (root_hdr.checksum != expected.checksum) {
                    log.warn("stale WAL — root mismatch, deleting", .{});
                    std.posix.close(fd);
                    std.fs.cwd().deleteFile(path) catch {};
                    return init(path);
                }

                // Scan forward to find the last valid entry.
                // Read each full entry and verify checksum + parent chain.
                // Cost: reads the entire WAL file once at startup. Acceptable
                // for a diagnostic WAL — recovery runs once, not per request.
                var entry_buf: [entry_max]u8 align(@alignOf(EntryHeader)) = undefined;
                var scan_offset: u64 = 0;
                var last_valid_checksum: u128 = expected.checksum;
                var last_valid_op: u64 = 0;
                var last_valid_end: u64 = @sizeOf(EntryHeader); // after root
                var entries_read: u64 = 0;

                while (scan_offset < file_size) {
                    // Read header to get entry_len.
                    const n = std.posix.pread(read_fd, entry_buf[0..@sizeOf(EntryHeader)], scan_offset) catch break;
                    if (n < @sizeOf(EntryHeader)) break;

                    const hdr: *const EntryHeader = @ptrCast(@alignCast(&entry_buf));
                    if (hdr.entry_len < @sizeOf(EntryHeader) or hdr.entry_len > entry_max) break;
                    if (scan_offset + hdr.entry_len > file_size) break;

                    // Read full entry for checksum verification.
                    const full_n = std.posix.pread(read_fd, entry_buf[0..hdr.entry_len], scan_offset) catch break;
                    if (full_n != hdr.entry_len) break;

                    // Verify parent chain.
                    if (hdr.parent != last_valid_checksum and entries_read > 0) break;

                    // Verify checksum over everything after the checksum field.
                    const checksum_offset = @offsetOf(EntryHeader, "checksum") + @sizeOf(u128);
                    const computed = cs.checksum(entry_buf[checksum_offset..hdr.entry_len]);
                    if (computed != hdr.checksum) break;

                    last_valid_checksum = hdr.checksum;
                    last_valid_op = hdr.op;
                    entries_read += 1;
                    last_valid_end = scan_offset + hdr.entry_len;
                    scan_offset += hdr.entry_len;
                }

                op = last_valid_op + 1;
                parent = last_valid_checksum;

                if (last_valid_end < file_size) {
                    log.warn("truncating {d} corrupt bytes at tail", .{file_size - last_valid_end});
                    std.posix.ftruncate(fd, last_valid_end) catch {};
                }
                log.info("recovered: entries={d} next_op={d}", .{ entries_read, op });
            } else {
                // New file — write root entry.
                const root_hdr = root_entry();
                if (!write_all(fd, std.mem.asBytes(&root_hdr))) {
                    log.err("root write failed", .{});
                    @panic("wal: failed to write root entry");
                }
                op = 1;
                parent = root_hdr.checksum;
                log.info("created new WAL", .{});
            }

            var wal = Wal{
                .fd = fd,
                .op = op,
                .parent = parent,
                .disabled = false,
            };
            wal.invariants();
            return wal;
        }

        pub fn deinit(wal: *Wal) void {
            std.posix.close(wal.fd);
            wal.* = undefined;
        }

        /// Append a SQL-write entry to the WAL.
        /// `operation`: the Operation enum value.
        /// `timestamp`: wall clock from set_time().
        /// `writes`: raw binary SQL writes (same format as sidecar protocol).
        ///   Empty for read-only operations (which shouldn't be in the WAL).
        /// `buf`: scratch buffer for assembling the entry. Must be >= entry size.
        pub fn append_writes(
            wal: *Wal,
            operation: Operation,
            timestamp: i64,
            writes_data: []const u8,
            write_count: u8,
            buf: []u8,
        ) void {
            assert(wal.op > 0);
            assert(!wal.disabled);
            assert(operation.is_mutation());
            defer wal.invariants();

            const entry_len: u32 = @intCast(@sizeOf(EntryHeader) + writes_data.len);
            assert(entry_len <= buf.len);

            // Build header.
            var hdr = EntryHeader{
                .entry_len = entry_len,
                .checksum = 0,
                .parent = wal.parent,
                .op = wal.op,
                .timestamp = timestamp,
                .operation = @intFromEnum(operation),
                .write_count = write_count,
            };

            // Assemble entry in buf: header + writes.
            @memcpy(buf[0..@sizeOf(EntryHeader)], std.mem.asBytes(&hdr));
            if (writes_data.len > 0) {
                @memcpy(buf[@sizeOf(EntryHeader)..][0..writes_data.len], writes_data);
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
