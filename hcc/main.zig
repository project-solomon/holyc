//! Command hcc is the HolyC compiler driver: it runs the front end (lex →
//! preprocess with the resident prelude → parse → check → layout) and hands
//! the result to the LLVM backend. See `help_text` below (hcc --help) for the
//! flag surface.

const std = @import("std");
const hcc = @import("hcc");
const llvm = @import("llvm");
const mod = @import("mod");

const usage_line = "usage: hcc [options] <input.HC>...   (try `hcc --help`)\n";

const help_text =
    \\hcc, the HolyC compiler.
    \\
    \\usage:
    \\  hcc [options] <input.HC>...       compile
    \\  hcc init <import-path> [dir]      write a starter hcc.toml
    \\  hcc get [<import-path>[@ver]]...  add or fetch dependencies
    \\  hcc build [name]                 build the manifest's executables
    \\  hcc install [<import-path>|name] build and install to the bin dir
    \\
    \\options:
    \\  -o <path>          output path (default: from the first input)
    \\  --emit <kind>      exe (default), obj, shared, check, ast
    \\  --target <triple>  cross-compile target (default: host; --target --help lists them)
    \\  -l <name>          link library (repeatable); -L <dir> adds a search path
    \\  -I <dir>           add a #include <...> search directory (repeatable)
    \\  --cc <driver>      link driver (default: cc, or $HCC_CC)
    \\  --no-cache         skip the build cache
    \\  -h, --help         show this help
    \\
    \\Angle includes resolve in order: -I dirs, $HCC_PATH/pkg, then $HCC_ROOT/std.
    \\HCC_ROOT is the toolchain tree (bin/, std/, pkg/), defaulting to the parent
    \\of the hcc binary's directory; HCC_PATH defaults to HCC_ROOT.
    \\
    \\hcc.toml holds the module name, [build] flags, [[dependencies]], and [[bin]]:
    \\
    \\    name = "github.com/you/myapp"
    \\    [build]
    \\    libs = ["m"]
    \\    [[dependencies]]
    \\    git = "github.com/terry/json"
    \\    version = "v1.4.0"
    \\    [[bin]]
    \\    name = "myapp"
    \\    path = "src/main.HC"
    \\
    \\A dependency is included under the last segment of its name (<json/Json.HC>),
    \\or an `as` override.
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
    /// The ordered angle-bracket #include <...> search path, computed from the
    /// -I dirs plus the package roots (HCC_PATH/pkg, HCC_ROOT/std) in main.
    include_path: []const []const u8 = &.{},
    /// Alias → import-path map loaded from the project's hcc.toml, used to
    /// expand `#include <alias/File.HC>`. Empty when there is no hcc.toml.
    aliases: std.StringHashMapUnmanaged([]const u8) = .empty,
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

/// The outcome of a manifest subcommand (init/get/build), unified so the
/// dispatch can handle all three the same way.
const SubResult = struct { ok: anyerror!bool };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    // `hcc init`/`get`/`build` are manifest subcommands; none takes the normal
    // compile flags.
    if (firstArg(init.minimal.args)) |first| {
        const sub: ?SubResult = if (std.mem.eql(u8, first, "init"))
            .{ .ok = cmdInit(arena, io, init.minimal.args, stderr) }
        else if (std.mem.eql(u8, first, "get"))
            .{ .ok = cmdGet(arena, io, init.environ_map, init.minimal.args, stderr) }
        else if (std.mem.eql(u8, first, "build"))
            .{ .ok = cmdBuild(arena, io, init.environ_map, init.minimal.args, stderr) }
        else if (std.mem.eql(u8, first, "install"))
            .{ .ok = cmdInstall(arena, io, init.environ_map, init.minimal.args, stderr) }
        else
            null;
        if (sub) |s| {
            const ok = s.ok catch |e| {
                try stderr.print("hcc {s}: {s}\n", .{ first, @errorName(e) });
                try stderr.flush();
                std.process.exit(1);
            };
            try stderr.flush();
            if (!ok) std.process.exit(1);
            return;
        }
    }

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
    cli.aliases = try loadAliases(arena, io, init.environ_map);
    if (init.environ_map.get("TMPDIR")) |t| cli.tmp_dir = std.mem.trimEnd(u8, t, "/");
    // The build cache lives in the toolchain tree at $HCC_ROOT/.cache/build
    // (beside .cache/core), shared across projects; content-addressed, so a hit
    // is always correct. Skipped when the root can't be resolved.
    if (toolchainRoots(arena, io, init.environ_map).root) |root|
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
            // `--target --help` (or -h) lists the supported targets.
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

