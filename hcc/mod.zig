//! hcc.toml, the project manifest: dependency manager and build file. A small
//! fixed subset of TOML, parsed here without a third-party library.
//!
//!     name = "github.com/you/myapp"
//!
//!     [build]
//!     libs = ["m"]
//!
//!     [[dependencies]]
//!     git = "github.com/terry/json"    # remote, cloned into pkg/
//!     version = "v1.4.0"
//!
//!     [[dependencies]]
//!     path = "../mylib"                # local submodule
//!     as = "lib"                       # override the include alias
//!
//!     [[bin]]
//!     name = "myapp"
//!     path = "src/main.HC"             # entrypoint (top-level stmts = main)
//!
//! String handling only; the driver (main.zig) does the io and git work.

const std = @import("std");

/// The manifest's fixed filename, searched for by walking up from the cwd.
pub const file_name = "hcc.toml";

/// Shared compiler flags from the `[build]` table.
pub const Build = struct {
    target: ?[]const u8 = null,
    cc: ?[]const u8 = null,
    libs: []const []const u8 = &.{},
    lib_dirs: []const []const u8 = &.{},
    include: []const []const u8 = &.{},
};

/// One `[[dependencies]]` record. Exactly one of `git`/`path` is set: `git` is a
/// remote import path (cloned into pkg/), `path` a local submodule directory.
pub const Dep = struct {
    git: ?[]const u8 = null,
    path: ?[]const u8 = null,
    /// Git tag for a `git` dependency; null checks out the default branch.
    version: ?[]const u8 = null,
    /// Include-alias override; null derives it from the dependency's name.
    as_: ?[]const u8 = null,

    /// The git import path or local path.
    pub fn source(d: Dep) []const u8 {
        return d.git orelse d.path orelse "";
    }
};

/// One `[[bin]]` executable.
pub const Bin = struct {
    name: ?[]const u8 = null,
    /// The entrypoint .HC file: its top-level statements become the program.
    path: ?[]const u8 = null,
    /// Optional per-executable emit override (exe/obj/shared/…).
    emit: ?[]const u8 = null,
};

pub const Manifest = struct {
    /// This module's import path; dependents include it under the last segment.
    name: ?[]const u8 = null,
    build: Build = .{},
    deps: []const Dep = &.{},
    bins: []const Bin = &.{},
};

const Section = enum { none, build, dep, bin, other };

/// Parses a manifest. Unknown tables and keys are ignored; blank lines and `#`
/// comments are skipped; surrounding quotes/whitespace are tolerated.
pub fn parse(arena: std.mem.Allocator, bytes: []const u8) !Manifest {
    var m: Manifest = .{};
    var deps: std.ArrayList(Dep) = .empty;
    var bins: std.ArrayList(Bin) = .empty;
    var libs: std.ArrayList([]const u8) = .empty;
    var lib_dirs: std.ArrayList([]const u8) = .empty;
    var include: std.ArrayList([]const u8) = .empty;

    var section: Section = .none;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, stripComment(std.mem.trim(u8, raw, " \t\r")), " \t");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "[[")) {
            const name = headerName(line);
            if (std.mem.eql(u8, name, "dependencies")) {
                try deps.append(arena, .{});
                section = .dep;
            } else if (std.mem.eql(u8, name, "bin")) {
                try bins.append(arena, .{});
                section = .bin;
            } else section = .other;
            continue;
        }
        if (line[0] == '[') {
            section = if (std.mem.eql(u8, headerName(line), "build")) .build else .other;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        switch (section) {
            .none => if (std.mem.eql(u8, key, "name")) {
                m.name = unquote(val);
            },
            .build => {
                if (std.mem.eql(u8, key, "target")) m.build.target = unquote(val) else if (std.mem.eql(u8, key, "cc")) m.build.cc = unquote(val) else if (std.mem.eql(u8, key, "libs")) libs = try parseArray(arena, val) else if (std.mem.eql(u8, key, "lib-dirs")) lib_dirs = try parseArray(arena, val) else if (std.mem.eql(u8, key, "include")) include = try parseArray(arena, val);
            },
            .dep => {
                const d = &deps.items[deps.items.len - 1];
                if (std.mem.eql(u8, key, "git")) d.git = unquote(val) else if (std.mem.eql(u8, key, "path")) d.path = unquote(val) else if (std.mem.eql(u8, key, "version")) d.version = unquote(val) else if (std.mem.eql(u8, key, "as")) d.as_ = unquote(val);
            },
            .bin => {
                const b = &bins.items[bins.items.len - 1];
                if (std.mem.eql(u8, key, "name")) b.name = unquote(val) else if (std.mem.eql(u8, key, "path")) b.path = unquote(val) else if (std.mem.eql(u8, key, "emit")) b.emit = unquote(val);
            },
            .other => {},
        }
    }
    m.build.libs = libs.items;
    m.build.lib_dirs = lib_dirs.items;
    m.build.include = include.items;
    m.deps = deps.items;
    m.bins = bins.items;
    return m;
}

