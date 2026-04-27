/// Size-limited trace writer. Wraps a file writer and stops writing
/// when the byte limit is reached. The tracer sees a normal AnyWriter —
/// it doesn't know about the limit. Writes beyond the limit are silently
/// dropped (no error, no partial write). The caller checks `limit_reached`
/// to know when to stop tracing.
///
/// TB principle: put a limit on everything. No unbounded files.
const std = @import("std");
const assert = std.debug.assert;

pub const TraceWriter = struct {
    inner: std.fs.File.Writer,
    bytes_written: u64,
    max_bytes: u64,

    pub fn init(file: std.fs.File, max_bytes: u64) TraceWriter {
        assert(max_bytes > 0);
        return .{
            .inner = file.writer(),
            .bytes_written = 0,
            .max_bytes = max_bytes,
        };
    }

    pub fn limit_reached(self: *const TraceWriter) bool {
        return self.bytes_written >= self.max_bytes;
    }

    fn write(ctx: *const anyopaque, bytes: []const u8) anyerror!usize {
        const self: *TraceWriter = @constCast(@ptrCast(@alignCast(ctx)));
        if (self.bytes_written >= self.max_bytes) return bytes.len;
        const remaining = self.max_bytes - self.bytes_written;
        const to_write = @min(bytes.len, remaining);
        const written = try self.inner.write(bytes[0..to_write]);
        self.bytes_written += written;
        return bytes.len; // report full length to avoid partial-write errors
    }

    pub fn any(self: *TraceWriter) std.io.AnyWriter {
        return .{
            .context = @ptrCast(self),
            .writeFn = write,
        };
    }
};