/// Builds the ordered angle-bracket #include <...> search path: the -I dirs
/// (passed in via include_dirs), then $HCC_PATH/pkg (third-party packages),
/// then $HCC_ROOT/std (the bundled standard library).
///
/// HCC_ROOT is the self-contained toolchain tree (`bin/` + `std/` + `pkg/`); it
/// defaults to the parent of the binary's own dir (so `~/hcc/bin/hcc` yields
/// `~/hcc`), letting a relocated install still find its stdlib. HCC_PATH — where
/// third-party packages live — defaults to HCC_ROOT, so packages resolve under
/// `<root>/pkg` beside the stdlib. Both env vars override; a root that can't be
/// resolved is simply skipped.
fn computeIncludePath(arena: std.mem.Allocator, io: std.Io, env: anytype, include_dirs: []const []const u8) ![]const []const u8 {
    var path: std.ArrayList([]const u8) = .empty;
    try path.appendSlice(arena, include_dirs);

    const roots = toolchainRoots(arena, io, env);
    if (roots.pkg) |hp| try path.append(arena, try std.fs.path.join(arena, &.{ hp, "pkg" }));
    if (roots.root) |hr| try path.append(arena, try std.fs.path.join(arena, &.{ hr, "std" }));

    return path.items;
}

/// The self-contained toolchain tree: `root` holds std/ (the bundled stdlib)
/// and `pkg` (defaulting to root) holds pkg/ (third-party clones). HCC_ROOT
/// defaults to the parent of the binary's own dir (so ~/hcc/bin/hcc -> ~/hcc);
/// HCC_PATH overrides where pkg/ lives. Either may be null if unresolvable.
const Roots = struct { root: ?[]const u8, pkg: ?[]const u8 };
fn toolchainRoots(arena: std.mem.Allocator, io: std.Io, env: anytype) Roots {
    const hcc_root: ?[]const u8 = env.get("HCC_ROOT") orelse blk: {
        const bindir = std.process.executableDirPathAlloc(io, arena) catch break :blk null;
        break :blk std.fs.path.dirname(bindir); // the parent of bin/
    };
    return .{ .root = hcc_root, .pkg = env.get("HCC_PATH") orelse hcc_root };
}

/// The first non-program argument, or null. Used to spot the `get` subcommand
/// before the normal flag parse.
fn firstArg(argv: std.process.Args) ?[]const u8 {
    var it = std.process.Args.Iterator.init(argv);
    _ = it.next(); // argv[0]
    return it.next();
}

/// Loads the include alias map from the nearest hcc.toml (walking up from the
/// cwd). Each alias maps to a dependency's absolute directory — a remote clone
/// under pkg/, or a local submodule dir. The alias is the dependency's `as`
/// override, else its own module `name`, else the source's last segment.
/// Dependencies are followed recursively (a submodule's own deps resolve too),
/// outer aliases winning on a clash. Empty when there is no manifest — includes
/// then behave as before the module system.
fn loadAliases(arena: std.mem.Allocator, io: std.Io, env: anytype) !std.StringHashMapUnmanaged([]const u8) {
    const found = try findManifest(arena, io) orelse return .empty;
    return aliasesFor(arena, io, env, found.path, found.bytes);
}

/// The alias map for a specific manifest (not necessarily the nearest one), used
/// when building or installing a module that lives elsewhere (a fetched command).
fn aliasesFor(arena: std.mem.Allocator, io: std.Io, env: anytype, manifest_path: []const u8, bytes: []const u8) !std.StringHashMapUnmanaged([]const u8) {
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    const pkg = pkgDir(arena, io, env) orelse return map;
    var visited: std.StringHashMapUnmanaged(void) = .empty;
    try mergeNames(arena, io, pkg, &map, &visited, manifest_path, bytes);
    return map;
}

