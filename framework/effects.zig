const std = @import("std");
const assert = std.debug.assert;

/// Render result — metadata describing effects written into a shared buffer.
///
/// Handlers call ctx.render(.{ ... }) with a tuple of effect descriptors.
/// The ctx.render() method validates the tuple at comptime, writes HTML
/// content into the framework's send buffer at runtime, and returns this
/// metadata describing where each effect's content lives in the buffer.
///
/// The framework reads the metadata + buffer to deliver as Datastar SSE
/// events or full-page HTML.

pub const effects_max = 16;

/// Inline selector buffer. Worst-case measured: "#col-" + 32-char hex UUID = 37 bytes.
/// 64 gives headroom for future selectors without buffer indirection.
pub const selector_max = 64;

comptime {
    assert(effects_max > 0);
    assert(selector_max > 0);
    assert(selector_max >= 37);
}

/// Maps 1:1 to Datastar SSE event types.
pub const EventType = enum {
    /// datastar-patch-elements — morph/append/replace/remove DOM elements.
    patch_elements,
    /// datastar-patch-signals — update reactive signal state on client.
    patch_signals,
};

/// Element patch modes — matches Datastar's ElementPatchMode enum exactly.
pub const PatchMode = enum {
    outer,
    inner,
    replace,
    prepend,
    append,
    before,
    after,
    remove,

    fn from_comptime_str(comptime s: []const u8) PatchMode {
        return comptime if (std.mem.eql(u8, s, "outer")) .outer
        else if (std.mem.eql(u8, s, "inner")) .inner
        else if (std.mem.eql(u8, s, "replace")) .replace
        else if (std.mem.eql(u8, s, "prepend")) .prepend
        else if (std.mem.eql(u8, s, "append")) .append
        else if (std.mem.eql(u8, s, "before")) .before
        else if (std.mem.eql(u8, s, "after")) .after
        else if (std.mem.eql(u8, s, "remove")) .remove
        else @compileError("invalid patch mode: \"" ++ s ++ "\"");
    }
};

/// User-facing effect verbs. These map to Datastar methods:
///   "patch"   → patchElements (with mode)
///   "remove"  → patchElements (mode=remove, no html — sugar)
///   "signal"  → patchSignals
///   "script"  → patchElements (as <script> tag — sugar)
///   "sync"    → framework-level: re-run another page's pipeline
pub const Verb = enum {
    patch,
    remove,
    signal,
    script,
    sync,

    fn from_comptime_str(comptime s: []const u8) Verb {
        return comptime if (std.mem.eql(u8, s, "patch")) .patch
        else if (std.mem.eql(u8, s, "remove")) .remove
        else if (std.mem.eql(u8, s, "signal")) .signal
        else if (std.mem.eql(u8, s, "script")) .script
        else if (std.mem.eql(u8, s, "sync")) .sync
        else @compileError("invalid render verb: \"" ++ s ++ "\". Valid: patch, remove, signal, script, sync");
    }
};

/// Per-effect metadata — describes one effect's location in the shared buffer.
pub const EffectMeta = struct {
    event_type: EventType,
    verb: Verb,
    mode: PatchMode = .outer,
    selector: [selector_max]u8 = .{0} ** selector_max,
    selector_len: u8 = 0,
    content_offset: u32 = 0,
    content_len: u32 = 0,

    pub fn selector_slice(self: *const EffectMeta) []const u8 {
        return self.selector[0..self.selector_len];
    }

    pub fn content(self: *const EffectMeta, buf: []const u8) []const u8 {
        assert(self.content_offset + self.content_len <= buf.len);
        return buf[self.content_offset..][0..self.content_len];
    }
};

/// Result returned by ctx.render(). Metadata only — content lives in the buffer.
pub const RenderResult = struct {
    effects: [effects_max]EffectMeta = undefined,
    len: u8 = 0,
    buf_used: u32 = 0,

    pub fn slice(self: *const RenderResult) []const EffectMeta {
        return self.effects[0..self.len];
    }

    fn add(self: *RenderResult, meta: EffectMeta) void {
        assert(self.len < effects_max);
        self.effects[self.len] = meta;
        self.len += 1;
    }
};

