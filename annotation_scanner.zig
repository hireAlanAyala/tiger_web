//! Annotation scanner — verifies sidecar handler exhaustiveness.
//!
//! Scans source files for `// [phase] .operation` annotations.
//! Reports missing operations, duplicates, and invalid annotations
//! with clickable file:line locations.
//!
//! Language-agnostic: comment prefix detected from file extension.
//! Only registers annotations where the next non-empty line is code
//! (not a comment), preventing false positives from documentation.
//!
//! Outputs a JSON manifest for language-specific adapters to consume.
//! The adapter reads the manifest, extracts function names from the
//! source files, and generates the dispatch file in the target language.
//!
//! Usage: zig build scan -- examples/ecommerce-ts/handlers/
//!        zig build scan -- examples/ecommerce-ts/handlers/ --manifest=generated/manifest.json

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");

const Operation = message.Operation;

/// Phases the scanner recognizes.
const Phase = enum {
    translate,
    prefetch,
    execute,
    render,
};

/// A registered annotation with its source location.
const Annotation = struct {
    phase: Phase,
    operation: []const u8,
    file: []const u8,
    line: u32,
    has_body: bool,
};

/// Comment prefix by file extension.
fn comment_prefix(path: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, path, ".ts") or
        std.mem.endsWith(u8, path, ".js") or
        std.mem.endsWith(u8, path, ".zig") or
        std.mem.endsWith(u8, path, ".go") or
        std.mem.endsWith(u8, path, ".rs") or
        std.mem.endsWith(u8, path, ".c") or
        std.mem.endsWith(u8, path, ".cpp"))
    {
        return "//";
    }
    if (std.mem.endsWith(u8, path, ".py") or
        std.mem.endsWith(u8, path, ".rb") or
        std.mem.endsWith(u8, path, ".sh"))
    {
        return "#";
    }
    if (std.mem.endsWith(u8, path, ".lua") or
        std.mem.endsWith(u8, path, ".hs"))
    {
        return "--";
    }
    return null;
}

/// Parse an annotation from a line. Returns the phase and operation name,
/// or null if the line is not a valid annotation.
/// Format: `{prefix} [{phase}] .{operation}`
fn parse_annotation(line: []const u8, prefix: []const u8) ?struct { phase: Phase, operation: []const u8 } {
    var trimmed = line;
    while (trimmed.len > 0 and (trimmed[0] == ' ' or trimmed[0] == '\t')) {
        trimmed = trimmed[1..];
    }

    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    var rest = trimmed[prefix.len..];

    while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];

    if (rest.len == 0 or rest[0] != '[') return null;
    rest = rest[1..];

    const close = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
    const phase_str = rest[0..close];
    rest = rest[close + 1 ..];

    // User-facing phase names only. Internal names (translate/execute)
    // belong to the Zig framework, not handler annotations.
    const phase: Phase = if (std.mem.eql(u8, phase_str, "route"))
        .translate
    else if (std.mem.eql(u8, phase_str, "prefetch"))
        .prefetch
    else if (std.mem.eql(u8, phase_str, "handle"))
        .execute
    else if (std.mem.eql(u8, phase_str, "render"))
        .render
    else
        return null;

    while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];

    if (rest.len == 0 or rest[0] != '.') return null;
    rest = rest[1..];

    var end: usize = 0;
    while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) {
        end += 1;
    }
    if (end == 0) return null;

    return .{ .phase = phase, .operation = rest[0..end] };
}

/// Returns true if a line is a comment.
fn is_comment(line: []const u8, prefix: []const u8) bool {
    var trimmed = line;
    while (trimmed.len > 0 and (trimmed[0] == ' ' or trimmed[0] == '\t')) {
        trimmed = trimmed[1..];
    }
    return std.mem.startsWith(u8, trimmed, prefix);
}

/// Returns true if a line is empty or whitespace-only.
fn is_empty(line: []const u8) bool {
    for (line) |ch| {
        if (ch != ' ' and ch != '\t' and ch != '\r' and ch != '\n') return false;
    }
    return true;
}

/// Map internal phase names back to user-facing names for error messages.
fn user_phase_name(phase: Phase) []const u8 {
    return switch (phase) {
        .translate => "route",
        .prefetch => "prefetch",
        .execute => "handle",
        .render => "render",
    };
}

/// All valid operation names, known at comptime from the Operation enum.
const valid_operations = blk: {
    const fields = @typeInfo(Operation).@"enum".fields;
    var names: [fields.len][]const u8 = undefined;
    for (fields, 0..) |f, i| names[i] = f.name;
    break :blk names;
};