/// The third-party package root (`$HCC_PATH/pkg`), or null if unresolvable.
fn pkgDir(arena: std.mem.Allocator, io: std.Io, env: anytype) ?[]const u8 {
    const hp = toolchainRoots(arena, io, env).pkg orelse return null;
    return std.fs.path.join(arena, &.{ hp, "pkg" }) catch null;
}

/// Merges a manifest's dependencies into `map` (alias → absolute dir), recursing
/// into each dependency's own manifest so its `name` and transitive deps come
/// along. `visited` guards against cycles, keyed by resolved directory.
fn mergeNames(
    arena: std.mem.Allocator,
    io: std.Io,
    pkg: []const u8,
    map: *std.StringHashMapUnmanaged([]const u8),
    visited: *std.StringHashMapUnmanaged(void),
    manifest_path: []const u8,
    bytes: []const u8,
) !void {
    const dir = std.fs.path.dirname(manifest_path) orelse ".";
    const manifest = try mod.parse(arena, bytes);
    for (manifest.deps) |d| {
        const depdir = if (d.git) |g|
            try std.fs.path.join(arena, &.{ pkg, g }) // remote clone under pkg/
        else if (d.path) |p|
            try resolveLocal(arena, io, dir, p) // local submodule dir
        else
            continue;

        // Read the dependency's own manifest for its `name` (the default alias)
        // and its transitive dependencies.
        const sub = try std.fs.path.join(arena, &.{ depdir, mod.file_name });
        const sub_bytes: ?[]const u8 = if (std.Io.Dir.cwd().readFileAlloc(io, sub, arena, .limited(1 << 20))) |b|
            b
        else |e| if (e == error.OutOfMemory) return error.OutOfMemory else null;
        // The alias is the last segment of the dependency's canonical `name`
        // (its import path, like Go's `module` directive), or of the source
        // path if it declares none — unless the consumer overrides with `as`.
        const own_name: ?[]const u8 = if (sub_bytes) |sb| (try mod.parse(arena, sb)).name else null;
        const alias = d.as_ orelse mod.defaultAlias(own_name orelse d.source());

        const gop = try map.getOrPut(arena, alias);
        if (!gop.found_existing) gop.value_ptr.* = depdir; // outer alias wins

        if ((try visited.getOrPut(arena, depdir)).found_existing) continue;
        if (sub_bytes) |sb| try mergeNames(arena, io, pkg, map, visited, sub, sb);
    }
}

/// Resolves a local dependency path against the directory of the manifest that
/// declared it, canonicalizing to an absolute path when the directory exists.
fn resolveLocal(arena: std.mem.Allocator, io: std.Io, base_dir: []const u8, rel: []const u8) ![]const u8 {
    const joined = if (std.fs.path.isAbsolute(rel))
        rel
    else
        try std.fs.path.join(arena, &.{ base_dir, rel });
    return std.Io.Dir.cwd().realPathFileAlloc(io, joined, arena) catch joined;
}

const FoundManifest = struct { path: []const u8, bytes: []const u8 };

/// Searches for hcc.toml from the cwd upward, returning the first hit's path and
/// contents (mirrors the ancestor walk in Preprocessor.includeUpward).
fn findManifest(arena: std.mem.Allocator, io: std.Io) !?FoundManifest {
    // realPathFileAlloc(".") is the codebase's proven way to a canonical
    // absolute path (Dir.realPath has spotty platform support).
    var dir: []const u8 = std.Io.Dir.cwd().realPathFileAlloc(io, ".", arena) catch return null;
    while (true) {
        const cand = try std.fs.path.join(arena, &.{ dir, mod.file_name });
        if (std.Io.Dir.cwd().readFileAlloc(io, cand, arena, .limited(1 << 20))) |bytes| {
            return .{ .path = cand, .bytes = bytes };
        } else |e| if (e == error.OutOfMemory) return error.OutOfMemory;
        const parent = std.fs.path.dirname(dir) orelse break;
        if (std.mem.eql(u8, parent, dir)) break;
        dir = parent;
    }
    return null;
}