/// Process a comptime-known effect tuple and write content into buf.
/// Called by HandlerContext.render(). Validates at comptime, writes at runtime.
///
/// Each element in the tuple is itself a tuple describing one effect:
///   .{ "patch", "#selector", html, "mode" }
///   .{ "remove", "#selector" }
///   .{ "signal", signals_json }
///   .{ "script", code }
///   .{ "sync", "/route" }
pub fn process_effects(comptime effects_tuple: anytype, buf: []u8) RenderResult {
    var result = RenderResult{};
    var pos: u32 = 0;

    inline for (std.meta.fields(@TypeOf(effects_tuple))) |field| {
        const effect = @field(effects_tuple, field.name);
        const verb = comptime Verb.from_comptime_str(effect.@"0");

        switch (verb) {
            .patch => {
                // .{ "patch", selector, html, mode }
                comptime assert(std.meta.fields(@TypeOf(effect)).len == 4);
                const selector = effect.@"1";
                const html: []const u8 = effect.@"2";
                const mode = comptime PatchMode.from_comptime_str(effect.@"3");

                var meta = EffectMeta{
                    .event_type = .patch_elements,
                    .verb = .patch,
                    .mode = mode,
                    .content_offset = pos,
                    .content_len = @intCast(html.len),
                };
                comptime assert(selector.len > 0);
                comptime assert(selector.len <= selector_max);
                @memcpy(meta.selector[0..selector.len], selector);
                meta.selector_len = selector.len;

                if (html.len > 0) {
                    assert(pos + html.len <= buf.len);
                    @memcpy(buf[pos..][0..html.len], html);
                    pos += @intCast(html.len);
                }

                result.add(meta);
            },
            .remove => {
                // .{ "remove", selector }
                comptime assert(std.meta.fields(@TypeOf(effect)).len == 2);
                const selector = effect.@"1";

                var meta = EffectMeta{
                    .event_type = .patch_elements,
                    .verb = .remove,
                    .mode = .remove,
                };
                comptime assert(selector.len > 0);
                comptime assert(selector.len <= selector_max);
                @memcpy(meta.selector[0..selector.len], selector);
                meta.selector_len = selector.len;

                result.add(meta);
            },
            .signal => {
                // .{ "signal", signals_json }
                comptime assert(std.meta.fields(@TypeOf(effect)).len == 2);
                const signals: []const u8 = effect.@"1";

                assert(pos + signals.len <= buf.len);
                @memcpy(buf[pos..][0..signals.len], signals);

                result.add(.{
                    .event_type = .patch_signals,
                    .verb = .signal,
                    .content_offset = pos,
                    .content_len = @intCast(signals.len),
                });
                pos += @intCast(signals.len);
            },
            .script => {
                // .{ "script", code }
                comptime assert(std.meta.fields(@TypeOf(effect)).len == 2);
                const code: []const u8 = effect.@"1";

                assert(pos + code.len <= buf.len);
                @memcpy(buf[pos..][0..code.len], code);

                result.add(.{
                    .event_type = .patch_elements,
                    .verb = .script,
                    .content_offset = pos,
                    .content_len = @intCast(code.len),
                });
                pos += @intCast(code.len);
            },
            .sync => {
                // .{ "sync", route }
                comptime assert(std.meta.fields(@TypeOf(effect)).len == 2);
                const route = effect.@"1";
                comptime assert(route.len > 0);
                comptime assert(route[0] == '/');
                comptime assert(route.len <= selector_max);

                var meta = EffectMeta{
                    .event_type = .patch_elements, // framework handles sync internally
                    .verb = .sync,
                };
                @memcpy(meta.selector[0..route.len], route);
                meta.selector_len = route.len;

                result.add(meta);
            },
        }
    }

    result.buf_used = pos;
    return result;
}

