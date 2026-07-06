//! Command hcc is the HolyC compiler driver: it runs the front end (lex →
//! preprocess with the resident prelude → parse → check → layout) and hands
//! the result to the LLVM backend.
//!
//! Usage:
//!
//!   hcc [--target <triple>] [--emit <kind>] [-o <out>] <input.HC>...
//!
//! The target defaults to the host machine; pass --target to cross-compile.
//! --emit selects the output: exe (default), obj, shared, check (diagnostics
//! only), or ast (dump the checked AST).

const std = @import("std");
const hcc = @import("hcc");
const llvm = @import("llvm");

const usage_text =
    \\Usage: hcc [--target <triple>] [--emit <kind>] [-o <out>] <input.HC>...
    \\
    \\Compile HolyC source. The front end (lex, preprocess with the resident
    \\prelude, parse, check, layout) runs fully; code generation goes through
    \\LLVM and links with the host C toolchain.
    \\
    \\Flags:
    \\  --target <triple>  target to compile for, e.g. arm64-apple-darwin or
    \\                     x86_64-unknown-linux-gnu (defaults to the host)
    \\  --emit <kind>      output kind: exe (default), obj (relocatable .o),
    \\                     shared (shared library), check (run the front end and
    \\                     print diagnostics only), or ast (dump the checked AST)
    \\  -o <out>           output path (defaults derive from the first input)
    \\  -l <name>          link against library <name> (repeatable), so `extern`
    \\                     imports resolve against it; libc is always linked
    \\  -L <dir>           add a library search directory (repeatable)
    \\  --cc <driver>      C compiler driver for the link step (or HCC_CC).
    \\                     Default: the system `cc` for the host target; for a
    \\                     cross target, `zig cc -target <triple>`
    \\  -h, --help         print this help
    \\
;

const EmitKind = enum { exe, obj, shared, check, ast };

const Cli = struct {
    target: hcc.target.Target,
    emit: EmitKind = .exe,
    out: ?[]const u8 = null,
    inputs: []const []const u8 = &.{},
    /// Libraries (-l) and search dirs (-L) forwarded to the link step, so
    /// `extern` imports can resolve against any shared library.
    libs: []const []const u8 = &.{},
    lib_dirs: []const []const u8 = &.{},
    /// Explicit link driver (--cc flag or HCC_CC); null picks the default
    /// (host `cc`, or `zig cc` for a cross target).
    cc: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    var cli = parseArgs(arena, io, init.minimal.args, stderr) catch |e| switch (e) {
        error.Usage => {
            try stderr.flush();
            std.process.exit(2);
        },
        error.HelpShown => return,
        else => return e,
    };
    if (cli.cc == null) cli.cc = init.environ_map.get("HCC_CC");

    const ok = try run(arena, io, cli, stderr);
    try stderr.flush();
    if (!ok) std.process.exit(1);
}

fn parseArgs(arena: std.mem.Allocator, io: std.Io, argv: std.process.Args, stderr: *std.Io.Writer) !Cli {
    var cli: Cli = .{ .target = hcc.target.Target.host() };
    var inputs: std.ArrayList([]const u8) = .empty;
    var libs: std.ArrayList([]const u8) = .empty;
    var lib_dirs: std.ArrayList([]const u8) = .empty;

    var args = std.process.Args.Iterator.init(argv);
    _ = args.next(); // argv[0]
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            var stdout_buf: [4096]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
            try stdout_writer.interface.writeAll(usage_text);
            try printTargetsHelp(&stdout_writer.interface);
            try stdout_writer.interface.flush();
            return error.HelpShown;
        }
        if (flagValue(arg, "--target", &args)) |v| {
            cli.target = hcc.target.Target.parse(v) catch |e| {
                try stderr.print("hcc: invalid --target \"{s}\": {s}\n", .{ v, hcc.target.explain(e) });
                return error.Usage;
            };
            continue;
        }
        if (flagValue(arg, "--emit", &args)) |v| {
            cli.emit = std.meta.stringToEnum(EmitKind, v) orelse {
                try stderr.print("hcc: unknown --emit \"{s}\" (want exe, obj, shared, check, or ast)\n", .{v});
                return error.Usage;
            };
            continue;
        }
        if (flagValue(arg, "-o", &args)) |v| {
            cli.out = v;
            continue;
        }
        if (flagValue(arg, "--cc", &args)) |v| {
            cli.cc = v;
            continue;
        }
        // -l and -L accept both the attached (-lm, -L/opt/lib) and separate
        // (-l m) spellings, like every C compiler driver.
        if (shortFlagValue(arg, "-l", &args)) |v| {
            try libs.append(arena, v);
            continue;
        }
        if (shortFlagValue(arg, "-L", &args)) |v| {
            try lib_dirs.append(arena, v);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            try stderr.print("hcc: unknown flag \"{s}\"\n\n{s}", .{ arg, usage_text });
            return error.Usage;
        }
        try inputs.append(arena, arg);
    }

    if (inputs.items.len == 0) {
        try stderr.print("hcc: expected at least one input file\n\n{s}", .{usage_text});
        return error.Usage;
    }
    cli.inputs = inputs.items;
    cli.libs = libs.items;
    cli.lib_dirs = lib_dirs.items;
    return cli;
}

/// Matches `-X value` and `-Xvalue` (attached), returning the value.
fn shortFlagValue(arg: []const u8, comptime flag: []const u8, args: *std.process.Args.Iterator) ?[]const u8 {
    if (std.mem.eql(u8, arg, flag)) return args.next();
    if (std.mem.startsWith(u8, arg, flag) and arg.len > flag.len) return arg[flag.len..];
    return null;
}