/// The starter hcc.toml written by `hcc init` (first `{s}` = the module's import
/// path, second `{s}` = its last segment, used as the default bin name).
const init_template =
    \\name = "{s}"                               # this module's import path (where it's hosted)
    \\
    \\# [build]                                  # shared compiler flags
    \\# target = "arm64-darwin"
    \\# libs = ["m"]
    \\
    \\# [[dependencies]]                         # a remote git dependency
    \\# git = "github.com/terry/json"           #   (add with `hcc get <import-path>`)
    \\# version = "v1.4.0"
    \\
    \\# [[dependencies]]                         # a local submodule dependency
    \\# path = "../mylib"
    \\# as = "lib"                               #   override the include alias
    \\
    \\# [[bin]]                                  # an executable to `hcc build`
    \\# name = "{s}"
    \\# path = "main.HC"
    \\
;

/// A starter .gitignore for a new project: the compiled executable (named after
/// the module's last segment, the default [[bin]] name) and object/library
/// artifacts. The build cache lives in the toolchain tree ($HCC_ROOT/.cache),
/// not the project, so there is nothing cache-related to ignore here.
const gitignore_template =
    \\# hcc build output
    \\/{s}
    \\*.o
    \\*.dylib
    \\*.so
    \\*.dll
    \\*.exe
    \\
;

/// `hcc init <import-path> [<dir>]`: writes a starter hcc.toml. The module name
/// (its canonical import path, Go's `module` directive) is required; `<dir>` is
/// the directory to initialize, defaulting to `.`. Refuses to clobber an
/// existing manifest.
fn cmdInit(arena: std.mem.Allocator, io: std.Io, argv: std.process.Args, stderr: *std.Io.Writer) !bool {
    var it = std.process.Args.Iterator.init(argv);
    _ = it.next(); // argv[0]
    _ = it.next(); // "init"
    const name = it.next() orelse {
        try stderr.writeAll("hcc init: a module name is required, e.g. `hcc init github.com/you/proj`\n");
        return false;
    };
    const dir = it.next() orelse ".";

    const cwd = std.Io.Dir.cwd();
    if (!std.mem.eql(u8, dir, ".")) cwd.createDirPath(io, dir) catch {};
    const manifest_path = try std.fs.path.join(arena, &.{ dir, mod.file_name });
    if (cwd.access(io, manifest_path, .{})) |_| {
        try stderr.print("{s} already exists\n", .{manifest_path});
        return false;
    } else |_| {}

    // The alias dependents get is the import path's last segment.
    const data = try std.fmt.allocPrint(arena, init_template, .{ name, mod.defaultAlias(name) });
    try cwd.writeFile(io, .{ .sub_path = manifest_path, .data = data });
    try stderr.print("created {s}\n", .{manifest_path});

    // Scaffold a .gitignore for build outputs, unless one already exists (never
    // clobber the user's).
    const gi_path = try std.fs.path.join(arena, &.{ dir, ".gitignore" });
    if (cwd.access(io, gi_path, .{})) |_| {} else |_| {
        const gi = try std.fmt.allocPrint(arena, gitignore_template, .{mod.defaultAlias(name)});
        try cwd.writeFile(io, .{ .sub_path = gi_path, .data = gi });
        try stderr.print("created {s}\n", .{gi_path});
    }
    return true;
}