// =====================================================================
// Tests
// =====================================================================

test "process_effects: single patch" {
    var buf: [4096]u8 = undefined;
    const html = "hello world";
    const result = process_effects(.{
        .{ "patch", "#target", @as([]const u8, html), "outer" },
    }, &buf);

    try std.testing.expectEqual(@as(u8, 1), result.len);
    try std.testing.expectEqual(Verb.patch, result.effects[0].verb);
    try std.testing.expectEqual(PatchMode.outer, result.effects[0].mode);
    try std.testing.expect(std.mem.eql(u8, "#target", result.effects[0].selector_slice()));
    try std.testing.expect(std.mem.eql(u8, "hello world", result.effects[0].content(&buf)));
}

test "process_effects: mixed effects" {
    var buf: [4096]u8 = undefined;
    const html = "<div>card</div>";
    const signals = "{\"count\":5}";
    const result = process_effects(.{
        .{ "patch", "#list", @as([]const u8, html), "inner" },
        .{ "signal", @as([]const u8, signals) },
        .{ "script", @as([]const u8, "console.log('done')") },
        .{ "sync", "/dashboard" },
    }, &buf);

    try std.testing.expectEqual(@as(u8, 4), result.len);
    try std.testing.expectEqual(Verb.patch, result.effects[0].verb);
    try std.testing.expectEqual(PatchMode.inner, result.effects[0].mode);
    try std.testing.expectEqual(Verb.signal, result.effects[1].verb);
    try std.testing.expectEqual(Verb.script, result.effects[2].verb);
    try std.testing.expectEqual(Verb.sync, result.effects[3].verb);
    try std.testing.expect(std.mem.eql(u8, "/dashboard", result.effects[3].selector_slice()));

    // Content is contiguous in buffer.
    try std.testing.expect(std.mem.eql(u8, html, result.effects[0].content(&buf)));
    try std.testing.expect(std.mem.eql(u8, signals, result.effects[1].content(&buf)));
}

test "process_effects: remove sugar" {
    var buf: [4096]u8 = undefined;
    const result = process_effects(.{
        .{ "remove", "#old-element" },
    }, &buf);

    try std.testing.expectEqual(@as(u8, 1), result.len);
    try std.testing.expectEqual(Verb.remove, result.effects[0].verb);
    try std.testing.expectEqual(PatchMode.remove, result.effects[0].mode);
    try std.testing.expectEqual(@as(u32, 0), result.effects[0].content_len);
}

test "process_effects: empty returns zero effects" {
    var buf: [4096]u8 = undefined;
    const result = process_effects(.{}, &buf);

    try std.testing.expectEqual(@as(u8, 0), result.len);
    try std.testing.expectEqual(@as(u32, 0), result.buf_used);
}

test "process_effects: all patch modes" {
    var buf: [4096]u8 = undefined;
    const html = @as([]const u8, "x");
    const result = process_effects(.{
        .{ "patch", "#a", html, "outer" },
        .{ "patch", "#b", html, "inner" },
        .{ "patch", "#c", html, "replace" },
        .{ "patch", "#d", html, "prepend" },
        .{ "patch", "#e", html, "append" },
        .{ "patch", "#f", html, "before" },
        .{ "patch", "#g", html, "after" },
    }, &buf);

    try std.testing.expectEqual(@as(u8, 7), result.len);
    try std.testing.expectEqual(PatchMode.outer, result.effects[0].mode);
    try std.testing.expectEqual(PatchMode.inner, result.effects[1].mode);
    try std.testing.expectEqual(PatchMode.replace, result.effects[2].mode);
    try std.testing.expectEqual(PatchMode.prepend, result.effects[3].mode);
    try std.testing.expectEqual(PatchMode.append, result.effects[4].mode);
    try std.testing.expectEqual(PatchMode.before, result.effects[5].mode);
    try std.testing.expectEqual(PatchMode.after, result.effects[6].mode);
}