/// Matches `--flag value` and `--flag=value`, returning the value. The
/// iterator is advanced past a separate value argument.
fn flagValue(arg: []const u8, comptime flag: []const u8, args: *std.process.Args.Iterator) ?[]const u8 {
    if (std.mem.eql(u8, arg, flag)) return args.next();
    if (std.mem.startsWith(u8, arg, flag ++ "=")) return arg[flag.len + 1 ..];
    return null;
}

fn printTargetsHelp(w: *std.Io.Writer) !void {
    try w.print("The target defaults to the host ({f}).\n", .{hcc.target.Target.host()});
}

/// Runs the requested emit mode over every input. Returns false if anything
/// failed (diagnostics already printed).
fn run(arena: std.mem.Allocator, io: std.Io, cli: Cli, stderr: *std.Io.Writer) !bool {
    var all_ok = true;
    var programs: std.ArrayList(hcc.ast.Program) = .empty;

    for (cli.inputs) |input| {
        if (std.mem.endsWith(u8, input, ".o")) {
            try stderr.print("hcc: {s}: linking object files is not implemented yet\n", .{input});
            all_ok = false;
            continue;
        }
        const src = std.Io.Dir.cwd().readFileAlloc(io, input, arena, .limited(64 << 20)) catch |e| {
            try stderr.print("hcc: cannot read {s}: {s}\n", .{ input, @errorName(e) });
            all_ok = false;
            continue;
        };

        // Each input compiles as an independent unit with its own diagnostics,
        // like the Go driver's per-unit objects.
        var diags = hcc.diag.Diagnostics.init(arena);
        var files: []const hcc.source.FileInfo = &.{};
        const result: ?hcc.frontend.Result = hcc.frontend.run(arena, &diags, io, src, .{
            .base_dir = std.fs.path.dirname(input) orelse ".",
            .target = cli.target,
            .files_out = &files,
        }) catch |e| switch (e) {
            error.CompileFailed => null,
            error.OutOfMemory => return error.OutOfMemory,
        };

        try printDiagnostics(&diags, files, input, stderr);
        if (result == null or diags.hasErrors()) {
            all_ok = false;
            continue;
        }
        try programs.append(arena, result.?.program);
    }
    if (!all_ok) return false;

    switch (cli.emit) {
        .check => return true,
        .ast => {
            var stdout_buf: [16 * 1024]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
            for (programs.items) |*prog| {
                try hcc.ast_render.renderProgram(prog, &stdout_writer.interface, .{});
            }
            try stdout_writer.interface.flush();
            return true;
        },
        .exe, .obj, .shared => {
            if (cli.inputs.len != 1) {
                try stderr.print("hcc: --emit {s} expects a single source file for now, got {d}\n", .{ @tagName(cli.emit), cli.inputs.len });
                return false;
            }
            const kind: llvm.EmitKind = switch (cli.emit) {
                .exe => .exe,
                .obj => .obj,
                .shared => .shared,
                else => unreachable,
            };
            var diags = hcc.diag.Diagnostics.init(arena);
            llvm.emit(arena, &diags, io, &programs.items[0], .{
                .target = cli.target,
                .kind = kind,
                .out_path = cli.out orelse try defaultOutput(arena, cli),
                .libs = cli.libs,
                .lib_dirs = cli.lib_dirs,
                .cc = cli.cc,
            }) catch |e| switch (e) {
                error.CompileFailed => {
                    try printDiagnostics(&diags, &.{}, cli.inputs[0], stderr);
                    return false;
                },
                error.OutOfMemory => return error.OutOfMemory,
            };
            return true;
        },
    }
}

/// The default output path, mirroring the Go driver: the first input's base
/// name for an executable ("a" if that would be empty; ".exe" for a windows
/// target), base+".o" for an object, and the target OS's shared-library
/// suffix for a shared library.
fn defaultOutput(arena: std.mem.Allocator, cli: Cli) ![]const u8 {
    const base_full = std.fs.path.basename(cli.inputs[0]);
    const stem = std.fs.path.stem(base_full);
    const base = if (stem.len == 0) "a" else stem;
    return switch (cli.emit) {
        .exe => if (cli.target.os == .windows) try std.fmt.allocPrint(arena, "{s}.exe", .{base}) else base,
        .obj => try std.fmt.allocPrint(arena, "{s}.o", .{base}),
        .shared => try std.fmt.allocPrint(arena, "{s}{s}", .{
            base,
            @as([]const u8, switch (cli.target.os) {
                .darwin => ".dylib",
                .windows => ".dll",
                .linux => ".so",
            }),
        }),
        else => unreachable,
    };
}

fn printDiagnostics(
    diags: *const hcc.diag.Diagnostics,
    files: []const hcc.source.FileInfo,
    input_path: []const u8,
    stderr: *std.Io.Writer,
) !void {
    for (diags.list.items) |d| {
        // File 0 is the top-level source: render it as the input path itself.
        // Other ids (includes, the prelude) render their recorded file names.
        if (d.file == 0 or d.file >= files.len) {
            try stderr.print("{s}:{f}: {s}: {s}\n", .{ input_path, d.pos, @tagName(d.severity), d.message });
        } else {
            try stderr.print("{f}:{f}: {s}: {s}\n", .{ files[d.file], d.pos, @tagName(d.severity), d.message });
        }
    }
}
