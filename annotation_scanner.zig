//! Annotation scanner — the framework's compiler for handler correctness.
//!
//! Scans source files for `// [phase] .operation` annotations.
//! Reports missing operations, duplicates, and invalid annotations
//! with clickable file:line locations.
//!
//! Language-agnostic: comment prefix detected from file extension.
//! Only registers annotations where the next non-empty line is code
//! (not a comment), preventing false positives from documentation.
//!
//! ## Status exhaustiveness
//!
//! Extracts status literals from [handle] bodies and handled statuses
//! from [render] bodies using language-specific patterns. Errors if
//! render doesn't cover every status that handle can return.
//!
//! Same check for all languages — Zig, TypeScript, Ruby, anything with
//! a language adapter. No generated types, no generated enums. The
//! scanner reads source text and compares two sets. This is deliberate:
//!
//! - **No sidecar type generation.** Sidecar languages don't get LSP
//!   type help for status values (status is `string`, not a union).
//!   This trade-off buys language-agnostic enforcement: adding a new
//!   sidecar language is one adapter struct, not a type generation
//!   pipeline. AI-generated handlers get the same feedback from
//!   `zig build scan`. CI catches drift with one build step.
//!
//! - **No catch-all handling.** Render must name every status explicitly.
//!   Negation patterns (`!== "ok"`, `else`, default branches) are not
//!   recognized — they hide which statuses are actually handled. Each
//!   status gets its own branch, each branch is visible to the scanner,
//!   each omission produces a specific error naming the missing status.
//!   Same principle as TigerBeetle's "assert one thing at a time."
//!
//! For Zig handlers, the compiler's exhaustive switch provides a second
//! layer of enforcement (redundant but harmless). For sidecar languages,
//! the scanner is the only enforcement.
//!
//! ## Manifest
//!
//! Outputs a JSON manifest for language-specific adapters to consume.
//! The adapter reads the manifest, extracts function names from the
//! source files, and generates the dispatch file in the target language.
//!
//! ## Usage
//!
//!     zig build scan
//!     zig build scan -- --manifest=generated/manifest.json

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

// =====================================================================
// Status extraction — language-adapter pattern matching
// =====================================================================

/// Maximum statuses per handler. Must fit all Status enum variants.
const max_statuses = 16;
comptime {
    // If Status gains more variants than max_statuses, this fires.
    assert(@typeInfo(message.Status).@"enum".fields.len <= max_statuses);
}

/// Fixed-size set of status names, deduplicated.
const StatusSet = struct {
    names: [max_statuses][]const u8 = .{&.{}} ** max_statuses,
    len: u8 = 0,

    fn add(self: *StatusSet, name: []const u8) void {
        assert(name.len > 0);
        for (self.names[0..self.len]) |existing| {
            if (std.mem.eql(u8, existing, name)) return; // deduplicate
        }
        assert(self.len < max_statuses);
        self.names[self.len] = name;
        self.len += 1;
    }

    fn slice(self: *const StatusSet) []const []const u8 {
        return self.names[0..self.len];
    }
};

/// Per-operation status extraction result.
const OperationStatuses = struct {
    operation: []const u8,
    statuses: StatusSet,
};

/// Language-specific pattern for extracting status literals.
/// The scanner searches for `prefix` in each byte position, then reads
/// the identifier that follows (terminated by `terminators` characters).
/// If `suffix` is set, the suffix must appear after the identifier
/// (with optional whitespace) for the match to count.
///
/// Example: Zig render uses prefix=".", suffix="=>" to match `.ok =>`
/// (switch arm) but NOT `.product` (field access) or `.active` (flag).
/// Without the suffix, every dot-access in the function body would be
/// extracted as a status name.
const StatusPattern = struct {
    prefix: []const u8,
    terminators: []const u8,
    suffix: ?[]const u8 = null,
};

/// Language adapter — extraction patterns for handle and render phases.
///
/// Adding a new sidecar language: define one LanguageAdapter with the
/// language's status patterns. No type generation, no compiler plugin.
/// The scanner's text matching is sufficient because:
/// - handle statuses are always literals in return expressions
/// - render statuses are always literals in switch/case/comparison
/// - the self-correcting property catches any false negatives
///
/// Render patterns must match EXPLICIT status references only — not
/// negation, not default/else, not catch-all. If the scanner can't see
/// which status a branch handles, it can't verify the branch exists.
const LanguageAdapter = struct {
    extensions: []const []const u8,
    handle_patterns: []const StatusPattern,
    render_patterns: []const StatusPattern,
};

