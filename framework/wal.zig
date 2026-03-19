//! Write-ahead log for production replay.
//!
//! Appends every committed Message to an append-only file. No fsync —
//! the kernel flushes on its own schedule. SQLite is the authority;
//! the WAL is a diagnostic notebook.
//!
//! Each entry is a fixed-size Message (784 bytes) with:
//! - checksum_body: Aegis128L over the body region
//! - checksum: Aegis128L over the header region (covers checksum_body)
//! - parent: previous entry's checksum (hash chain)
//! - op: sequential counter, monotonically increasing
//! - timestamp: wall clock from set_time()
//!
//! Op 0 is a root entry (TB pattern). The root has operation .root
//! (enum value 0) and deterministic content — its checksum is fully
//! determined by the code. On recovery, if the root checksum doesn't
//! match what this code produces, the WAL was written by an incompatible
//! version.
//!
//! Append ordering: the server commits to the database first, then
//! appends to the WAL. This is a deliberate choice between two options:
//!
//!   Option A — WAL first, then DB:
//!     If the server crashes between append and commit, the WAL contains
//!     a mutation the database never applied. The entry is valid, the
//!     chain is intact, and there's no way to detect the phantom. The
//!     WAL lies silently.
//!
//!   Option B — DB first, then WAL (chosen):
//!     If the server crashes between commit and append, the database has
//!     the mutation but the WAL doesn't. The chain ends one entry early.
//!     This is detectable — `tiger-replay verify` reports the clean stop.
//!     The WAL is honest but incomplete.
//!
//! Option B is strictly better: a missing entry is obvious and safe,
//! a phantom entry is silent and dangerous. The gap is exactly one entry
//! wide and only exists during a process crash (kill -9, OOM, power loss).
//! During normal operation the gap doesn't matter — the database is
//! the authority and has the data.
//!
//! This ordering holds regardless of storage backend. The framework is
//! DB-agnostic — different databases have different WAL semantics or
//! none at all. The framework's WAL is independent of the storage engine.
//!
//! On crash, the tail may also be truncated mid-write. The replay tool
//! reads entries sequentially and stops at the first invalid checksum.
//!
//! If a write fails (disk full, IO error), the WAL disables itself and
//! logs a warning. The server continues serving — the WAL is secondary.

const std = @import("std");
const assert = std.debug.assert;
const cs = @import("checksum.zig");

const log = std.log.scoped(.wal);

