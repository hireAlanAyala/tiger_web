//! Shared IO definitions — imported by io/linux.zig.
//! Ported from TigerBeetle's src/io.zig (Linux-only subset).

const std = @import("std");

pub const DirectIO = enum {
    direct_io_required,
    direct_io_optional,
    direct_io_disabled,
};

pub fn buffer_limit(buffer_len: usize) usize {
    // Linux limits pwrite/pread to 0x7ffff000 bytes due to signed C int return.
    return @min(0x7ffff000, buffer_len);
}