fn is_valid_operation(name: []const u8) bool {
    for (valid_operations) |op| {
        if (std.mem.eql(u8, op, name)) return true;
    }
    return false;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.process.args();
    _ = args.skip(); // binary name

    const scan_dir = args.next() orelse {
        std.debug.print("Usage: annotation-scanner <directory> [--manifest=<output.json>]\n", .{});
        std.process.exit(1);
    };

    var manifest_path: ?[]const u8 = null;
    if (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--manifest=")) {
            manifest_path = arg[11..];
        }
    }

    var annotations = std.ArrayList(Annotation).init(allocator);
    defer annotations.deinit();

    var errors: u32 = 0;
    const stderr = std.io.getStdErr().writer();

    // Scan all files recursively.
    var dir = std.fs.cwd().openDir(scan_dir, .{ .iterate = true }) catch |err| {
        try stderr.print("error: cannot open directory '{s}': {}\n", .{ scan_dir, err });
        std.process.exit(1);
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        const prefix = comment_prefix(entry.basename) orelse continue;

        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ scan_dir, entry.path });

        const content = dir.readFileAlloc(allocator, entry.path, 1024 * 1024) catch |err| {
            try stderr.print("error: cannot read '{s}': {}\n", .{ path, err });
            errors += 1;
            continue;
        };
        defer allocator.free(content);

        var line_num: u32 = 0;
        var lines = std.mem.splitScalar(u8, content, '\n');
        var prev_annotation: ?struct { phase: Phase, operation: []const u8, line: u32 } = null;

        while (lines.next()) |line| {
            line_num += 1;

            if (prev_annotation) |ann| {
                if (!is_empty(line)) {
                    // Check if this line is another annotation.
                    const next_ann = parse_annotation(line, prefix);

                    if (next_ann != null or is_comment(line, prefix)) {
                        // [handle] without function body = read-only, register it.
                        // Other phases without a body are warnings.
                        if (ann.phase == .execute) {
                            if (!is_valid_operation(ann.operation)) {
                                try stderr.print("error: {s}:{d}: unknown operation '.{s}'\n", .{ path, ann.line, ann.operation });
                                errors += 1;
                            } else {
                                try annotations.append(.{
                                    .phase = ann.phase,
                                    .operation = try allocator.dupe(u8, ann.operation),
                                    .file = try allocator.dupe(u8, path),
                                    .line = ann.line,
                                    .has_body = false,
                                });
                            }
                        } else if (next_ann == null) {
                            // Non-handle annotation followed by comment.
                            try stderr.print("warning: {s}:{d}: annotation followed by comment, skipping\n", .{ path, ann.line });
                        } else {
                            try stderr.print("error: {s}:{d}: [{s}] .{s} requires a function body\n", .{
                                path, ann.line, user_phase_name(ann.phase), ann.operation,
                            });
                            errors += 1;
                        }
                        prev_annotation = null;

                        // If this line is a new annotation, start tracking it.
                        if (next_ann) |na| {
                            prev_annotation = .{ .phase = na.phase, .operation = na.operation, .line = line_num };
                        }
                    } else {
                        // Non-empty, non-comment, non-annotation = code. Register.
                        if (!is_valid_operation(ann.operation)) {
                            try stderr.print("error: {s}:{d}: unknown operation '.{s}'\n", .{ path, ann.line, ann.operation });
                            errors += 1;
                        } else {
                            try annotations.append(.{
                                .phase = ann.phase,
                                .operation = try allocator.dupe(u8, ann.operation),
                                .file = try allocator.dupe(u8, path),
                                .line = ann.line,
                                .has_body = true,
                            });
                        }
                        prev_annotation = null;
                        continue;
                    }
                } else {
                    continue;
                }
            } else {
                if (parse_annotation(line, prefix)) |ann| {
                    prev_annotation = .{ .phase = ann.phase, .operation = ann.operation, .line = line_num };
                }
            }
        }

        // Handle annotation at EOF.
        if (prev_annotation) |ann| {
            if (ann.phase == .execute) {
                // [handle] at EOF = read-only, register it.
                if (is_valid_operation(ann.operation)) {
                    try annotations.append(.{
                        .phase = ann.phase,
                        .operation = try allocator.dupe(u8, ann.operation),
                        .file = try allocator.dupe(u8, path),
                        .line = ann.line,
                        .has_body = false,
                    });
                }
            } else {
                try stderr.print("warning: {s}:{d}: annotation at end of file, no code follows\n", .{ path, ann.line });
            }
        }
    }

    // Check for duplicates.
    for (annotations.items, 0..) |a, i| {
        for (annotations.items[i + 1 ..]) |b| {
            if (a.phase == b.phase and std.mem.eql(u8, a.operation, b.operation)) {
                try stderr.print("error: duplicate handler for [{s}] .{s}\n  --> {s}:{d}\n  --> {s}:{d}\n", .{
                    user_phase_name(a.phase), a.operation, a.file, a.line, b.file, b.line,
                });
                errors += 1;
            }
        }
    }

    // Check exhaustiveness — every non-root operation needs a handler for each phase.
    const phases = [_]Phase{ .translate, .prefetch, .execute, .render };
    for (phases) |phase| {
        for (valid_operations) |op| {
            if (std.mem.eql(u8, op, "root")) continue;

            var found = false;
            for (annotations.items) |ann| {
                if (ann.phase == phase and std.mem.eql(u8, ann.operation, op)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try stderr.print("error: missing handler for [{s}] .{s}\n", .{ user_phase_name(phase), op });
                errors += 1;
            }
        }
    }

    // Summary.
    const stdout = std.io.getStdOut().writer();
    if (errors > 0) {
        try stderr.print("\n{d} error(s) found.\n", .{errors});
        std.process.exit(1);
    }

    try stdout.print("OK: {d} annotations in {s}/\n", .{ annotations.items.len, scan_dir });

    // Write manifest if requested.
    if (manifest_path) |out_path| {
        try emit_manifest(allocator, out_path, annotations.items);
        try stdout.print("Manifest: {s}\n", .{out_path});
    }
}

