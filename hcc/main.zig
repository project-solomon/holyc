//! The HolyC compiler driver: runs the front end (lex → preprocess with the
//! core → parse → check → layout) and hands the result to the LLVM backend.
//! See `help_text` (hcc --help) for the flags.

const std = @import("std");
const hcc = @import("hcc");
const llvm = @import("llvm");

const usage_line = "usage: hcc [options] <input.HC>...   (try `hcc --help`)\n";

const help_text =
    \\hcc, the HolyC compiler.
    \\
    \\usage: hcc [options] <input.HC>...
    \\
    \\  -o <path>          output path (default: from the first input)
    \\  --emit <kind>      exe (default), obj, shared, check, ast
    \\  --target <triple>  cross-compile target (default: host; --target --help lists them)
    \\  -l <name>          link library (repeatable); -L <dir> adds a search path
    \\  -I <dir>           add a #include <...> search directory (repeatable)
    \\  --cc <driver>      link driver (default: cc, or $HCC_CC)
    \\  --no-cache         skip the build cache
    \\  -h, --help         show this help
    \\
;

const EmitKind = enum { exe, obj, shared, check, ast };

const Cli = struct {
    target: hcc.target.Target,
    emit: EmitKind = .exe,
    out: ?[]const u8 = null,
    inputs: []const []const u8 = &.{},
    /// Libraries (-l) and search dirs (-L) forwarded to the link step, so
    /// `extern` imports resolve against shared libraries.
    libs: []const []const u8 = &.{},
    lib_dirs: []const []const u8 = &.{},
    /// Ordered #include <...> search path: the -I dirs plus the package roots
    /// (HCC_ROOT/pkg, HCC_ROOT/std), assembled in main.
    include_path: []const []const u8 = &.{},
    /// Explicit link driver (--cc flag or HCC_CC); null picks the default
    /// (host `cc`, or `zig cc` for a cross target).
    cc: ?[]const u8 = null,
    /// Directory for #exe scratch executables (from $TMPDIR, else /tmp).
    tmp_dir: []const u8 = "/tmp",
    /// The content-addressed build cache dir ($HCC_ROOT/.cache/build), set by
    /// main; null when the toolchain root can't be resolved (cache disabled).
    cache_dir: ?[]const u8 = null,
    /// Disables the build cache for this run (--no-cache).
    no_cache: bool = false,
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
    cli.include_path = try computeIncludePath(arena, io, init.environ_map, cli.include_path);
    if (init.environ_map.get("TMPDIR")) |t| cli.tmp_dir = std.mem.trimEnd(u8, t, "/");
    // Build cache lives at $HCC_ROOT/.cache/build (beside .cache/core), shared
    // across projects and content-addressed so a hit is always correct. Skipped
    // when the root can't be resolved.
    if (toolchainRoot(arena, io, init.environ_map)) |root|
        cli.cache_dir = try std.fs.path.join(arena, &.{ root, ".cache", "build" });

    const ok = try run(arena, io, cli, stderr);
    try stderr.flush();
    if (!ok) std.process.exit(1);
}

fn parseArgs(arena: std.mem.Allocator, io: std.Io, argv: std.process.Args, stderr: *std.Io.Writer) !Cli {
    var cli: Cli = .{ .target = hcc.target.Target.host() };
    var inputs: std.ArrayList([]const u8) = .empty;
    var libs: std.ArrayList([]const u8) = .empty;
    var lib_dirs: std.ArrayList([]const u8) = .empty;
    var include_dirs: std.ArrayList([]const u8) = .empty;

    var args = std.process.Args.Iterator.init(argv);
    _ = args.next(); // argv[0]
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try printToStdout(io, help_text);
            return error.HelpShown;
        }
        if (flagValue(arg, "--target", &args)) |v| {
            // --target --help (or -h) lists the supported targets.
            if (std.mem.eql(u8, v, "--help") or std.mem.eql(u8, v, "-h")) {
                var buf: [2048]u8 = undefined;
                var w = std.Io.Writer.fixed(&buf);
                hcc.target.writeSupported(&w) catch unreachable;
                try printToStdout(io, w.buffered());
                return error.HelpShown;
            }
            cli.target = hcc.target.Target.parse(v) catch |e| {
                try stderr.print("hcc: invalid --target \"{s}\": {s}\n", .{ v, hcc.target.explain(e) });
                try stderr.writeAll("try `hcc --target --help` for the supported targets\n");
                return error.Usage;
            };
            continue;
        }
        if (flagValue(arg, "--emit", &args)) |v| {
            cli.emit = std.meta.stringToEnum(EmitKind, v) orelse {
                try stderr.print("hcc: unknown --emit \"{s}\" (exe, obj, shared, check, or ast)\n{s}", .{ v, usage_line });
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
        if (std.mem.eql(u8, arg, "--no-cache")) {
            cli.no_cache = true;
            continue;
        }
        // -l and -L accept attached (-lm, -L/opt/lib) and separate (-l m)
        // spellings, like any C driver.
        if (shortFlagValue(arg, "-l", &args)) |v| {
            try libs.append(arena, v);
            continue;
        }
        if (shortFlagValue(arg, "-L", &args)) |v| {
            try lib_dirs.append(arena, v);
            continue;
        }
        if (shortFlagValue(arg, "-I", &args)) |v| {
            try include_dirs.append(arena, v);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            try stderr.print("hcc: unknown flag \"{s}\"\n{s}", .{ arg, usage_line });
            return error.Usage;
        }
        try inputs.append(arena, arg);
    }

    if (inputs.items.len == 0) {
        try stderr.print("hcc: expected at least one input file\n{s}", .{usage_line});
        return error.Usage;
    }
    cli.inputs = inputs.items;
    cli.libs = libs.items;
    cli.lib_dirs = lib_dirs.items;
    cli.include_path = include_dirs.items; // -I dirs; main appends the package roots
    return cli;
}