pub fn WalType(comptime Message: type, comptime root_fn: fn () Message) type {
    return struct {
    const Wal = @This();
    fd: std.posix.fd_t,
    op: u64,
    parent: u128,
    disabled: bool,

    /// Construct the root entry — deterministic, same code always produces
    /// the same bytes. Operation is .root (enum value 0), which is not a
    /// valid application operation. Follows TigerBeetle's Header.Prepare.root().
    ///
    /// The body contains a layout sentinel — a Product with distinct values
    /// in every numeric field. If fields are reordered (same size, different
    /// semantic meaning), the body bytes change and the root checksum catches
    /// the incompatibility. An all-zero body would not detect same-size swaps.
    pub fn root() Message {
        return root_fn();
    }

    /// Open or create the WAL file. On creation, writes the root entry
    /// at op 0. On recovery, verifies the root checksum matches this
    /// code's root, then scans backwards from the last complete entry
    /// to find the last valid one and continues the chain from there.
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
            const entry_count = file_size / @sizeOf(Message);
            if (entry_count == 0) {
                // File exists but is too small for even one entry — corrupt.
                log.warn("stale WAL — deleting and starting fresh", .{});
                std.posix.close(fd);
                std.fs.cwd().deleteFile(path) catch {};
                return init(path);
            }
            {
                const read_fd = std.posix.open(
                    path,
                    .{ .ACCMODE = .RDONLY },
                    0,
                ) catch |err| {
                    log.err("open for recovery failed: {}", .{err});
                    @panic("wal: failed to open file for recovery");
                };
                // Verify root entry matches this code's version.
                const root_entry = read_entry(read_fd, 0);
                const stale = if (root_entry) |re| blk: {
                    const expected_root = Wal.root();
                    break :blk re.checksum != expected_root.checksum;
                } else true;

                if (stale) {
                    // Incompatible or corrupt WAL — delete and start fresh.
                    // Expected during development when types change between builds.
                    log.warn("stale WAL — deleting and starting fresh", .{});
                    std.posix.close(read_fd);
                    std.posix.close(fd);
                    std.fs.cwd().deleteFile(path) catch {};
                    return init(path);
                }
                defer std.posix.close(read_fd);

                // Scan backwards from the last entry to find the last valid one.
                // A crash mid-write may corrupt the tail — skip corrupt entries
                // to maintain the hash chain from the last known-good point.
                // The root was already verified above, so the scan always finds
                // at least one valid entry.
                var last_valid_slot: u64 = 0; // root, guaranteed valid
                var slot = entry_count;
                while (slot > 0) {
                    slot -= 1;
                    const entry = read_entry(read_fd, slot * @sizeOf(Message));
                    if (entry) |e| {
                        if (e.valid_checksum_header()) {
                            op = e.op + 1;
                            parent = e.checksum;
                            last_valid_slot = slot;
                            if (slot + 1 < entry_count) {
                                log.warn("skipped {d} corrupt entries at tail", .{entry_count - slot - 1});
                            }
                            log.info("recovered: entries={d} next_op={d}", .{ slot + 1, op });
                            break;
                        }
                    }
                } else unreachable; // root is always valid

                // Truncate corrupt tail so the replay tool sees a clean
                // sequential file and new appends follow the last valid entry.
                const valid_size = (last_valid_slot + 1) * @sizeOf(Message);
                if (valid_size < file_size) {
                    std.posix.ftruncate(fd, valid_size) catch |err| {
                        log.warn("ftruncate failed: {}", .{err});
                        // Non-fatal — the file has corrupt entries at the tail
                        // but new appends still go after them. The replay tool
                        // will stop at the corruption boundary.
                    };
                }
            }
        } else {
            // New file — write the root entry at op 0.
            const root_entry = Wal.root();
            if (!write_all(fd, std.mem.asBytes(&root_entry))) {
                log.err("root write failed", .{});
                @panic("wal: failed to write root entry");
            }

            op = 1;
            parent = root_entry.checksum;
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

    /// Prepare a message for the WAL: assign op, timestamp, parent,
    /// and compute checksums. Returns the prepared message.
    pub fn prepare(wal: *const Wal, msg: Message, timestamp: i64) Message {
        assert(wal.op > 0); // op 0 is the root
        assert(!wal.disabled);
        assert(msg.operation.is_mutation()); // Only mutations enter the WAL.
        var entry = msg;
        entry.op = wal.op;
        entry.timestamp = timestamp;
        entry.parent = wal.parent;
        entry.set_checksum();
        assert(entry.valid_checksum()); // Verify constructed entry.
        return entry;
    }

    /// Append a prepared message to the WAL file. Updates op counter
    /// and parent for the next entry. On write failure, disables the
    /// WAL and logs a warning — the server continues serving.
    pub fn append(wal: *Wal, entry: *const Message) void {
        assert(entry.valid_checksum());
        assert(entry.operation.is_mutation()); // Pair: prepare() asserts the same.
        assert(entry.op == wal.op);
        assert(entry.op > 0); // op 0 is the root
        assert(entry.parent == wal.parent);
        assert(!wal.disabled);
        defer wal.invariants();

        const bytes = std.mem.asBytes(entry);
        if (!write_all(wal.fd, bytes)) {
            log.warn("write failed, disabling WAL", .{});
            wal.disabled = true;
            return;
        }

        wal.parent = entry.checksum;
        wal.op += 1;
    }

    pub fn invariants(wal: *const Wal) void {
        assert(wal.fd > 0);
        assert(wal.op > 0); // root is always op 0; next op is at least 1
        if (wal.disabled) return;
        // parent must be non-zero after root (root's checksum is non-zero).
        assert(wal.parent != 0);
    }

    /// Read a single entry from the WAL at the given byte offset.
    /// Returns null if the read fails or returns fewer bytes than expected.
    pub fn read_entry(fd: std.posix.fd_t, offset: u64) ?Message {
        var buf: [@sizeOf(Message)]u8 align(@alignOf(Message)) = undefined;
        const n = std.posix.pread(fd, &buf, offset) catch return null;
        if (n != @sizeOf(Message)) return null;
        const entry: *const Message = @ptrCast(@alignCast(&buf));
        return entry.*;
    }

    /// Write all bytes to fd, retrying on partial writes (signal interruption).
    /// Returns false on error.
    pub fn write_all(fd: std.posix.fd_t, bytes: []const u8) bool {
        var remaining = bytes;
        while (remaining.len > 0) {
            const written = std.posix.write(fd, remaining) catch return false;
            if (written == 0) return false;
            remaining = remaining[written..];
        }
        return true;
    }

    }; // return struct
} // WalType