/// Write the annotation manifest as JSON.
/// This is the contract between the scanner and language adapters.
fn emit_manifest(allocator: std.mem.Allocator, out_path: []const u8, annotations: []const Annotation) !void {
    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();

    try w.writeAll("{\n  \"annotations\": [\n");
    for (annotations, 0..) |ann, i| {
        if (i > 0) try w.writeAll(",\n");
        try w.print("    {{ \"phase\": \"{s}\", \"operation\": \"{s}\", \"file\": \"{s}\", \"line\": {d}, \"has_body\": {s} }}", .{
            @tagName(ann.phase), ann.operation, ann.file, ann.line, if (ann.has_body) "true" else "false",
        });
    }
    try w.writeAll("\n  ]\n}\n");

    const file = try std.fs.cwd().createFile(out_path, .{});
    defer file.close();
    try file.writeAll(buf.items);
}

// =====================================================================
// Tests
// =====================================================================

test "parse_annotation valid" {
    const result = parse_annotation("// [handle] .create_product", "//");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(result.?.phase, .execute);
    try std.testing.expect(std.mem.eql(u8, result.?.operation, "create_product"));
}

test "parse_annotation with leading whitespace" {
    const result = parse_annotation("  // [render] .get_product", "//");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(result.?.phase, .render);
}

test "parse_annotation python style" {
    const result = parse_annotation("# [route] .list_products", "#");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(result.?.phase, .translate);
    try std.testing.expect(std.mem.eql(u8, result.?.operation, "list_products"));
}

test "parse_annotation all user-facing phases" {
    const route = parse_annotation("// [route] .create_product", "//");
    try std.testing.expect(route != null);
    try std.testing.expectEqual(route.?.phase, .translate);

    const prefetch = parse_annotation("// [prefetch] .create_product", "//");
    try std.testing.expect(prefetch != null);
    try std.testing.expectEqual(prefetch.?.phase, .prefetch);

    const handle = parse_annotation("// [handle] .get_product", "//");
    try std.testing.expect(handle != null);
    try std.testing.expectEqual(handle.?.phase, .execute);

    const render = parse_annotation("// [render] .list_products", "//");
    try std.testing.expect(render != null);
    try std.testing.expectEqual(render.?.phase, .render);
}

test "parse_annotation rejects internal prefetch name" {
    // "prefetch" is a valid user-facing name (unlike translate/execute).
    const result = parse_annotation("// [prefetch] .get_product", "//");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(result.?.phase, .prefetch);
}

test "user_phase_name round-trips" {
    try std.testing.expect(std.mem.eql(u8, user_phase_name(.translate), "route"));
    try std.testing.expect(std.mem.eql(u8, user_phase_name(.prefetch), "prefetch"));
    try std.testing.expect(std.mem.eql(u8, user_phase_name(.execute), "handle"));
    try std.testing.expect(std.mem.eql(u8, user_phase_name(.render), "render"));
}

test "parse_annotation rejects internal phase names" {
    // Internal names belong to Zig framework, not handler annotations.
    try std.testing.expect(parse_annotation("// [translate] .foo", "//") == null);
    try std.testing.expect(parse_annotation("// [execute] .foo", "//") == null);
}

test "parse_annotation invalid phase" {
    try std.testing.expect(parse_annotation("// [unknown] .foo", "//") == null);
}

test "parse_annotation no dot" {
    try std.testing.expect(parse_annotation("// [execute] create_product", "//") == null);
}

test "parse_annotation not a comment" {
    try std.testing.expect(parse_annotation("export function foo()", "//") == null);
}

test "is_comment" {
    try std.testing.expect(is_comment("// hello", "//"));
    try std.testing.expect(is_comment("  // hello", "//"));
    try std.testing.expect(!is_comment("export function", "//"));
    try std.testing.expect(is_comment("# hello", "#"));
}

test "is_empty" {
    try std.testing.expect(is_empty(""));
    try std.testing.expect(is_empty("  \t  "));
    try std.testing.expect(!is_empty("code"));
}

test "is_valid_operation" {
    try std.testing.expect(is_valid_operation("create_product"));
    try std.testing.expect(is_valid_operation("get_product"));
    try std.testing.expect(is_valid_operation("root"));
    try std.testing.expect(!is_valid_operation("nonexistent"));
    try std.testing.expect(!is_valid_operation(""));
}

test "comment_prefix by extension" {
    try std.testing.expect(std.mem.eql(u8, comment_prefix("foo.ts").?, "//"));
    try std.testing.expect(std.mem.eql(u8, comment_prefix("bar.py").?, "#"));
    try std.testing.expect(std.mem.eql(u8, comment_prefix("baz.lua").?, "--"));
    try std.testing.expect(comment_prefix("readme.md") == null);
}