/// The default alias for a source (git path or local dir): its last path
/// segment, minus a trailing slash or `.git` (`github.com/terry/json` → `json`).
pub fn defaultAlias(src: []const u8) []const u8 {
    var p = src;
    if (std.mem.endsWith(u8, p, "/")) p = p[0 .. p.len - 1];
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |slash| p = p[slash + 1 ..];
    if (std.mem.endsWith(u8, p, ".git")) p = p[0 .. p.len - 4];
    return p;
}

/// Splits an `hcc get` argument (`import-path[@version]`) into its path and
/// optional version.
pub const GetArg = struct { path: []const u8, version: ?[]const u8 };
pub fn parseArg(arg: []const u8) GetArg {
    if (std.mem.lastIndexOfScalar(u8, arg, '@')) |at|
        return .{ .path = arg[0..at], .version = arg[at + 1 ..] };
    return .{ .path = arg, .version = null };
}

/// Returns `bytes` with a git dependency inserted or its version updated. If a
/// `[[dependencies]]` record already names `git`, its `version` is set in place;
/// otherwise a new record is appended. The result ends in a single newline.
pub fn addDependency(arena: std.mem.Allocator, bytes: []const u8, git: []const u8, version: ?[]const u8) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |l| try lines.append(arena, l);

    // Scan for a [[dependencies]] block whose `git` matches; note its git line
    // (to insert a version after) and any existing version line (to replace).
    var in_dep = false;
    var cur_git: ?[]const u8 = null;
    var cur_git_line: usize = 0;
    var cur_ver_line: ?usize = null;
    var match_git_line: ?usize = null;
    var match_ver_line: ?usize = null;
    const closeBlock = struct {
        fn run(is_dep: bool, cg: ?[]const u8, cgl: usize, cvl: ?usize, want: []const u8, mg: *?usize, mv: *?usize) void {
            if (is_dep and cg != null and std.mem.eql(u8, cg.?, want)) {
                mg.* = cgl;
                mv.* = cvl;
            }
        }
    }.run;

    for (lines.items, 0..) |raw, i| {
        const line = std.mem.trim(u8, stripComment(std.mem.trim(u8, raw, " \t\r")), " \t");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            closeBlock(in_dep, cur_git, cur_git_line, cur_ver_line, git, &match_git_line, &match_ver_line);
            in_dep = std.mem.startsWith(u8, line, "[[") and std.mem.eql(u8, headerName(line), "dependencies");
            cur_git = null;
            cur_ver_line = null;
            continue;
        }
        if (!in_dep) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (std.mem.eql(u8, key, "git")) {
            cur_git = unquote(std.mem.trim(u8, line[eq + 1 ..], " \t"));
            cur_git_line = i;
        } else if (std.mem.eql(u8, key, "version")) {
            cur_ver_line = i;
        }
    }
    closeBlock(in_dep, cur_git, cur_git_line, cur_ver_line, git, &match_git_line, &match_ver_line);

    if (match_git_line) |gl| {
        if (version) |v| {
            const ver_line = try std.fmt.allocPrint(arena, "version = \"{s}\"", .{v});
            if (match_ver_line) |vl| {
                lines.items[vl] = ver_line;
            } else {
                try lines.insert(arena, gl + 1, ver_line);
            }
        }
        return joinLines(arena, lines.items);
    }

    // Append a fresh record.
    try lines.append(arena, "");
    try lines.append(arena, "[[dependencies]]");
    try lines.append(arena, try std.fmt.allocPrint(arena, "git = \"{s}\"", .{git}));
    if (version) |v| try lines.append(arena, try std.fmt.allocPrint(arena, "version = \"{s}\"", .{v}));
    return joinLines(arena, lines.items);
}

// --- internals -------------------------------------------------------------

/// The name inside a `[header]` or `[[header]]` line.
fn headerName(line: []const u8) []const u8 {
    const open = std.mem.indexOfNone(u8, line, "[") orelse return "";
    const close = std.mem.indexOfScalarPos(u8, line, open, ']') orelse return "";
    return std.mem.trim(u8, line[open..close], " \t");
}