/// Builds the #include <...> search path: the -I dirs (include_dirs), then
/// $HCC_ROOT/pkg (third-party packages), then $HCC_ROOT/std (standard library).
/// An unresolvable root is skipped.
fn computeIncludePath(arena: std.mem.Allocator, io: std.Io, env: anytype, include_dirs: []const []const u8) ![]const []const u8 {
    var path: std.ArrayList([]const u8) = .empty;
    try path.appendSlice(arena, include_dirs);
    if (toolchainRoot(arena, io, env)) |root| {
        try path.append(arena, try std.fs.path.join(arena, &.{ root, "pkg" }));
        try path.append(arena, try std.fs.path.join(arena, &.{ root, "std" }));
    }
    return path.items;
}

/// The toolchain tree ($HCC_ROOT), holding bin/, std/, and pkg/. Defaults to
/// the parent of the binary's own dir (~/hcc/bin/hcc -> ~/hcc), so a relocated
/// install still finds its stdlib. Null if unresolvable.
fn toolchainRoot(arena: std.mem.Allocator, io: std.Io, env: anytype) ?[]const u8 {
    return env.get("HCC_ROOT") orelse blk: {
        const bindir = std.process.executableDirPathAlloc(io, arena) catch break :blk null;
        break :blk std.fs.path.dirname(bindir); // the parent of bin/
    };
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

fn printToStdout(io: std.Io, text: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &buf);
    try stdout_writer.interface.writeAll(text);
    try stdout_writer.interface.flush();
}

/// Runs the requested emit mode over every input. Returns false if anything
/// failed (diagnostics already printed).
/// Hard cap on #exe nesting (a block whose generated source itself contains
/// #exe); a backstop against runaway recursion.
const max_exe_depth = 16;

/// The state the #exe executor needs, passed opaquely through the preprocessor.
const ExeCtx = struct {
    include_path: []const []const u8,
    cc: ?[]const u8,
    tmp_dir: []const u8,
    /// Shared across nested runs so scratch executable names never collide.
    counter: *u32,
    depth: u32,
};