/// `hcc get`: with import-path arguments, clones each into pkg/ and records it
/// in hcc.toml; with no arguments, clones/updates everything the manifest
/// lists. Returns false if any fetch failed.
fn cmdGet(arena: std.mem.Allocator, io: std.Io, env: anytype, argv: std.process.Args, stderr: *std.Io.Writer) !bool {
    const roots = toolchainRoots(arena, io, env);
    const pkg = if (roots.pkg) |hp| try std.fs.path.join(arena, &.{ hp, "pkg" }) else {
        try stderr.writeAll("cannot locate the package root; set HCC_ROOT or HCC_PATH\n");
        return false;
    };

    var targets: std.ArrayList([]const u8) = .empty;
    var it = std.process.Args.Iterator.init(argv);
    _ = it.next(); // argv[0]
    _ = it.next(); // "get"
    while (it.next()) |a| try targets.append(arena, a);

    // Like `go get` and go.mod, `hcc get` runs only inside a project: the
    // nearest hcc.toml walking up from the cwd. It never creates one; use
    // `hcc init` to start a project.
    const found = try findManifest(arena, io) orelse {
        try stderr.print("no {s} in this directory or any parent; run `hcc init` first\n", .{mod.file_name});
        return false;
    };

    if (targets.items.len == 0) {
        const manifest = try mod.parse(arena, found.bytes);
        var any = false;
        var ok = true;
        for (manifest.deps) |d| {
            const git = d.git orelse continue; // local deps live on disk; nothing to fetch
            any = true;
            ok = (try fetchGit(arena, io, stderr, pkg, git, d.version)) and ok;
        }
        if (!any) try stderr.print("{s} lists no remote dependencies\n", .{mod.file_name});
        return ok;
    }

    var bytes: []const u8 = found.bytes;
    var ok = true;
    var changed = false;
    for (targets.items) |t| {
        const spec = mod.parseArg(t);
        if (!try fetchGit(arena, io, stderr, pkg, spec.path, spec.version)) {
            ok = false;
            continue;
        }
        bytes = try mod.addDependency(arena, bytes, spec.path, spec.version);
        changed = true;
    }
    // Write back to the manifest wherever it lives (a parent dir is fine), only
    // if a dependency was actually added.
    if (changed) {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = found.path, .data = bytes });
        try stderr.print("updated {s}\n", .{found.path});
    }
    return ok;
}

/// Clones (or updates) a remote dependency into `<pkg>/<import-path>` and checks
/// out its version tag when given. Progress and errors go to stderr.
fn fetchGit(arena: std.mem.Allocator, io: std.Io, stderr: *std.Io.Writer, pkg: []const u8, git: []const u8, version: ?[]const u8) !bool {
    const dest = try std.fs.path.join(arena, &.{ pkg, git });
    const present = blk: {
        std.Io.Dir.cwd().access(io, dest, .{}) catch break :blk false;
        break :blk true;
    };
    if (present) {
        try stderr.print("updating {s}\n", .{git});
        if (!try gitRun(io, stderr, &.{ "git", "-C", dest, "fetch", "--tags", "--quiet" })) return false;
    } else {
        try stderr.print("cloning {s}\n", .{git});
        const url = try cloneUrl(arena, git);
        if (!try gitRun(io, stderr, &.{ "git", "clone", "--quiet", url, dest })) return false;
    }
    if (version) |v| {
        if (!try gitRun(io, stderr, &.{ "git", "-C", dest, "checkout", "--quiet", v })) return false;
    }
    return true;
}

/// `hcc build [name]`: compiles each `[[bin]]` in the nearest manifest (or the
/// named one) into the current directory.
fn cmdBuild(arena: std.mem.Allocator, io: std.Io, env: anytype, argv: std.process.Args, stderr: *std.Io.Writer) !bool {
    const found = try findManifest(arena, io) orelse {
        try stderr.print("no {s} found (run `hcc init`)\n", .{mod.file_name});
        return false;
    };
    return buildManifest(arena, io, env, found.path, found.bytes, subArg(argv), null, stderr);
}

