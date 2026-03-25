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

/// Parsed route match directive — `// match GET /products/:id`.
const RouteMatch = struct {
    method: Method,
    pattern: []const u8,
    line: u32,

    /// HTTP methods recognized in match directives. Superset of
    /// framework's http.Method — the scanner accepts PATCH even though
    /// the framework parser doesn't (yet). Comptime assertion below
    /// verifies the framework's methods are a subset.
    const Method = enum { get, post, put, delete, patch };

    /// Free the duped pattern. Single free site for the single dupe site.
    fn deinit(self: RouteMatch, allocator: std.mem.Allocator) void {
        allocator.free(self.pattern);
    }
};

const http = @import("tiger_framework").http;
comptime {
    // Every framework HTTP method must exist in RouteMatch.Method.
    // If the framework adds a method, the scanner must recognize it.
    for (@typeInfo(http.Method).@"enum".fields) |f| {
        assert(@hasField(RouteMatch.Method, f.name));
    }
}

/// A registered annotation with its source location.
const Annotation = struct {
    phase: Phase,
    operation: []const u8,
    file: []const u8,
    line: u32,
    has_body: bool,
    route_match: ?RouteMatch = null,
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

/// Parse a match directive from a comment line.
/// Format: `{prefix} match {METHOD} {/path/pattern}`
/// Returns null if the line is not a match directive.
fn parse_match_directive(line: []const u8, prefix: []const u8) ?struct { method: RouteMatch.Method, pattern: []const u8 } {
    var trimmed = line;
    while (trimmed.len > 0 and (trimmed[0] == ' ' or trimmed[0] == '\t')) {
        trimmed = trimmed[1..];
    }

    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    var rest = trimmed[prefix.len..];

    while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];

    if (!std.mem.startsWith(u8, rest, "match ")) return null;
    rest = rest[6..];

    while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];

    // Parse HTTP method.
    const method_end = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const method_str = rest[0..method_end];
    const method: RouteMatch.Method =
        if (std.ascii.eqlIgnoreCase(method_str, "GET")) .get
        else if (std.ascii.eqlIgnoreCase(method_str, "POST")) .post
        else if (std.ascii.eqlIgnoreCase(method_str, "PUT")) .put
        else if (std.ascii.eqlIgnoreCase(method_str, "DELETE")) .delete
        else if (std.ascii.eqlIgnoreCase(method_str, "PATCH")) .patch
        else return null;

    rest = rest[method_end..];
    while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];

    // Parse path pattern — must start with /.
    if (rest.len == 0 or rest[0] != '/') return null;

    // Trim trailing whitespace.
    var pattern_end = rest.len;
    while (pattern_end > 0 and (rest[pattern_end - 1] == ' ' or rest[pattern_end - 1] == '\t' or rest[pattern_end - 1] == '\r')) {
        pattern_end -= 1;
    }
    if (pattern_end == 0) return null;

    return .{ .method = method, .pattern = rest[0..pattern_end] };
}