/// Compiles and runs one #exe block at compile time, returning its stdout to
/// splice back into the source. `unit` is the program the preprocessor built
/// (the file up to the directive plus the block body as top-level statements);
/// it is compiled for the host, run, and its stdout captured. Matches
/// Preprocessor.ExeRunner.
fn runExeBlock(
    ctx_ptr: *anyopaque,
    arena: std.mem.Allocator,
    io: std.Io,
    unit: []const u8,
    base_dir: []const u8,
) hcc.Preprocessor.ExeResult {
    const ctx: *const ExeCtx = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.depth >= max_exe_depth) return .{ .err = "#exe blocks nested too deeply" };

    // Nested #exe inside this block re-enters one level deeper.
    const child = arena.create(ExeCtx) catch return .{ .err = "out of memory" };
    child.* = ctx.*;
    child.depth = ctx.depth + 1;

    // Front end. The block runs on the host: #exe is a compile-time effect, so
    // the outer --target is irrelevant here.
    var diags = hcc.diag.Diagnostics.init(arena);
    const result = hcc.frontend.run(arena, &diags, io, unit, .{
        .base_dir = base_dir,
        .target = hcc.target.Target.host(),
        .include_path = ctx.include_path,
        .exe_runner = runExeBlock,
        .exe_ctx = child,
    }) catch |e| switch (e) {
        error.OutOfMemory => return .{ .err = "out of memory" },
        error.CompileFailed => return .{ .err = diagMessage(&diags, "the block failed to compile") },
    };

    // Back end → a scratch host executable.
    ctx.counter.* += 1;
    const exe_path = std.fmt.allocPrint(arena, "{s}/hcc-exe-{d}", .{ ctx.tmp_dir, ctx.counter.* }) catch
        return .{ .err = "out of memory" };
    var bediags = hcc.diag.Diagnostics.init(arena);
    llvm.emit(arena, &bediags, io, &result.program, .{
        .target = hcc.target.Target.host(),
        .kind = .exe,
        .out_path = exe_path,
        .cc = ctx.cc,
    }) catch |e| switch (e) {
        error.OutOfMemory => return .{ .err = "out of memory" },
        error.CompileFailed => return .{ .err = diagMessage(&bediags, "the block failed to build") },
    };
    defer std.Io.Dir.cwd().deleteFile(io, exe_path) catch {};

    // Run it, capturing stdout. std.process.run drains the pipes before waiting,
    // so a large generated program cannot deadlock.
    const child_run = std.process.run(arena, io, .{
        .argv = &.{exe_path},
        .stdout_limit = .limited(64 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch |e| return .{ .err = std.fmt.allocPrint(arena, "cannot run the block: {s}", .{@errorName(e)}) catch
        "cannot run the block" };
    switch (child_run.term) {
        .exited => |code| if (code != 0)
            return .{ .err = std.fmt.allocPrint(arena, "the block exited with {d}", .{code}) catch
                "the block exited nonzero" },
        else => return .{ .err = "the block terminated abnormally" },
    }
    return .{ .ok = child_run.stdout };
}

/// The first error message in diags, duped into arena, or a fallback.
fn diagMessage(diags: *const hcc.diag.Diagnostics, fallback: []const u8) []const u8 {
    if (diags.firstError()) |d| return d.message;
    return fallback;
}

fn run(arena: std.mem.Allocator, io: std.Io, cli: Cli, stderr: *std.Io.Writer) !bool {
    var all_ok = true;
    var programs: std.ArrayList(hcc.ast.Program) = .empty;
    // The content digest of each program's resolved source, parallel to
    // `programs`, keying the build cache in the emit step.
    var digests: std.ArrayList([32]u8) = .empty;

    // The #exe executor: compile-time blocks are sub-compiled and run on the
    // host (they run now, so can never be cross-compiled), then their stdout is
    // spliced back into the source. include_path/cc carry over so a block
    // resolves the same headers as the outer compile.
    var exe_counter: u32 = 0;
    var exe_ctx: ExeCtx = .{
        .include_path = cli.include_path,
        .cc = cli.cc,
        .tmp_dir = cli.tmp_dir,
        .counter = &exe_counter,
        .depth = 0,
    };

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
            .include_path = cli.include_path,
            .files_out = &files,
            .exe_runner = runExeBlock,
            .exe_ctx = &exe_ctx,
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
        try digests.append(arena, result.?.source_digest);
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
            const out_path = cli.out orelse try defaultOutput(arena, cli);
            var diags = hcc.diag.Diagnostics.init(arena);
            emitCached(arena, io, cli, &programs.items[0], digests.items[0], kind, out_path, &diags) catch |e| switch (e) {
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

/// The cache-format version. Bumping it changes the `v<N>` subdir, retiring
/// every prior entry without a manual clear.
const cache_format: u32 = 1;

/// Emits the artifact through the content-addressed build cache. The cached unit
/// is the OBJECT (the expensive LLVM O2 + codegen output), never the linked
/// artifact: linking is cheap and re-run every build, so a changed library is
/// always picked up. Flow: obtain the object (from cache, or build and store
/// it), then for --emit obj copy it out, else link against the current
/// -l/-L/--cc. A cache I/O failure degrades to a normal build.
fn emitCached(
    arena: std.mem.Allocator,
    io: std.Io,
    cli: Cli,
    prog: *const hcc.ast.Program,
    digest: [32]u8,
    kind: llvm.EmitKind,
    out_path: []const u8,
    diags: *hcc.diag.Diagnostics,
) llvm.Error!void {
    const cwd = std.Io.Dir.cwd();
    const cache_file: ?[]const u8 = if (cli.no_cache) null else blk: {
        const dir = cli.cache_dir orelse break :blk null;
        const key = cacheKey(arena, io, cli, digest, kind) catch break :blk null;
        // Shard by the first hash byte so no single directory grows unbounded;
        // the v<N> level lets a format bump retire everything at once.
        break :blk std.fs.path.join(arena, &.{
            dir, comptimeVerDir(), key[0..2], key,
        }) catch break :blk null;
    };

    // The object we will link/copy: a cache hit uses the stored object in place;
    // otherwise build it and (best-effort) store it for next time.
    const obj: []const u8 = obtain: {
        if (cache_file) |cf| {
            if (cwd.access(io, cf, .{})) |_| {
                break :obtain cf; // hit
            } else |_| {}
        }
        // Miss: build the object to a temp beside the output, then cache it.
        const tmp_obj = try std.fmt.allocPrint(arena, "{s}.build.o", .{out_path});
        try llvm.emitObject(arena, diags, prog, .{
            .target = cli.target,
            .kind = kind,
            .out_path = out_path, // unused by emitObject; the object path is explicit
        }, tmp_obj);
        if (cache_file) |cf| {
            if (cwd.copyFile(tmp_obj, cwd, cf, io, .{ .make_path = true })) |_| {
                cwd.deleteFile(io, tmp_obj) catch {};
                break :obtain cf;
            } else |_| {}
        }
        break :obtain tmp_obj; // uncached (or store failed): link/copy the temp
    };
    // Clean up a temp object once we are done with it (not the cache file).
    defer if (cache_file == null or !std.mem.eql(u8, obj, cache_file.?))
        cwd.deleteFile(io, obj) catch {};

    if (kind == .obj) {
        cwd.copyFile(obj, cwd, out_path, io, .{ .make_path = true }) catch |e|
            return diags.fail(.codegen, 0, .{}, "cannot write {s}: {s}", .{ out_path, @errorName(e) });
        return;
    }
    try llvm.linkObject(arena, diags, io, obj, .{
        .target = cli.target,
        .kind = kind,
        .out_path = out_path,
        .libs = cli.libs,
        .lib_dirs = cli.lib_dirs,
        .cc = cli.cc,
    });
}

fn comptimeVerDir() []const u8 {
    return std.fmt.comptimePrint("v{d}", .{cache_format});
}

/// The object-cache key (hex SHA-256). Covers everything that affects the
/// object bytes: the cache format, the compiler's own binary (any codegen
/// change), the libLLVM version (linked dynamically), the resolved-source
/// digest, the target, and the lowering mode (whole-program for exe vs a
/// separate-compilation unit for obj/shared). Link inputs are excluded; linking
/// is a separate, always-run step. Errors if the compiler binary can't be read,
/// so the caller skips the cache.
fn cacheKey(
    arena: std.mem.Allocator,
    io: std.Io,
    cli: Cli,
    digest: [32]u8,
    kind: llvm.EmitKind,
) ![]const u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(std.mem.asBytes(&cache_format));
    // Compiler identity: the running binary's own bytes (catches every codegen
    // change, not just a version bump).
    const exe_path = try std.process.executablePathAlloc(io, arena);
    const exe_bytes = try std.Io.Dir.cwd().readFileAlloc(io, exe_path, arena, .limited(256 << 20));
    hashChunk(&h, exe_bytes);
    // Backend identity: libLLVM is linked dynamically, so its version can change
    // codegen without changing hcc.
    h.update(std.mem.asBytes(&llvm.llvmVersion()));
    hashChunk(&h, &digest);
    hashChunk(&h, std.mem.asBytes(&cli.target));
    // The object depends on the lowering mode, not the emit kind: obj and shared
    // both lower as libraries and share one object; exe is whole-program.
    h.update(&[_]u8{@intFromBool(kind == .exe)});
    var out: [32]u8 = undefined;
    h.final(&out);
    const hex = std.fmt.bytesToHex(out, .lower);
    return arena.dupe(u8, &hex);
}

/// Folds one byte string into a hash, length-prefixed so a different split of
/// the same bytes cannot collide.
fn hashChunk(h: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, bytes.len, .little);
    h.update(&len);
    h.update(bytes);
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
        // Other ids (includes, the core) render their recorded file names.
        if (d.file == 0 or d.file >= files.len) {
            try stderr.print("{s}:{f}: {s}: {s}\n", .{ input_path, d.pos, @tagName(d.severity), d.message });
        } else {
            try stderr.print("{f}:{f}: {s}: {s}\n", .{ files[d.file], d.pos, @tagName(d.severity), d.message });
        }
    }
}
