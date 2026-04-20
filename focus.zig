//! Focus CLI — single Zig binary for project scaffolding, build, and dev.
//!
//! Replaces the shell scripts (focus, focus-internal). All tooling
//! centralized in Zig per TB's principle: "Bash is not cross platform,
//! suffers from high accidental complexity, and is a second language."
//!
//! Subcommands:
//!   new --ts <name>    Scaffold a TypeScript project
//!   build <path>       Scan annotations + generate dispatch
//!   dev <path>         Build + server + sidecar + watch + reload
//!   schema <args>      Apply/reset database schema
//!   docs               Print framework reference

const std = @import("std");
const stdx = @import("stdx");
const Shell = @import("shell.zig");

pub const std_options: std.Options = .{ .log_level = .info };

const CLIArgs = union(enum) {
    new: NewArgs,
    build: BuildArgs,
    // dev: DevArgs,     // TODO: implement
    // schema: SchemaArgs, // exists in main.zig, expose here
    // docs: void,       // TODO: @embedFile reference

    pub const help =
        \\Usage:
        \\  focus new --ts <name>    Scaffold a TypeScript project
        \\  focus build <path>       Scan annotations + generate dispatch
        \\  focus dev <path>         Build + server + sidecar + watch + reload
        \\  focus schema <args>      Apply/reset database schema
        \\  focus docs               Print framework reference
        \\
    ;
};

const NewArgs = struct {
    ts: bool = false,
    // go: bool = false,  // future
    // py: bool = false,  // future
    /// Positional: project name
    @"--": void,
    name: []const u8,
};

const BuildArgs = struct {
    /// Positional: handler source path
    @"--": void,
    path: []const u8,
};

pub fn main() !void {
    var gpa_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer switch (gpa_allocator.deinit()) {
        .ok => {},
        .leak => @panic("memory leak"),
    };
    const gpa = gpa_allocator.allocator();

    var args = try std.process.argsWithAllocator(gpa);
    defer args.deinit();

    const cli = stdx.flags(&args, CLIArgs);

    switch (cli) {
        .new => |new_args| try cmd_new(new_args),
        .build => |build_args| {
            const shell = Shell.create(gpa) catch {
                std.io.getStdErr().writer().print("error: must run from within a focus project (no build.zig found)\n", .{}) catch {};
                std.process.exit(1);
            };
            defer shell.destroy();
            try cmd_build(shell, build_args);
        },
    }
}

// =============================================================
// focus new
// =============================================================

fn cmd_new(args: NewArgs) !void {
    if (!args.ts) {
        std.io.getStdErr().writer().print("error: specify a language: --ts\n", .{}) catch {};
        std.process.exit(1);
    }

    const name = args.name;
    const stdout = std.io.getStdOut().writer();

    // Create project directory.
    std.fs.cwd().makeDir(name) catch |err| {
        if (err == error.PathAlreadyExists) {
            stdout.print("error: '{s}' already exists.\n", .{name}) catch {};
            std.process.exit(1);
        }
        return err;
    };

    // Write template files.
    const templates = .{
        .{ "schema.sql", @embedFile("templates/ts/schema.sql") },
        .{ ".focus", @embedFile("templates/ts/dot-focus") },
        .{ ".gitignore", @embedFile("templates/ts/dot-gitignore") },
        .{ "package.json", @embedFile("templates/ts/package.json") },
        .{ "tsconfig.json", @embedFile("templates/ts/tsconfig.json") },
        .{ "src/list_items.ts", @embedFile("templates/ts/src/list_items.ts") },
        .{ "src/create_item.ts", @embedFile("templates/ts/src/create_item.ts") },
    };

    const dir = try std.fs.cwd().openDir(name, .{});
    dir.makeDir("src") catch {};

    inline for (templates) |t| {
        const path = t[0];
        const content = t[1];
        if (std.mem.indexOfScalar(u8, path, '/')) |_| {
            // Has subdirectory — already created above.
        }
        const file = try dir.createFile(path, .{});
        defer file.close();
        try file.writeAll(content);
    }


    try stdout.print(
        \\
        \\  Created {s}/
        \\
        \\  Next steps:
        \\    cd {s}
        \\    focus dev src/
        \\
        \\
    , .{ name, name });
}

// =============================================================
// focus build
// =============================================================

fn cmd_build(shell: *Shell, args: BuildArgs) !void {
    const path = args.path;
    const stdout = std.io.getStdOut().writer();

    // Step 1: Run the annotation scanner.
    try shell.exec(
        "./zig/zig build scan -- {path} --manifest=generated/manifest.json --registry=generated/operations.json --operations-zig=generated/operations.generated.zig --routes-zig=generated/routes.generated.zig",
        .{ .path = path },
    );

    // Step 2: Run the TypeScript adapter (codegen).
    // TODO: read build hook from .focus file instead of hardcoding tsx.
    try shell.exec(
        "npx tsx adapters/typescript.ts generated/manifest.json generated/handlers.generated.ts generated/operations.json generated/operations.ts",
        .{},
    );

    try stdout.print("Build complete.\n", .{});
}