/// Zig adapter.
/// handle: `{ .status = .not_found }` (HandleResult literal) → extracts status name
///   The `{ .status = .` prefix distinguishes struct literal init from field
///   assignment (`order_result.status = .pending` has no leading `{`).
///   Legacy patterns (`read_only(.`, `single(.`) kept for scanner test content.
/// render: `.not_found =>` (switch arm) → extracts status name
const zig_adapter = LanguageAdapter{
    .extensions = &.{".zig"},
    .handle_patterns = &.{
        .{ .prefix = "{ .status = .", .terminators = " ,)};:\t\n" },
        .{ .prefix = "read_only(.", .terminators = ",)};: \t\n" },
        .{ .prefix = "single(.", .terminators = ",)};: \t\n" },
    },
    .render_patterns = &.{
        .{ .prefix = ".", .terminators = " \t\n=>,)", .suffix = "=>" },
    },
};

/// TypeScript adapter.
/// handle: `status: "not_found"` → "not_found"
/// render: `case "not_found":` or `=== "not_found"` → status names
///
/// `!==` is deliberately excluded. `if (status !== "ok")` is a catch-all
/// that handles every non-ok status in one branch — the scanner can't
/// tell which statuses that branch covers. The developer must write
/// `if (status === "not_found")` for each status so the scanner can
/// verify each one exists.
const ts_adapter = LanguageAdapter{
    .extensions = &.{ ".ts", ".js" },
    .handle_patterns = &.{
        .{ .prefix = "status: \"", .terminators = "\"" },
    },
    .render_patterns = &.{
        .{ .prefix = "case \"", .terminators = "\"" },
        .{ .prefix = "=== \"", .terminators = "\"" },
    },
};

const adapters = [_]LanguageAdapter{ zig_adapter, ts_adapter };

comptime {
    for (adapters) |a| {
        assert(a.extensions.len > 0);
        assert(a.handle_patterns.len > 0);
        assert(a.render_patterns.len > 0);
        for (a.handle_patterns) |p| assert(p.prefix.len > 0);
        for (a.render_patterns) |p| assert(p.prefix.len > 0);
    }
}

/// Select adapter based on file extension.
fn find_adapter(path: []const u8) ?LanguageAdapter {
    for (adapters) |a| {
        for (a.extensions) |ext| {
            if (std.mem.endsWith(u8, path, ext)) return a;
        }
    }
    return null;
}

// Aliases for tests.
const zig_status_patterns = zig_adapter.handle_patterns;
const ts_status_patterns = ts_adapter.handle_patterns;

/// Extract status literals from a function body.
///
/// Locates the function body by finding the first `{` at or after
/// `start_line` (1-based), then scans with brace-depth tracking
/// until the body closes. Within the body, applies each pattern
/// to extract status names.
///
/// Used for both handle and render extraction — patterns differ.
///
/// Known limitation: brace counting does not skip string literals or
/// comments. A `{` or `}` inside a string would throw off the depth.
/// In practice, handle/render bodies don't contain brace characters
/// in string literals. If they did, the scanner would extract too few
/// or too many statuses — self-correcting via the exhaustiveness check.
fn extract_statuses_from_body(
    content: []const u8,
    start_line: u32,
    patterns: []const StatusPattern,
) StatusSet {
    assert(start_line > 0); // 1-based
    var result = StatusSet{};

    // Advance to start_line (1-based).
    var pos: usize = 0;
    var line_num: u32 = 1;
    while (line_num < start_line and pos < content.len) {
        if (content[pos] == '\n') line_num += 1;
        pos += 1;
    }

    // Find the opening brace of the function body.
    const brace_start = std.mem.indexOfScalar(u8, content[pos..], '{') orelse return result;
    pos = pos + brace_start + 1;
    var depth: u32 = 1;

    // Scan through the function body.
    while (pos < content.len and depth > 0) {
        switch (content[pos]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                pos += 1;
                continue;
            },
            else => {},
        }
        if (depth > 0) {
            for (patterns) |pat| {
                if (pos + pat.prefix.len <= content.len and
                    std.mem.eql(u8, content[pos..][0..pat.prefix.len], pat.prefix))
                {
                    const name_start = pos + pat.prefix.len;
                    var name_end = name_start;
                    while (name_end < content.len) {
                        if (is_terminator(content[name_end], pat.terminators)) break;
                        if (!std.ascii.isAlphanumeric(content[name_end]) and content[name_end] != '_') break;
                        name_end += 1;
                    }
                    if (name_end > name_start) {
                        // If pattern has a suffix, verify it follows the identifier.
                        if (pat.suffix) |suffix| {
                            var check = name_end;
                            while (check < content.len and (content[check] == ' ' or content[check] == '\t')) check += 1;
                            if (check + suffix.len <= content.len and
                                std.mem.eql(u8, content[check..][0..suffix.len], suffix))
                            {
                                result.add(content[name_start..name_end]);
                            }
                        } else {
                            result.add(content[name_start..name_end]);
                        }
                    }
                }
            }
        }
        pos += 1;
    }

    return result;
}