/// `hcc install [<import-path>[@ver]] | [<name>]`: builds executables and copies
/// them into the bin dir (on PATH), like `go install`. A remote import path is
/// fetched, built, and installed without touching the current project; with no
/// argument (or a bin name) the current project's executables are installed.
fn cmdInstall(arena: std.mem.Allocator, io: std.Io, env: anytype, argv: std.process.Args, stderr: *std.Io.Writer) !bool {
    const bindir = binDir(arena, io, env) orelse {
        try stderr.writeAll("cannot locate the bin dir; set HCC_BIN or HCC_ROOT\n");
        return false;
    };

    const arg = subArg(argv);
    // A remote command (`import/path` or `path@ver`) is fetched and installed
    // without needing a project here; a bare name filters the local project.
    if (arg) |a| if (std.mem.indexOfAny(u8, a, "/@") != null) {
        const pkg = pkgDir(arena, io, env) orelse {
            try stderr.writeAll("cannot locate the package root; set HCC_ROOT or HCC_PATH\n");
            return false;
        };
        const spec = mod.parseArg(a);
        if (!try fetchGit(arena, io, stderr, pkg, spec.path, spec.version)) return false;
        const mpath = try std.fs.path.join(arena, &.{ pkg, spec.path, mod.file_name });
        const mbytes = std.Io.Dir.cwd().readFileAlloc(io, mpath, arena, .limited(1 << 20)) catch {
            try stderr.print("{s} has no {s}; nothing to install\n", .{ spec.path, mod.file_name });
            return false;
        };
        return buildManifest(arena, io, env, mpath, mbytes, null, bindir, stderr);
    };

    const found = try findManifest(arena, io) orelse {
        try stderr.print("no {s} found (run `hcc init`)\n", .{mod.file_name});
        return false;
    };
    return buildManifest(arena, io, env, found.path, found.bytes, arg, bindir, stderr);
}

/// The directory installed executables go to (Go's GOBIN / $GOPATH/bin): $HCC_BIN
/// if set, else $HCC_ROOT/bin, the toolchain bin dir already on PATH.
fn binDir(arena: std.mem.Allocator, io: std.Io, env: anytype) ?[]const u8 {
    if (env.get("HCC_BIN")) |b| return b;
    const root = toolchainRoots(arena, io, env).root orelse return null;
    return std.fs.path.join(arena, &.{ root, "bin" }) catch null;
}

/// The single argument after a subcommand (`hcc build <arg>`), or null.
fn subArg(argv: std.process.Args) ?[]const u8 {
    var it = std.process.Args.Iterator.init(argv);
    _ = it.next(); // argv[0]
    _ = it.next(); // subcommand
    return it.next();
}

/// Compiles the `[[bin]]` executables of the manifest at `manifest_path` with
/// its `[build]` flags. `only` restricts to one bin by name; `out_dir` (when
/// set) writes each executable there (install) instead of the current directory.
fn buildManifest(
    arena: std.mem.Allocator,
    io: std.Io,
    env: anytype,
    manifest_path: []const u8,
    bytes: []const u8,
    only: ?[]const u8,
    out_dir: ?[]const u8,
    stderr: *std.Io.Writer,
) !bool {
    const manifest = try mod.parse(arena, bytes);
    const dir = std.fs.path.dirname(manifest_path) orelse ".";
    if (manifest.bins.len == 0) {
        try stderr.writeAll("nothing to build (no [[bin]]); this is a library\n");
        return true;
    }
    const aliases = try aliasesFor(arena, io, env, manifest_path, bytes);
    var incs: std.ArrayList([]const u8) = .empty;
    for (manifest.build.include) |inc| try incs.append(arena, try std.fs.path.join(arena, &.{ dir, inc }));
    const include_path = try computeIncludePath(arena, io, env, incs.items);
    const target = if (manifest.build.target) |t| hcc.target.Target.parse(t) catch {
        try stderr.print("invalid target \"{s}\"\n", .{t});
        return false;
    } else hcc.target.Target.host();
    if (out_dir) |d| std.Io.Dir.cwd().createDirPath(io, d) catch {};

    var ok = true;
    for (manifest.bins) |b| {
        const name = b.name orelse {
            try stderr.writeAll("a [[bin]] is missing `name`\n");
            ok = false;
            continue;
        };
        if (only) |o| if (!std.mem.eql(u8, o, name)) continue;
        const path = b.path orelse {
            try stderr.print("[[bin]] {s} is missing `path`\n", .{name});
            ok = false;
            continue;
        };
        const emit: EmitKind = if (b.emit) |e| std.meta.stringToEnum(EmitKind, e) orelse {
            try stderr.print("[[bin]] {s}: unknown emit \"{s}\"\n", .{ name, e });
            ok = false;
            continue;
        } else .exe;

        const inputs = try arena.alloc([]const u8, 1);
        inputs[0] = try std.fs.path.join(arena, &.{ dir, path });
        var cli: Cli = .{
            .target = target,
            .emit = emit,
            .out = if (out_dir) |d| try std.fs.path.join(arena, &.{ d, name }) else name,
            .inputs = inputs,
            .libs = manifest.build.libs,
            .lib_dirs = manifest.build.lib_dirs,
            .include_path = include_path,
            .aliases = aliases,
            .cc = manifest.build.cc orelse env.get("HCC_CC"),
        };
        if (env.get("TMPDIR")) |t| cli.tmp_dir = std.mem.trimEnd(u8, t, "/");
        try stderr.print("{s} {s} <- {s}\n", .{ if (out_dir != null) "installing" else "building", name, path });
        if (!try run(arena, io, cli, stderr)) ok = false;
    }
    return ok;
}