/// Validate a route pattern's structure. Returns an error message or null if valid.
/// Rules:
///   - Must start with /
///   - Segments between / must be non-empty (no //)
///   - Param names after : must be non-empty identifiers
///   - No trailing slash (except root /)
fn validate_route_pattern(pattern: []const u8) ?[]const u8 {
    if (pattern.len == 0) return "empty pattern";
    if (pattern[0] != '/') return "must start with /";
    if (pattern.len == 1) return null; // root "/" is valid

    // No trailing slash.
    if (pattern[pattern.len - 1] == '/') return "trailing slash";

    // Walk segments.
    var pos: usize = 1; // skip leading /
    while (pos < pattern.len) {
        const next_slash = std.mem.indexOfScalarPos(u8, pattern, pos, '/');
        const seg_end = next_slash orelse pattern.len;
        const segment = pattern[pos..seg_end];

        if (segment.len == 0) return "empty segment (double slash)";

        // If segment starts with :, validate param name.
        if (segment[0] == ':') {
            if (segment.len == 1) return "empty param name after :";
            for (segment[1..]) |ch| {
                if (!std.ascii.isAlphanumeric(ch) and ch != '_') return "invalid character in param name";
            }
        }

        pos = if (next_slash) |s| s + 1 else pattern.len;
    }

    return null;
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
    sql_quote: u8 = '"', // quote character for SQL string literals
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
///
/// All string fields on Annotation (operation, file, route_match.pattern)
/// are duped via the allocator. In main() this is an arena — no individual
/// frees needed. In tests, std.testing.allocator catches leaks.
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
    var pending_match: ?RouteMatch = null;

    while (lines.next()) |line| {
        line_num += 1;

        if (prev_annotation) |ann| {
            if (!is_empty(line)) {
                const next_ann = parse_annotation(line, prefix);

                if (next_ann != null or is_comment(line, prefix)) {
                    // Check for `// match` directive between [route] and function body.
                    if (ann.phase == .translate and next_ann == null) {
                        if (parse_match_directive(line, prefix)) |m| {
                            if (pending_match != null) {
                                try stderr.print("error: {s}:{d}: duplicate match directive for [route] .{s}\n", .{ path, line_num, ann.operation });
                                errors += 1;
                            } else if (validate_route_pattern(m.pattern)) |err| {
                                try stderr.print("error: {s}:{d}: invalid route pattern '{s}': {s}\n", .{ path, line_num, m.pattern, err });
                                errors += 1;
                            } else {
                                pending_match = .{
                                    .method = m.method,
                                    .pattern = try allocator.dupe(u8, m.pattern),
                                    .line = line_num,
                                };
                            }
                            continue; // Stay in prev_annotation state, wait for function body.
                        }
                    }

                    // `// match` on non-route phases is an error.
                    if (ann.phase != .translate and next_ann == null) {
                        if (parse_match_directive(line, prefix) != null) {
                            try stderr.print("error: {s}:{d}: match directive only valid after [route], not [{s}]\n", .{ path, line_num, user_phase_name(ann.phase) });
                            errors += 1;
                            prev_annotation = null;
                            pending_match = null;
                            continue;
                        }
                    }

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
                    if (pending_match) |rm| rm.deinit(allocator);
                    pending_match = null;

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
                            .route_match = pending_match,
                        });
                    }
                    prev_annotation = null;
                    pending_match = null;
                    continue;
                }
            } else {
                continue;
            }
        } else {
            if (parse_annotation(line, prefix)) |ann| {
                prev_annotation = .{ .phase = ann.phase, .operation = ann.operation, .line = line_num };
            } else if (parse_match_directive(line, prefix) != null) {
                // match directive outside any annotation.
                try stderr.print("error: {s}:{d}: match directive without preceding [route] annotation\n", .{ path, line_num });
                errors += 1;
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
        // Free pending match if it was duped but never stored on an annotation.
        if (pending_match) |rm| rm.deinit(allocator);
        pending_match = null;
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

    // Check for duplicate route patterns — two operations claiming the same URL.
    for (annotations.items, 0..) |a, i| {
        const a_match = a.route_match orelse continue;
        for (annotations.items[i + 1 ..]) |b| {
            const b_match = b.route_match orelse continue;
            if (a_match.method == b_match.method and std.mem.eql(u8, a_match.pattern, b_match.pattern)) {
                try stderr.print("error: duplicate route pattern {s} {s}\n  --> {s}:{d} (.{s})\n  --> {s}:{d} (.{s})\n", .{
                    @tagName(a_match.method), a_match.pattern,
                    a.file, a_match.line, a.operation,
                    b.file, b_match.line, b.operation,
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

    // --- SQL validation ---
    //
    // Extract SQL string literals from prefetch/handle/render bodies.
    // Prefetch and render must be SELECT. Handle must be INSERT/UPDATE/DELETE.
    // Build-time enforcement of read/write separation — same guarantee as
    // Zig-native ReadView/WriteView but via source text scanning.
    for (annotations.items) |ann| {
        if (!ann.has_body) continue;

        const content = for (files.items) |f| {
            if (std.mem.eql(u8, f.path, ann.file)) break f.content;
        } else continue;

        const adapter = find_adapter(ann.file) orelse continue;
        const quote = adapter.sql_quote;

        switch (ann.phase) {
            .prefetch => {
                var sql_iter = SqlStringIterator.init(content, ann.line, quote);
                while (sql_iter.next()) |sql| {
                    if (!sql_starts_with_select(sql)) {
                        try stderr.print("error: {s}:{d}: [prefetch] .{s} SQL must be SELECT: \"{s}...\"\n", .{
                            ann.file, ann.line, ann.operation, sql_preview(sql),
                        });
                        errors += 1;
                    }
                }
            },
            .execute => {
                var sql_iter = SqlStringIterator.init(content, ann.line, quote);
                while (sql_iter.next()) |sql| {
                    if (!sql_starts_with_write(sql)) {
                        try stderr.print("error: {s}:{d}: [handle] .{s} SQL must be INSERT/UPDATE/DELETE: \"{s}...\"\n", .{
                            ann.file, ann.line, ann.operation, sql_preview(sql),
                        });
                        errors += 1;
                    }
                }
            },
            .render => {
                var sql_iter = SqlStringIterator.init(content, ann.line, quote);
                while (sql_iter.next()) |sql| {
                    if (!sql_starts_with_select(sql)) {
                        try stderr.print("error: {s}:{d}: [render] .{s} SQL must be SELECT: \"{s}...\"\n", .{
                            ann.file, ann.line, ann.operation, sql_preview(sql),
                        });
                        errors += 1;
                    }
                }
            },
            .translate => {}, // Route has no SQL.
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

// =====================================================================
// SQL string validation — extract SQL literals, check first keyword
// =====================================================================

/// Iterator over SQL string literals in a function body.
/// Scans for quoted strings that look like SQL — first keyword is
/// a SQL verb (SELECT, INSERT, etc.). Skips status names, HTML, etc.
/// Scoped to the function body (opening `{` to matching `}`).
const SqlStringIterator = struct {
    body: []const u8,
    pos: usize,
    quote: u8,

    fn init(content: []const u8, start_line: u32, quote: u8) SqlStringIterator {
        // Advance to start_line.
        var pos: usize = 0;
        var line: u32 = 1;
        while (pos < content.len and line < start_line) : (pos += 1) {
            if (content[pos] == '\n') line += 1;
        }
        // Find opening brace and extract body by depth.
        const brace_start = std.mem.indexOfScalar(u8, content[pos..], '{') orelse
            return .{ .body = "", .pos = 0, .quote = quote };
        const body_start = pos + brace_start + 1;
        var depth: u32 = 1;
        var bpos = body_start;
        while (bpos < content.len and depth > 0) : (bpos += 1) {
            if (content[bpos] == '{') depth += 1;
            if (content[bpos] == '}') depth -= 1;
        }
        return .{ .body = content[body_start..bpos], .pos = 0, .quote = quote };
    }

    fn next(self: *SqlStringIterator) ?[]const u8 {
        while (self.pos < self.body.len) {
            // Find next quote.
            const start = std.mem.indexOfScalarPos(u8, self.body, self.pos, self.quote) orelse return null;
            self.pos = start + 1;

            // Find closing quote (skip escaped quotes).
            var end = self.pos;
            while (end < self.body.len) : (end += 1) {
                if (self.body[end] == '\\') {
                    end += 1;
                    continue;
                }
                if (self.body[end] == self.quote) break;
            }
            if (end >= self.body.len) return null;

            const str = self.body[self.pos..end];
            self.pos = end + 1;

            // Only return strings that look like SQL — start with a letter
            // and first word is a SQL keyword. Skip status names, HTML, etc.
            const first_word = sql_first_keyword(str) orelse continue;
            if (is_sql_keyword(first_word)) return str;
        }
        return null;
    }
};

/// Extract the first whitespace-delimited word from a SQL string.
fn sql_first_keyword(sql: []const u8) ?[]const u8 {
    // Skip leading whitespace.
    var start: usize = 0;
    while (start < sql.len and (sql[start] == ' ' or sql[start] == '\t' or sql[start] == '\n')) start += 1;
    if (start >= sql.len) return null;

    // Find end of first word.
    var end = start;
    while (end < sql.len and sql[end] != ' ' and sql[end] != '\t' and sql[end] != '\n') end += 1;
    return sql[start..end];
}

/// Check if a word is a known SQL keyword (case-insensitive).
fn is_sql_keyword(word: []const u8) bool {
    const keywords = [_][]const u8{ "SELECT", "INSERT", "UPDATE", "DELETE", "select", "insert", "update", "delete" };
    for (keywords) |kw| {
        if (std.ascii.eqlIgnoreCase(word, kw)) return true;
    }
    return false;
}

fn sql_starts_with_select(sql: []const u8) bool {
    const kw = sql_first_keyword(sql) orelse return false;
    return std.ascii.eqlIgnoreCase(kw, "SELECT");
}

fn sql_starts_with_write(sql: []const u8) bool {
    const kw = sql_first_keyword(sql) orelse return false;
    return std.ascii.eqlIgnoreCase(kw, "INSERT") or
        std.ascii.eqlIgnoreCase(kw, "UPDATE") or
        std.ascii.eqlIgnoreCase(kw, "DELETE");
}

fn sql_preview(sql: []const u8) []const u8 {
    return sql[0..@min(sql.len, 40)];
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

// --- parse_match_directive tests ---

test "match: valid GET" {
    const result = parse_match_directive("// match GET /products/:id", "//");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(result.?.method, .get);
    try std.testing.expect(std.mem.eql(u8, result.?.pattern, "/products/:id"));
}

test "match: valid POST with sub-resource" {
    const result = parse_match_directive("// match POST /orders/:id/complete", "//");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(result.?.method, .post);
    try std.testing.expect(std.mem.eql(u8, result.?.pattern, "/orders/:id/complete"));
}

test "match: valid DELETE" {
    const result = parse_match_directive("// match DELETE /products/:id", "//");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(result.?.method, .delete);
}

test "match: case insensitive method" {
    const result = parse_match_directive("// match get /products", "//");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(result.?.method, .get);
}

test "match: root path" {
    const result = parse_match_directive("// match GET /", "//");
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.eql(u8, result.?.pattern, "/"));
}

test "match: python style" {
    const result = parse_match_directive("# match GET /products/:id", "#");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(result.?.method, .get);
}

test "match: rejects missing method" {
    try std.testing.expect(parse_match_directive("// match /products/:id", "//") == null);
}

test "match: rejects invalid method" {
    try std.testing.expect(parse_match_directive("// match TRACE /products", "//") == null);
}

test "match: rejects missing path" {
    try std.testing.expect(parse_match_directive("// match GET", "//") == null);
}

test "match: rejects path without leading slash" {
    try std.testing.expect(parse_match_directive("// match GET products/:id", "//") == null);
}

test "match: rejects non-match comment" {
    try std.testing.expect(parse_match_directive("// some comment", "//") == null);
}

test "match: rejects plain code" {
    try std.testing.expect(parse_match_directive("pub fn route() void {}", "//") == null);
}

test "match: leading whitespace" {
    const result = parse_match_directive("  // match GET /products", "//");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(result.?.method, .get);
}

// --- validate_route_pattern tests ---

test "pattern: valid paths" {
    try std.testing.expect(validate_route_pattern("/") == null);
    try std.testing.expect(validate_route_pattern("/products") == null);
    try std.testing.expect(validate_route_pattern("/products/:id") == null);
    try std.testing.expect(validate_route_pattern("/orders/:id/complete") == null);
    try std.testing.expect(validate_route_pattern("/go/:slug") == null);
}

test "pattern: rejects empty" {
    try std.testing.expect(validate_route_pattern("") != null);
}

test "pattern: rejects no leading slash" {
    try std.testing.expect(validate_route_pattern("products") != null);
}

test "pattern: rejects trailing slash" {
    try std.testing.expect(validate_route_pattern("/products/") != null);
}

test "pattern: rejects double slash" {
    try std.testing.expect(validate_route_pattern("/products//list") != null);
}

test "pattern: rejects empty param name" {
    try std.testing.expect(validate_route_pattern("/products/:") != null);
}

test "pattern: rejects invalid param characters" {
    try std.testing.expect(validate_route_pattern("/products/:id-name") != null);
    try std.testing.expect(validate_route_pattern("/products/:id.format") != null);
}

test "pattern: accepts underscore in param" {
    try std.testing.expect(validate_route_pattern("/products/:product_id") == null);
}

test "match: PUT and PATCH" {
    const put = parse_match_directive("// match PUT /products/:id", "//");
    try std.testing.expect(put != null);
    try std.testing.expectEqual(put.?.method, .put);

    const patch = parse_match_directive("// match PATCH /products/:id", "//");
    try std.testing.expect(patch != null);
    try std.testing.expectEqual(patch.?.method, .patch);
}

// --- scan_file_content tests (match integration) ---

test "scan: route with match directive" {
    var result = try test_scan(
        \\// [route] .get_product
        \\// match GET /products/:id
        \\pub fn route() void {}
    );
    defer free_test_scan(&result.annotations);

    try std.testing.expectEqual(@as(u32, 0), result.errors);
    try std.testing.expectEqual(@as(usize, 1), result.annotations.items.len);
    try std.testing.expectEqual(Phase.translate, result.annotations.items[0].phase);
    try std.testing.expect(result.annotations.items[0].has_body);
    try std.testing.expect(result.annotations.items[0].route_match != null);
    try std.testing.expectEqual(result.annotations.items[0].route_match.?.method, .get);
    try std.testing.expect(std.mem.eql(u8, result.annotations.items[0].route_match.?.pattern, "/products/:id"));
}

test "scan: route without match directive" {
    var result = try test_scan(
        \\// [route] .get_product
        \\pub fn route() void {}
    );
    defer free_test_scan(&result.annotations);

    try std.testing.expectEqual(@as(u32, 0), result.errors);
    try std.testing.expectEqual(@as(usize, 1), result.annotations.items.len);
    try std.testing.expect(result.annotations.items[0].route_match == null);
}

test "scan: match directive on non-route phase is error" {
    var result = try test_scan(
        \\// [handle] .get_product
        \\// match GET /products/:id
        \\pub fn handle() void {}
    );
    defer free_test_scan(&result.annotations);

    try std.testing.expectEqual(@as(u32, 1), result.errors);
}

test "scan: match directive without annotation is error" {
    var result = try test_scan(
        \\// match GET /products/:id
        \\pub fn route() void {}
    );
    defer free_test_scan(&result.annotations);

    try std.testing.expectEqual(@as(u32, 1), result.errors);
}

test "scan: duplicate match directive is error" {
    var result = try test_scan(
        \\// [route] .get_product
        \\// match GET /products/:id
        \\// match POST /products
        \\pub fn route() void {}
    );
    defer free_test_scan(&result.annotations);

    try std.testing.expectEqual(@as(u32, 1), result.errors);
}

test "scan: invalid route pattern is error" {
    var result = try test_scan(
        \\// [route] .get_product
        \\// match GET /products//list
        \\pub fn route() void {}
    );
    defer free_test_scan(&result.annotations);

    try std.testing.expectEqual(@as(u32, 1), result.errors);
    // Invalid pattern — annotation registered without route_match.
    try std.testing.expectEqual(@as(usize, 1), result.annotations.items.len);
    try std.testing.expect(result.annotations.items[0].route_match == null);
}

test "scan: route with match followed by another annotation does not leak" {
    var result = try test_scan(
        \\// [route] .get_product
        \\// match GET /products/:id
        \\// [prefetch] .get_product
        \\pub fn prefetch() void {}
    );
    defer free_test_scan(&result.annotations);

    // Route had no body — error. Match pattern must be freed.
    try std.testing.expect(result.errors > 0);
}

test "scan: route with match at EOF does not leak" {
    var result = try test_scan(
        \\// [route] .get_product
        \\// match GET /products/:id
    );
    defer free_test_scan(&result.annotations);

    // No function body follows — warning, no registration.
    // The duped pattern must be freed (std.testing.allocator catches leaks).
    try std.testing.expectEqual(@as(usize, 0), result.annotations.items.len);
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
        if (ann.route_match) |rm| rm.deinit(std.testing.allocator);
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

        // Cross-check: if handler exports route_method/route_pattern consts,
        // verify they match the // match annotation. Pair assertion: annotation
        // is the scanner's source of truth, const is the compiler's. They must agree.
        var ann_match: ?struct { method: []const u8, pattern: []const u8 } = null;
        var match_lines = std.mem.splitScalar(u8, content, '\n');
        while (match_lines.next()) |mline| {
            if (parse_match_directive(mline, "//")) |m| {
                ann_match = .{ .method = @tagName(m.method), .pattern = m.pattern };
                break;
            }
        }

        // Check route_method const matches annotation method.
        const has_method_const = std.mem.indexOf(u8, content, "pub const route_method") != null;
        const has_pattern_const = std.mem.indexOf(u8, content, "pub const route_pattern") != null;

        if (has_method_const != has_pattern_const) {
            std.debug.panic(
                "handler {s}: has route_method but not route_pattern (or vice versa)",
                .{entry.basename},
            );
        }

        if (has_method_const and ann_match == null) {
            std.debug.panic(
                "handler {s}: exports route_method/route_pattern but has no // match annotation",
                .{entry.basename},
            );
        }

        if (has_method_const) {
            const ann = ann_match.?;
            // Verify method const matches annotation.
            // e.g. "pub const route_method = t.http.Method.get;" must match "// match GET ..."
            const method_line_start = std.mem.indexOf(u8, content, "pub const route_method").?;
            const method_line_end = std.mem.indexOfPos(u8, content, method_line_start, ";").?;
            const method_line = content[method_line_start..method_line_end];
            if (std.mem.indexOf(u8, method_line, ann.method) == null) {
                std.debug.panic(
                    "handler {s}: route_method const doesn't match // match annotation method '{s}'",
                    .{ entry.basename, ann.method },
                );
            }

            // Verify pattern const matches annotation.
            const pattern_line_start = std.mem.indexOf(u8, content, "pub const route_pattern").?;
            const pattern_line_end = std.mem.indexOfPos(u8, content, pattern_line_start, ";").?;
            const pattern_line = content[pattern_line_start..pattern_line_end];
            if (std.mem.indexOf(u8, pattern_line, ann.pattern) == null) {
                std.debug.panic(
                    "handler {s}: route_pattern const doesn't match // match annotation pattern '{s}'",
                    .{ entry.basename, ann.pattern },
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