/// Extract statuses from a handle() body. Always includes "ok" because
/// HandlerContext defaults status to .ok — the variant must exist.
/// Bodyless handles (read-only) return only ok, set by the caller.
fn extract_statuses_from_handle(
    content: []const u8,
    start_line: u32,
    patterns: []const StatusPattern,
) StatusSet {
    var result = extract_statuses_from_body(content, start_line, patterns);
    result.add("ok");
    assert(result.len >= 1); // "ok" was just added
    assert(has_name(&result, "ok")); // pair: add promised, we verify
    return result;
}

fn is_terminator(ch: u8, terminators: []const u8) bool {
    for (terminators) |term| {
        if (ch == term) return true;
    }
    return false;
}

/// Scan a single file's content for annotations. Returns the number of errors found.
/// Extracted from main() for testability.
fn scan_file_content(
    allocator: std.mem.Allocator,
    content: []const u8,
    prefix: []const u8,
    path: []const u8,
    annotations: *std.ArrayList(Annotation),
) !u32 {
    var errors: u32 = 0;
    const stderr = std.io.getStdErr().writer();

    var line_num: u32 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var prev_annotation: ?struct { phase: Phase, operation: []const u8, line: u32 } = null;

    while (lines.next()) |line| {
        line_num += 1;

        if (prev_annotation) |ann| {
            if (!is_empty(line)) {
                const next_ann = parse_annotation(line, prefix);

                if (next_ann != null or is_comment(line, prefix)) {
                    // [handle] without function body = read-only, register it.
                    // Other phases without a body are warnings/errors.
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
                        try stderr.print("warning: {s}:{d}: annotation followed by comment, skipping\n", .{ path, ann.line });
                    } else {
                        try stderr.print("error: {s}:{d}: [{s}] .{s} requires a function body\n", .{
                            path, ann.line, user_phase_name(ann.phase), ann.operation,
                        });
                        errors += 1;
                    }
                    prev_annotation = null;

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

    return errors;
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
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--manifest=")) {
            manifest_path = arg[11..];
        }
    }

    var annotations = std.ArrayList(Annotation).init(allocator);
    defer annotations.deinit();

    // File records — kept alive in the arena for status extraction pass.
    const FileRecord = struct { path: []const u8, content: []const u8 };
    var files = std.ArrayList(FileRecord).init(allocator);
    defer files.deinit();

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
        // Content lives in the arena — no free needed, kept for status extraction.

        try files.append(.{ .path = path, .content = content });

        const scan_errors = try scan_file_content(allocator, content, prefix, path, &annotations);
        errors += scan_errors;
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

    // --- Status exhaustiveness check ---
    //
    // For each operation, extract status literals from [handle] body and
    // handled statuses from [render] body. Error if render doesn't cover
    // every status that handle can return. Same check for all languages.
    //
    // op_statuses collects handle statuses for the manifest only —
    // the exhaustiveness check uses local variables directly.
    var op_statuses = std.ArrayList(OperationStatuses).init(allocator);
    defer op_statuses.deinit();

    for (annotations.items) |ann| {
        if (ann.phase != .execute) continue;

        const adapter = find_adapter(ann.file) orelse continue;

        if (!ann.has_body) {
            // Bodyless handle — read-only, only status is ok.
            var ss = StatusSet{};
            ss.add("ok");
            try op_statuses.append(.{ .operation = ann.operation, .statuses = ss });
            continue;
        }

        // File content must exist — stored in the same scan pass that registered this annotation.
        const content = for (files.items) |f| {
            if (std.mem.eql(u8, f.path, ann.file)) break f.content;
        } else unreachable;

        const handle_statuses = extract_statuses_from_handle(content, ann.line, adapter.handle_patterns);
        try op_statuses.append(.{ .operation = ann.operation, .statuses = handle_statuses });

        // Single-status handlers (just ok) don't need a switch in render —
        // there's only one outcome, so the render body handles it implicitly.
        if (handle_statuses.len <= 1) continue;

        // Find the matching [render] annotation for this operation.
        const render_ann = for (annotations.items) |r| {
            if (r.phase == .render and std.mem.eql(u8, r.operation, ann.operation)) break r;
        } else continue; // No render annotation — already caught by exhaustiveness check above.

        if (!render_ann.has_body) continue; // Bodyless render — nothing to check.

        // Render file content must exist — same scan pass stored all file contents.
        const render_content = for (files.items) |f| {
            if (std.mem.eql(u8, f.path, render_ann.file)) break f.content;
        } else unreachable;

        const render_adapter = find_adapter(render_ann.file) orelse continue;
        const render_statuses = extract_statuses_from_body(render_content, render_ann.line, render_adapter.render_patterns);

        // Check: every handle status must be handled in render.
        for (handle_statuses.slice()) |status| {
            if (!has_name(&render_statuses, status)) {
                try stderr.print("error: {s}:{d}: render for .{s} missing status: {s}\n", .{
                    render_ann.file, render_ann.line, ann.operation, status,
                });
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
        try emit_manifest(allocator, out_path, annotations.items, op_statuses.items);
        try stdout.print("Manifest: {s}\n", .{out_path});
    }
}

fn has_name(ss: *const StatusSet, name: []const u8) bool {
    for (ss.slice()) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

/// Write the annotation manifest as JSON.
/// This is the contract between the scanner and language adapters.
fn emit_manifest(
    allocator: std.mem.Allocator,
    out_path: []const u8,
    annotations: []const Annotation,
    op_statuses: []const OperationStatuses,
) !void {
    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();

    try w.writeAll("{\n  \"annotations\": [\n");
    for (annotations, 0..) |ann, i| {
        if (i > 0) try w.writeAll(",\n");
        try w.print("    {{ \"phase\": \"{s}\", \"operation\": \"{s}\", \"file\": \"{s}\", \"line\": {d}, \"has_body\": {s}", .{
            @tagName(ann.phase), ann.operation, ann.file, ann.line, if (ann.has_body) "true" else "false",
        });

        // Include statuses for execute (handle) phase annotations.
        if (ann.phase == .execute) {
            for (op_statuses) |os| {
                if (std.mem.eql(u8, os.operation, ann.operation)) {
                    try w.writeAll(", \"statuses\": [");
                    for (os.statuses.slice(), 0..) |s, j| {
                        if (j > 0) try w.writeAll(", ");
                        try w.print("\"{s}\"", .{s});
                    }
                    try w.writeAll("]");
                    break;
                }
            }
        }

        try w.writeAll(" }");
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

// --- scan_file_content tests ---

fn test_scan(content: []const u8) !struct { annotations: std.ArrayList(Annotation), errors: u32 } {
    var annotations = std.ArrayList(Annotation).init(std.testing.allocator);
    const errors = try scan_file_content(std.testing.allocator, content, "//", "test.zig", &annotations);
    return .{ .annotations = annotations, .errors = errors };
}

fn free_test_scan(result: *std.ArrayList(Annotation)) void {
    for (result.items) |ann| {
        std.testing.allocator.free(ann.operation);
        std.testing.allocator.free(ann.file);
    }
    result.deinit();
}

test "scan: annotation followed by code" {
    var result = try test_scan("// [route] .create_product\npub fn route() void {}\n");
    defer free_test_scan(&result.annotations);

    try std.testing.expectEqual(@as(u32, 0), result.errors);
    try std.testing.expectEqual(@as(usize, 1), result.annotations.items.len);
    try std.testing.expectEqual(Phase.translate, result.annotations.items[0].phase);
    try std.testing.expect(result.annotations.items[0].has_body);
}

test "scan: bodyless handle followed by next annotation" {
    var result = try test_scan(
        \\// [handle] .get_product
        \\// [render] .get_product
        \\pub fn render() void {}
    );
    defer free_test_scan(&result.annotations);

    try std.testing.expectEqual(@as(u32, 0), result.errors);
    try std.testing.expectEqual(@as(usize, 2), result.annotations.items.len);
    // First: handle, bodyless.
    try std.testing.expectEqual(Phase.execute, result.annotations.items[0].phase);
    try std.testing.expect(!result.annotations.items[0].has_body);
    // Second: render, with body.
    try std.testing.expectEqual(Phase.render, result.annotations.items[1].phase);
    try std.testing.expect(result.annotations.items[1].has_body);
}

test "scan: bodyless handle at EOF" {
    var result = try test_scan("// [handle] .get_product\n");
    defer free_test_scan(&result.annotations);

    try std.testing.expectEqual(@as(u32, 0), result.errors);
    try std.testing.expectEqual(@as(usize, 1), result.annotations.items.len);
    try std.testing.expectEqual(Phase.execute, result.annotations.items[0].phase);
    try std.testing.expect(!result.annotations.items[0].has_body);
}

test "scan: non-handle without body followed by annotation is error" {
    var result = try test_scan(
        \\// [route] .get_product
        \\// [prefetch] .get_product
        \\pub fn prefetch() void {}
    );
    defer free_test_scan(&result.annotations);

    // Route without body is an error, prefetch with body succeeds.
    try std.testing.expectEqual(@as(u32, 1), result.errors);
    try std.testing.expectEqual(@as(usize, 1), result.annotations.items.len);
    try std.testing.expectEqual(Phase.prefetch, result.annotations.items[0].phase);
}

test "scan: all 4 phases with bodyless handle" {
    var result = try test_scan(
        \\// [route] .get_product
        \\pub fn route() void {}
        \\
        \\// [prefetch] .get_product
        \\pub fn prefetch() void {}
        \\
        \\// [handle] .get_product
        \\
        \\// [render] .get_product
        \\pub fn render() void {}
    );
    defer free_test_scan(&result.annotations);

    try std.testing.expectEqual(@as(u32, 0), result.errors);
    try std.testing.expectEqual(@as(usize, 4), result.annotations.items.len);
    try std.testing.expectEqual(Phase.translate, result.annotations.items[0].phase);
    try std.testing.expect(result.annotations.items[0].has_body);
    try std.testing.expectEqual(Phase.prefetch, result.annotations.items[1].phase);
    try std.testing.expect(result.annotations.items[1].has_body);
    try std.testing.expectEqual(Phase.execute, result.annotations.items[2].phase);
    try std.testing.expect(!result.annotations.items[2].has_body);
    try std.testing.expectEqual(Phase.render, result.annotations.items[3].phase);
    try std.testing.expect(result.annotations.items[3].has_body);
}

test "scan: handle with body is mutation" {
    var result = try test_scan(
        \\// [handle] .create_product
        \\pub fn handle() void {}
    );
    defer free_test_scan(&result.annotations);

    try std.testing.expectEqual(@as(u32, 0), result.errors);
    try std.testing.expectEqual(@as(usize, 1), result.annotations.items.len);
    try std.testing.expect(result.annotations.items[0].has_body);
}

// --- Status extraction tests ---

test "status: extracts HandleResult literal patterns" {
    const content =
        \\// [handle] .get_product
        \\pub fn handle(ctx: Context, db: anytype) HandleResult {
        \\    _ = db;
        \\    if (ctx.prefetched.product == null)
        \\        return .{ .status = .not_found };
        \\    return .{};
        \\}
    ;
    const ss = extract_statuses_from_handle(content, 1, zig_status_patterns);
    try std.testing.expectEqual(@as(u8, 2), ss.len);
    try std.testing.expect(has_name(&ss, "ok"));
    try std.testing.expect(has_name(&ss, "not_found"));
}

test "status: deduplicates same status" {
    const content =
        \\// [handle] .get_product
        \\pub fn handle(ctx: Context, db: anytype) HandleResult {
        \\    _ = db;
        \\    if (ctx.prefetched.product == null)
        \\        return .{ .status = .not_found };
        \\    if (!ctx.prefetched.product.?.active)
        \\        return .{ .status = .not_found };
        \\    return .{};
        \\}
    ;
    const ss = extract_statuses_from_handle(content, 1, zig_status_patterns);
    try std.testing.expectEqual(@as(u8, 2), ss.len);
}

test "status: always includes ok" {
    const content =
        \\// [handle] .cancel_order
        \\pub fn handle(ctx: Context, db: anytype) HandleResult {
        \\    _ = ctx; _ = db;
        \\    return .{ .status = .not_found };
        \\}
    ;
    const ss = extract_statuses_from_handle(content, 1, zig_status_patterns);
    try std.testing.expect(has_name(&ss, "ok"));
    try std.testing.expect(has_name(&ss, "not_found"));
}

test "status: multiple distinct statuses" {
    const content =
        \\// [handle] .create_order
        \\pub fn handle(ctx: Context, db: anytype) HandleResult {
        \\    if (missing) return .{ .status = .not_found };
        \\    if (low) return .{ .status = .insufficient_inventory };
        \\    db.execute(sql.products.update, .{ params });
        \\    return .{};
        \\}
    ;
    const ss = extract_statuses_from_handle(content, 1, zig_status_patterns);
    try std.testing.expectEqual(@as(u8, 3), ss.len);
    try std.testing.expect(has_name(&ss, "ok"));
    try std.testing.expect(has_name(&ss, "not_found"));
    try std.testing.expect(has_name(&ss, "insufficient_inventory"));
}

test "status: session_action variant still extracts ok" {
    const content =
        \\// [handle] .logout
        \\pub fn handle(ctx: Context, db: anytype) HandleResult {
        \\    _ = ctx; _ = db;
        \\    return .{ .session_action = .clear };
        \\}
    ;
    // .session_action = .clear doesn't match status patterns, but ok is always added.
    const ss = extract_statuses_from_handle(content, 1, zig_status_patterns);
    try std.testing.expectEqual(@as(u8, 1), ss.len);
    try std.testing.expect(has_name(&ss, "ok"));
}

test "status: TypeScript pattern" {
    const content =
        \\// [handle] .get_product
        \\export function handle(ctx) {
        \\    if (!ctx.prefetched.product)
        \\        return { status: "not_found", writes: [] };
        \\    return { status: "ok", writes: [] };
        \\}
    ;
    const ss = extract_statuses_from_handle(content, 1, ts_status_patterns);
    try std.testing.expectEqual(@as(u8, 2), ss.len);
    try std.testing.expect(has_name(&ss, "ok"));
    try std.testing.expect(has_name(&ss, "not_found"));
}

test "status: no body (no brace) still returns ok" {
    const content = "// [handle] .get_product\n";
    const ss = extract_statuses_from_handle(content, 1, zig_status_patterns);
    try std.testing.expectEqual(@as(u8, 1), ss.len);
    try std.testing.expect(has_name(&ss, "ok"));
}

test "status: StatusSet deduplication" {
    var ss = StatusSet{};
    ss.add("ok");
    ss.add("not_found");
    ss.add("ok"); // duplicate
    ss.add("not_found"); // duplicate
    try std.testing.expectEqual(@as(u8, 2), ss.len);
}

// --- Render extraction tests ---

test "render: extracts Zig switch arms" {
    const content =
        \\// [render] .get_product
        \\pub fn render(ctx: Context) []const u8 {
        \\    return switch (ctx.status) {
        \\        .ok => render_product(ctx),
        \\        .not_found => "<div>Not found</div>",
        \\    };
        \\}
    ;
    const ss = extract_statuses_from_body(content, 1, zig_adapter.render_patterns);
    try std.testing.expectEqual(@as(u8, 2), ss.len);
    try std.testing.expect(has_name(&ss, "ok"));
    try std.testing.expect(has_name(&ss, "not_found"));
}

test "render: extracts TS case statements" {
    const content =
        \\// [render] .get_product
        \\export function render(ctx) {
        \\    switch (ctx.status) {
        \\        case "ok": return renderProduct(ctx);
        \\        case "not_found": return "<div>Not found</div>";
        \\    }
        \\}
    ;
    const ss = extract_statuses_from_body(content, 1, ts_adapter.render_patterns);
    try std.testing.expectEqual(@as(u8, 2), ss.len);
    try std.testing.expect(has_name(&ss, "ok"));
    try std.testing.expect(has_name(&ss, "not_found"));
}

test "render: suffix rejects non-switch-arm dots" {
    const content =
        \\// [render] .get_product
        \\pub fn render(ctx: Context) []const u8 {
        \\    const product = ctx.prefetched.product;
        \\    return switch (ctx.status) {
        \\        .ok => render_product(ctx),
        \\    };
        \\}
    ;
    const ss = extract_statuses_from_body(content, 1, zig_adapter.render_patterns);
    // .product and .prefetched should NOT be extracted — no "=>" suffix.
    // Only .ok should match.
    try std.testing.expectEqual(@as(u8, 1), ss.len);
    try std.testing.expect(has_name(&ss, "ok"));
}

// --- Integration test: scanner vs real handlers ---
//
// Reads every handler file from disk, extracts handle statuses using the
// scanner's patterns, and verifies they match the declared Status enum.
// Catches pattern regressions that unit tests with synthetic content miss.

test "integration: extracted handle statuses match declared Status enum" {
    const allocator = std.testing.allocator;

    // Read handler directory.
    var dir = try std.fs.cwd().openDir("handlers", .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var checked: u32 = 0;

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const content = try dir.readFileAlloc(allocator, entry.path, 1024 * 1024);
        defer allocator.free(content);

        // Find the [handle] annotation line.
        var handle_line: ?u32 = null;
        var line_num: u32 = 0;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            line_num += 1;
            if (parse_annotation(line, "//")) |ann| {
                if (ann.phase == .execute) handle_line = line_num;
            }
        }
        const start_line = handle_line orelse continue;

        // Extract statuses from handle body.
        const extracted = extract_statuses_from_handle(content, start_line, zig_adapter.handle_patterns);

        // Parse declared Status enum from "pub const Status = enum { ... };".
        var declared = StatusSet{};
        var decl_lines = std.mem.splitScalar(u8, content, '\n');
        while (decl_lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (std.mem.startsWith(u8, trimmed, "pub const Status = enum {")) {
                // Extract variants from "pub const Status = enum { ok, not_found };"
                const start = std.mem.indexOf(u8, trimmed, "{").? + 1;
                const end = std.mem.indexOf(u8, trimmed, "}").?;
                var variants = std.mem.splitScalar(u8, trimmed[start..end], ',');
                while (variants.next()) |v| {
                    const name = std.mem.trim(u8, v, " \t");
                    if (name.len > 0) declared.add(name);
                }
                break;
            }
        }

        // declared must have at least ok.
        assert(declared.len >= 1);
        assert(has_name(&declared, "ok"));

        // Every declared status must be in the extracted set.
        for (declared.slice()) |status| {
            if (!has_name(&extracted, status)) {
                std.debug.panic(
                    "handler {s}: declared status '{s}' not found by scanner extraction",
                    .{ entry.basename, status },
                );
            }
        }

        // Every extracted status must be in the declared set.
        for (extracted.slice()) |status| {
            if (!has_name(&declared, status)) {
                std.debug.panic(
                    "handler {s}: scanner extracted '{s}' but it's not in declared Status enum",
                    .{ entry.basename, status },
                );
            }
        }

        checked += 1;
    }

    // Must have checked all 24 handlers.
    try std.testing.expectEqual(@as(u32, 24), checked);
}

test "render: Zig multi-status with other switches" {
    const content =
        \\// [render] .complete_order
        \\pub fn render(ctx: Context, db: anytype) []const u8 {
        \\    switch (ctx.status) {
        \\        .not_found => return "<div>Not found</div>",
        \\        .ok => {},
        \\    }
        \\    pos += h.raw(buf[pos..], switch (order.status) {
        \\        .pending => "Pending",
        \\        .confirmed => "Confirmed",
        \\        .failed => "Failed",
        \\        .cancelled => "Cancelled",
        \\    });
        \\    return buf[0..pos];
        \\}
    ;
    const ss = extract_statuses_from_body(content, 1, zig_adapter.render_patterns);
    // Picks up all switch arms: ok, not_found, pending, confirmed, failed, cancelled.
    // The exhaustiveness check only looks for handle statuses in this set,
    // so extra statuses from other switches are harmless.
    try std.testing.expect(has_name(&ss, "ok"));
    try std.testing.expect(has_name(&ss, "not_found"));
    try std.testing.expect(has_name(&ss, "pending"));
}