/// Parses a single-line TOML array `["a", "b"]` into its string elements.
fn parseArray(arena: std.mem.Allocator, s: []const u8) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    var inner = s;
    if (std.mem.startsWith(u8, inner, "[")) inner = inner[1..];
    if (std.mem.endsWith(u8, inner, "]")) inner = inner[0 .. inner.len - 1];
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |part| {
        const e = unquote(std.mem.trim(u8, part, " \t"));
        if (e.len > 0) try out.append(arena, e);
    }
    return out;
}

/// Drops a `#` comment, honoring double-quoted strings.
fn stripComment(line: []const u8) []const u8 {
    var in_str = false;
    for (line, 0..) |ch, i| {
        if (ch == '"') in_str = !in_str;
        if (ch == '#' and !in_str) return line[0..i];
    }
    return line;
}

/// Strips a matching pair of surrounding single or double quotes.
fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and (s[0] == '"' or s[0] == '\'') and s[s.len - 1] == s[0])
        return s[1 .. s.len - 1];
    return s;
}

fn joinLines(arena: std.mem.Allocator, lines: []const []const u8) ![]const u8 {
    const joined = try std.mem.join(arena, "\n", lines);
    if (joined.len == 0 or joined[joined.len - 1] != '\n')
        return std.fmt.allocPrint(arena, "{s}\n", .{joined});
    return joined;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "parse reads name, build, dependency list, and bins" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const m = try parse(arena,
        \\name = "myapp"
        \\
        \\[build]
        \\target = "arm64-darwin"
        \\libs = ["m", "curl"]
        \\
        \\[[dependencies]]
        \\git = "github.com/terry/json"
        \\version = "v1.4.0"
        \\
        \\[[dependencies]]
        \\path = "../mylib"
        \\as = "lib"
        \\
        \\[[bin]]
        \\name = "myapp"
        \\path = "src/main.HC"
        \\
    );
    try testing.expectEqualStrings("myapp", m.name.?);
    try testing.expectEqualStrings("arm64-darwin", m.build.target.?);
    try testing.expectEqual(@as(usize, 2), m.build.libs.len);
    try testing.expectEqualStrings("curl", m.build.libs[1]);

    try testing.expectEqual(@as(usize, 2), m.deps.len);
    try testing.expectEqualStrings("github.com/terry/json", m.deps[0].git.?);
    try testing.expectEqualStrings("v1.4.0", m.deps[0].version.?);
    try testing.expect(m.deps[0].path == null);
    try testing.expectEqualStrings("../mylib", m.deps[1].path.?);
    try testing.expectEqualStrings("lib", m.deps[1].as_.?);

    try testing.expectEqual(@as(usize, 1), m.bins.len);
    try testing.expectEqualStrings("myapp", m.bins[0].name.?);
    try testing.expectEqualStrings("src/main.HC", m.bins[0].path.?);
}

test "defaultAlias and parseArg" {
    try testing.expectEqualStrings("json", defaultAlias("github.com/terry/json"));
    try testing.expectEqualStrings("mylib", defaultAlias("../mylib"));
    const a = parseArg("github.com/x/y@v1.2.0");
    try testing.expectEqualStrings("github.com/x/y", a.path);
    try testing.expectEqualStrings("v1.2.0", a.version.?);
    try testing.expect(parseArg("github.com/x/y").version == null);
}

test "addDependency appends a new record" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const out = try addDependency(arena, "name = \"app\"\n", "github.com/terry/json", "v1.4.0");
    const m = try parse(arena, out);
    try testing.expectEqual(@as(usize, 1), m.deps.len);
    try testing.expectEqualStrings("github.com/terry/json", m.deps[0].git.?);
    try testing.expectEqualStrings("v1.4.0", m.deps[0].version.?);
    try testing.expect(out[out.len - 1] == '\n');
}

test "addDependency updates the version of an existing record" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const start =
        \\[[dependencies]]
        \\git = "github.com/terry/json"
        \\version = "v1.0.0"
        \\
    ;
    const out = try addDependency(arena, start, "github.com/terry/json", "v2.0.0");
    const m = try parse(arena, out);
    try testing.expectEqual(@as(usize, 1), m.deps.len);
    try testing.expectEqualStrings("v2.0.0", m.deps[0].version.?);
}

test "addDependency adds a version line when the record had none" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const start =
        \\[[dependencies]]
        \\git = "github.com/terry/json"
        \\
    ;
    const out = try addDependency(arena, start, "github.com/terry/json", "v1.4.0");
    const m = try parse(arena, out);
    try testing.expectEqual(@as(usize, 1), m.deps.len);
    try testing.expectEqualStrings("v1.4.0", m.deps[0].version.?);
}