/// The clone URL for an import path: an explicit scheme is honored, otherwise
/// https:// is assumed (Go's convention — the import path is the repo URL).
fn cloneUrl(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, path, "://") != null) return path;
    return std.fmt.allocPrint(arena, "https://{s}", .{path});
}

/// Spawns git and waits; returns whether it exited 0.
fn gitRun(io: std.Io, stderr: *std.Io.Writer, argv: []const []const u8) !bool {
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore }) catch |e| {
        try stderr.print("cannot run git: {s}\n", .{@errorName(e)});
        return false;
    };
    const term = child.wait(io) catch |e| {
        try stderr.print("git failed: {s}\n", .{@errorName(e)});
        return false;
    };
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
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
/// A hard cap on #exe nesting (a block whose generated source itself contains
/// #exe), a backstop against runaway recursion.
const max_exe_depth = 16;

/// The state the #exe executor needs, passed opaquely through the preprocessor.
const ExeCtx = struct {
    include_path: []const []const u8,
    aliases: std.StringHashMapUnmanaged([]const u8),
    cc: ?[]const u8,
    tmp_dir: []const u8,
    /// Shared across nested runs so scratch executable names never collide.
    counter: *u32,
    depth: u32,
};

/// Compiles and runs one #exe block at compile time, returning its stdout to be
/// spliced back into the source. `unit` is the self-contained program the
/// preprocessor built (the file up to the directive plus the block body as
/// top-level statements); it is compiled for the host, run, and its stdout
/// captured. Matches Preprocessor.ExeRunner.
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
        .aliases = ctx.aliases,
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
    // host (they run now, so they can never be cross-compiled), then their
    // stdout is spliced back into the source. include_path/cc/aliases carry
    // over so a block resolves the same headers as the outer compile.
    var exe_counter: u32 = 0;
    var exe_ctx: ExeCtx = .{
        .include_path = cli.include_path,
        .aliases = cli.aliases,
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
            .aliases = cli.aliases,
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
/// is the OBJECT — the expensive LLVM O2 + codegen output — never the linked
/// artifact: linking is cheap and re-run every build, so a changed library is
/// always picked up. Flow: obtain the object (from cache, or by building and
/// storing it), then for --emit obj copy it out, else link it against the
/// current -l/-L/--cc. Any cache I/O failure degrades to a normal build.
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
/// change), the libLLVM version (it links dynamically), the resolved-source
/// digest, the target, and the lowering mode (whole-program for exe vs a
/// separate-compilation unit for obj/shared). Link inputs are deliberately
/// excluded — linking is a separate, always-run step. Errors if the compiler
/// binary can't be read, so the caller skips the cache.
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
        // Other ids (includes, the prelude) render their recorded file names.
        if (d.file == 0 or d.file >= files.len) {
            try stderr.print("{s}:{f}: {s}: {s}\n", .{ input_path, d.pos, @tagName(d.severity), d.message });
        } else {
            try stderr.print("{f}:{f}: {s}: {s}\n", .{ files[d.file], d.pos, @tagName(d.severity), d.message });
        }
    }
}
