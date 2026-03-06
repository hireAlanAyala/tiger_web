//! Coverage marks: link production log sites to test assertions.
//!
//! In production code, `log.mark.warn(...)` records a hit when a mark is active.
//! In test code, `marks.check("substring")` activates a mark, and
//! `mark.expect_hit()` / `mark.expect_not_hit()` assert coverage.
//!
//! Zero overhead in non-test builds — `mark` aliases the base logger directly.
//! Follows TigerBeetle's `src/testing/marks.zig` exactly.

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

const GlobalStateType = if (builtin.is_test) struct {
    mark_name: ?[]const u8 = null,
    mark_hit_count: u32 = 0,
} else void;

var global_state: GlobalStateType = .{};

pub const Mark = struct {
    name: []const u8,

    pub fn expect_hit(mark: Mark) !void {
        comptime assert(builtin.is_test);
        assert(global_state.mark_name.?.ptr == mark.name.ptr);
        defer global_state = .{};

        if (global_state.mark_hit_count == 0) {
            std.debug.print("mark '{s}' not hit", .{mark.name});
            return error.MarkNotHit;
        }
    }

    pub fn expect_not_hit(mark: Mark) !void {
        comptime assert(builtin.is_test);
        assert(global_state.mark_name.?.ptr == mark.name.ptr);
        defer global_state = .{};

        if (global_state.mark_hit_count != 0) {
            std.debug.print("mark '{s}' hit", .{mark.name});
            return error.MarkHit;
        }
    }
};

pub fn check(name: []const u8) Mark {
    comptime assert(builtin.is_test);
    assert(global_state.mark_name == null);
    assert(global_state.mark_hit_count == 0);

    global_state.mark_name = name;
    return Mark{ .name = name };
}

pub fn wrap_log(comptime base: type) type {
    return struct {
        pub const mark = if (builtin.is_test) struct {
            pub fn err(comptime fmt: []const u8, args: anytype) void {
                record(fmt);
                base.err(fmt, args);
            }

            pub fn warn(comptime fmt: []const u8, args: anytype) void {
                record(fmt);
                base.warn(fmt, args);
            }

            pub fn info(comptime fmt: []const u8, args: anytype) void {
                record(fmt);
                base.info(fmt, args);
            }

            pub fn debug(comptime fmt: []const u8, args: anytype) void {
                record(fmt);
                base.debug(fmt, args);
            }
        } else base;

        pub const err = base.err;
        pub const warn = base.warn;
        pub const info = base.info;
        pub const debug = base.debug;
    };
}

fn record(fmt: []const u8) void {
    comptime assert(builtin.is_test);
    if (global_state.mark_name) |mark_active| {
        if (std.mem.indexOf(u8, fmt, mark_active) != null) {
            global_state.mark_hit_count += 1;
        }
    }
}

test "mark hit" {
    const log = wrap_log(std.log.scoped(.test_marks));

    const mark = check("something happened");
    log.mark.warn("something happened fd={d}", .{42});
    try mark.expect_hit();
}

test "mark not hit" {
    const log = wrap_log(std.log.scoped(.test_marks));

    const mark = check("something happened");
    log.warn("different message fd={d}", .{42});
    try mark.expect_not_hit();
}

test "mark — non-test global state is void" {
    comptime {
        // In test builds GlobalStateType is a struct; in non-test it would be void.
        // We can only verify the test-build size is non-zero here.
        assert(@sizeOf(GlobalStateType) > 0);
    }
}
