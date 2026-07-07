//! The HolyC preprocessor.
//!
//! A Preprocessor wraps the lexers and is itself a token source (it has `next`,
//! so the parser reads from it directly). It slots between the lexer and the
//! parser and never materialises the whole token list. As tokens flow through:
//!
//!   - #define / #undef build and tear down a macro table. HolyC has only
//!     object-like macros (no function-like macros); they are expanded inline,
//!     with a hide-set guarding against self-reference.
//!   - #include "file" reads the file and pushes it onto a source stack, so its
//!     tokens splice in where the directive appeared. The path resolves
//!     relative to the including file's directory; a `::`-prefixed path
//!     (TempleOS-style) searches the current directory and each ancestor.
//!     Cycles and excessive nesting are rejected.
//!   - #if / #ifdef / #ifndef / #elif / #else / #endif select compilation
//!     regions. #ifdef / #ifndef test the macro table; #if / #elif evaluate an
//!     integer constant expression over the same macros, with `defined NAME` /
//!     `defined(NAME)` and undefined names taken as 0 (C rules), using HolyC
//!     operator precedence. Tokens (and ordinary directives) in an unselected
//!     region are dropped. The primary use is include guards, so a file is
//!     processed at most once.
//!
//! Directives run to the end of their line. The lexer discards newlines, but
//! every token carries span.pos.line, so the preprocessor finds line
//! boundaries from token positions; no newline tokens needed.

const std = @import("std");
const source = @import("source.zig");
const diag = @import("diag.zig");
const token_mod = @import("token.zig");
const Token = token_mod.Token;
const Lexer = @import("Lexer.zig");
const target_mod = @import("target.zig");
const core = @import("core.zig");

const Preprocessor = @This();

pub const Error = diag.Error;

/// A hard cap on #include nesting, a backstop beyond the cycle guard.
const max_include_depth = 64;

/// The outcome of running an #exe block: either the program's captured stdout
/// (spliced back in as source) or a human-readable failure message.
pub const ExeResult = union(enum) {
    ok: []const u8,
    err: []const u8,
};

/// Runs one #exe block's compile-time program and returns its stdout. The
/// preprocessor lives in the frontend module, which links no backend, so the
/// driver injects this: it sub-compiles `unit` (the file up to the directive
/// plus the block body as top-level statements), runs the host executable, and
/// captures stdout. `ctx` is the opaque driver state passed alongside the fn;
/// `base_dir` fixes where the unit's relative #includes resolve. The returned
/// bytes must outlive the splice, so they are allocated in `arena`.
pub const ExeRunner = *const fn (
    ctx: *anyopaque,
    arena: std.mem.Allocator,
    io: std.Io,
    unit: []const u8,
    base_dir: []const u8,
) ExeResult;

/// A compiler-predefined object-like macro: NAME expands to the integer value
/// (or 1 when value is not a decimal integer). Used to seed platform macros.
pub const Define = struct {
    name: []const u8,
    value: []const u8,
};

/// One entry in the macro table. An object-like macro has `params == null` and
/// is its replacement body. A function-like macro (a C extension over
/// TempleOS HolyC) carries a parameter list and is only expanded when its name
/// is followed by `(`; `variadic` marks a trailing `...` whose extra arguments
/// gather into `__VA_ARGS__`.
const Macro = struct {
    params: ?[]const []const u8 = null,
    variadic: bool = false,
    body: []const Token,
};

/// The set of macro names that must not be re-expanded within a token: an
/// immutable cons list in the arena (macros are object-like only, so the set
/// grows one name per expansion level).
const HideSet = struct {
    name: []const u8,
    parent: ?*const HideSet,

    fn contains(set: ?*const HideSet, name: []const u8) bool {
        var cur = set;
        while (cur) |node| : (cur = node.parent) {
            if (std.mem.eql(u8, node.name, name)) return true;
        }
        return false;
    }
};

/// A token paired with its hide set.
const PpTok = struct {
    tok: Token,
    hide: ?*const HideSet = null,
};

/// One open #include'd file on the source stack.
const Frame = struct {
    /// Lexer streaming the included file's tokens.
    lexer: Lexer,
    /// Tokens read past the directive that opened this frame (the single token
    /// parked past an #include line, or the same-line leftovers after an #exe
    /// block), replayed in order once the frame is exhausted.
    resume_toks: []const Token,
    /// This file's directory, for its own relative #includes.
    dir: []const u8,
    /// Canonical path, for cycle detection ("fs:"-prefixed for embedded files).
    path: []const u8,
    /// Whether this frame's source and its relative #includes resolve against
    /// the embedded prelude table rather than the disk. Inherited by every
    /// file the frame #includes.
    embedded: bool,
    /// Index into `files`, stamped onto this frame's tokens.
    file_id: u32,
};

/// One open conditional-compilation group (#if/#ifdef/#ifndef … #endif). The
/// preprocessor consults the innermost frame to decide whether tokens and
/// ordinary directives in the current region are live.
const CondState = struct {
    /// Was the enclosing region emitting when this group opened?
    parent_active: bool,
    /// Has a branch in this group already been selected?
    taken: bool,
    /// Is the current branch the selected (emitting) one?
    active: bool,
    /// Has #else been seen? (a later #elif/#else is then an error)
    saw_else: bool = false,
    /// includes.items.len when the group opened, so an #if must be closed by an
    /// #endif within the same file (an unbalanced one is reported at that
    /// file's end).
    frame_depth: usize,
};

arena: std.mem.Allocator,
diags: *diag.Diagnostics,
/// The I/O interface disk #includes resolve through.
io: std.Io,
/// The base (top-level) source lexer, file 0.
inner: Lexer,
/// A one-token push-back for the inner stream. A directive sometimes reads one
/// token past its line and parks it here.
lookahead: ?Token = null,
/// Tokens to replay before anything else, nearest LAST (LIFO). A frame's
/// resume tokens land here when it is exhausted, so they stream out ahead of
/// the enclosing source; the parser never sees them out of order.
pushback: std.ArrayList(Token) = .empty,
/// Buffered, expanded tokens awaiting output. Stored as a stack with the
/// nearest token LAST, so taking the front and prepending macro expansions are
/// both O(1).
pending: std.ArrayList(PpTok) = .empty,
macros: std.StringArrayHashMapUnmanaged(Macro) = .empty,
base_dir: []const u8,
/// Ordered directories searched for angle-bracket #include <...> (library and
/// package includes): the -I dirs followed by the package roots
/// (HCC_PATH/pkg, HCC_ROOT/std). Each is tried in turn; first match wins.
/// Empty means angle-bracket includes cannot resolve.
include_path: []const []const u8 = &.{},
/// Maps a dependency alias (from the project's hcc.toml) to a package path, so
/// `#include <json/File.HC>` expands before resolution. A remote dependency
/// maps to its import path (searched on include_path); a local (submodule)
/// dependency maps to an absolute directory (resolved directly). Empty (no
/// hcc.toml) leaves includes untouched.
aliases: std.StringHashMapUnmanaged([]const u8) = .empty,
includes: std.ArrayList(Frame) = .empty,
/// The conditional-compilation nesting stack, innermost last. Empty means the
/// top level, which always emits.
conds: std.ArrayList(CondState) = .empty,
/// Whether the prelude was injected; its files are then reserved (a user
/// #include naming one is rejected: the prelude is implicit and always in
/// scope).
prelude_injected: bool = false,
/// The append-only table of every source file seen, indexed by span.file;
/// entry 0 is the base/top-level source. It never shrinks, so ids stay valid
/// for the whole parse.
files: std.ArrayList(source.FileInfo) = .empty,
/// The driver-injected #exe executor, or null (the language server and tests
/// leave it unset, so #exe reports it is unavailable rather than pulling the
/// backend into the frontend module).
exe_runner: ?ExeRunner = null,
exe_ctx: *anyopaque = undefined,
/// Counts spliced #exe outputs, so each generated frame gets a unique
/// synthetic path for the cycle check.
exe_gen: u32 = 0,
/// A running hash of every source buffer consumed (base + prelude + every
/// #include and #exe-spliced frame), for the driver's content-addressed build
/// cache. Each buffer is length-prefixed so distinct file splits never collide.
src_hasher: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),

pub const Options = struct {
    /// Directory that relative #include "..." paths in the top-level source
    /// resolve against; also fixes file 0's directory for privacy purposes.
    base_dir: []const u8 = ".",
    /// Seeds the predefined target macros (_WIN32/__linux__/…).
    target: ?target_mod.Target = null,
    /// Extra compiler-predefined macros.
    defines: []const Define = &.{},
    /// Injects the implicit prelude ahead of the base source, so its
    /// definitions are in scope without an explicit #include.
    inject_prelude: bool = true,
    /// Ordered search path for angle-bracket #include <...> (library/package
    /// includes): each directory is tried in turn, first match wins. Plain
    /// "..." includes ignore this and resolve relative to the including file.
    include_path: []const []const u8 = &.{},
    /// Alias → import-path map from the project's hcc.toml. See the field of
    /// the same name; empty means no alias expansion.
    aliases: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// The #exe compile-time executor and its opaque driver state. Null (the
    /// default) makes #exe report that it is unavailable.
    exe_runner: ?ExeRunner = null,
    exe_ctx: *anyopaque = undefined,
};

pub fn init(
    arena: std.mem.Allocator,
    diags: *diag.Diagnostics,
    io: std.Io,
    src: []const u8,
    opts: Options,
) Error!Preprocessor {
    var p: Preprocessor = .{
        .arena = arena,
        .diags = diags,
        .io = io,
        .inner = Lexer.init(arena, diags, src),
        .base_dir = opts.base_dir,
        .include_path = opts.include_path,
        .aliases = opts.aliases,
        .exe_runner = opts.exe_runner,
        .exe_ctx = opts.exe_ctx,
    };

    // File 0, the base/top-level source. Its privacy comes from base_dir; the
    // source has no filename, so it gets directory-based privacy only.
    // Canonicalised so its directory components line up with the canonical
    // paths of #include'd files.
    const canon = canonicalizeExisting(io, arena, opts.base_dir) catch opts.base_dir;
    try p.files.append(arena, .{ .dir = try dirComponents(arena, canon), .name = "" });
    p.hashSource(src); // the base source is the first input to the build digest

    try p.addDefines(&.{.{ .name = "__HCC__", .value = "1" }});
    if (opts.target) |tgt| try p.addDefines(targetMacros(tgt));
    try p.addDefines(opts.defines);

    if (opts.inject_prelude) try p.injectPrelude();
    return p;
}

/// Seeds compiler-predefined object-like macros, each expanding to its integer
/// value (or 1 for a non-numeric value). They are in effect from the first
/// token; a program may #undef or redefine them.
fn addDefines(p: *Preprocessor, defs: []const Define) Error!void {
    for (defs) |d| {
        const n = std.fmt.parseInt(i64, d.value, 10) catch 1;
        const body = try p.arena.alloc(Token, 1);
        body[0] = .{ .kind = .{ .int = n } };
        try p.macros.put(p.arena, d.name, .{ .body = body });
    }
}

/// Pushes the embedded prelude as the first frame on the include stack, so its
/// tokens come first; the prelude's own #includes resolve against the embedded
/// table.
fn injectPrelude(p: *Preprocessor) Error!void {
    p.prelude_injected = true;
    const file_id: u32 = @intCast(p.files.items.len);
    try p.files.append(p.arena, try fileInfoForPath(p.arena, core.root));
    p.hashSource(core.get(core.root).?);
    var lexer = Lexer.init(p.arena, p.diags, core.get(core.root).?);
    lexer.file = file_id;
    try p.includes.append(p.arena, .{
        .lexer = lexer,
        .resume_toks = &.{},
        .dir = posixDirname(core.root),
        .path = try std.fmt.allocPrint(p.arena, "fs:{s}", .{core.root}),
        .embedded = true,
        .file_id = file_id,
    });
}

/// Produces the next fully-expanded, directive-processed token. It is the only
/// method the parser needs to pull tokens.
pub fn next(p: *Preprocessor) Error!Token {
    return p.nextExpanded();
}

/// The table of source files seen, indexed by span.file; entry 0 is the base
/// source. Read after parsing to fill the program's file table.
pub fn sourceFiles(p: *const Preprocessor) []const source.FileInfo {
    return p.files.items;
}

/// Folds one source buffer into the running content digest, length-prefixed so
/// that a different split of the same bytes across files cannot collide.
fn hashSource(p: *Preprocessor, bytes: []const u8) void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, bytes.len, .little);
    p.src_hasher.update(&len);
    p.src_hasher.update(bytes);
}

/// The digest of every source buffer consumed so far. Call after parsing, when
/// all #includes and #exe splices have been read. Keys the build cache.
pub fn sourceDigest(p: *const Preprocessor) [32]u8 {
    var copy = p.src_hasher;
    var out: [32]u8 = undefined;
    copy.final(&out);
    return out;
}

fn fail(p: *Preprocessor, file: u32, pos: source.Pos, comptime fmt: []const u8, args: anytype) Error {
    return p.diags.fail(.preproc, file, pos, fmt, args);
}

/// The file id diagnostics in the current innermost source should carry.
fn currentFile(p: *const Preprocessor) u32 {
    if (p.includes.items.len > 0) {
        return p.includes.items[p.includes.items.len - 1].file_id;
    }
    return 0;
}

/// Pulls the next raw token, from the innermost open #include first, then the
/// base source. Each frame stamps its file id onto the tokens it emits; the
/// base source keeps file 0.
fn innerNext(p: *Preprocessor) Error!Token {
    if (p.pushback.items.len > 0) return p.pushback.pop().?;
    if (p.lookahead) |t| {
        p.lookahead = null;
        return t;
    }
    const n = p.includes.items.len;
    if (n > 0) {
        const frame = &p.includes.items[n - 1];
        var t = try frame.lexer.next();
        t.span.file = frame.file_id;
        return t;
    }
    return p.inner.next();
}

// ---- layer A: directives, no macro expansion ----

/// Returns the next token, handling directives. Macro names come through
/// unexpanded.
fn pull(p: *Preprocessor) Error!Token {
    while (true) {
        const t = try p.innerNext();
        switch (t.kind) {
            .eof => {
                // An included file ended. Pop its frame and resume the parent
                // stream, after checking it left no conditional open.
                const n = p.includes.items.len;
                if (n > 0) {
                    try p.checkBalanced(n, t.span.file, t.span.pos);
                    const frame = p.includes.pop().?;
                    // Replay the frame's resume tokens next, in order (they are
                    // pushed reversed onto the LIFO pushback stack).
                    var i = frame.resume_toks.len;
                    while (i > 0) {
                        i -= 1;
                        try p.pushback.append(p.arena, frame.resume_toks[i]);
                    }
                    continue;
                }
                try p.checkBalanced(0, t.span.file, t.span.pos);
                return t;
            },
            .hash => try p.directive(t),
            else => {
                // Tokens inside an unselected conditional branch are dropped.
                if (!p.emitting()) continue;
                return t;
            },
        }
    }
}

/// Handles a directive line introduced by hash.
fn directive(p: *Preprocessor, hash: Token) Error!void {
    const line = hash.span.pos.line;
    const first = try p.innerNext();
    const same_line = first.kind != .eof and first.span.pos.line == line;
    var toks: std.ArrayList(Token) = .empty;
    if (same_line) {
        try toks.append(p.arena, first);
    } else {
        p.lookahead = first; // belongs to the next line (or eof)
    }
    if (same_line) {
        while (true) {
            const t = try p.innerNext();
            if (t.kind == .eof or t.span.pos.line != line) {
                p.lookahead = t; // belongs to the next line
                break;
            }
            try toks.append(p.arena, t);
        }
    }
    if (toks.items.len == 0) return; // a lone `#`

    const name = directiveName(toks.items[0]) orelse "";
    // Conditional-compilation directives are handled even inside a skipped
    // region, so that #if … #endif nesting stays balanced; they are what
    // decide what is skipped.
    if (condDirective(name)) {
        return p.doConditional(name, toks.items, hash.span.file, hash.span.pos);
    }
    // Every other directive takes effect only where the surrounding region is
    // live.
    if (!p.emitting()) return;
    if (std.mem.eql(u8, name, "define")) return p.doDefine(toks.items);
    if (std.mem.eql(u8, name, "undef")) return p.doUndef(toks.items);
    if (std.mem.eql(u8, name, "include")) return p.doInclude(toks.items);
    if (std.mem.eql(u8, name, "exe")) return p.doExe(toks.items, hash);
    // Unknown directive, e.g. #help_index: drop it.
}

fn condDirective(name: []const u8) bool {
    const names = [_][]const u8{ "if", "ifdef", "ifndef", "elif", "else", "endif" };
    for (names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

/// Whether the current region's tokens and ordinary directives are live. False
/// inside the unselected branch of a conditional. A group is only ever active
/// when its parent was, so the innermost frame's flag is sufficient.
fn emitting(p: *const Preprocessor) bool {
    const n = p.conds.items.len;
    if (n > 0) return p.conds.items[n - 1].active;
    return true;
}

/// Reports an error if a conditional opened in the file at include
/// depth >= depth is still open, i.e. the file ended without its #endif. depth
/// is includes.items.len for a popping frame, or 0 at the base source's end.
fn checkBalanced(p: *Preprocessor, depth: usize, file: u32, pos: source.Pos) Error!void {
    const n = p.conds.items.len;
    if (n > 0 and p.conds.items[n - 1].frame_depth >= depth) {
        return p.fail(file, pos, "unterminated #if (missing #endif)", .{});
    }
}

// ---- conditional compilation ----

fn doConditional(p: *Preprocessor, name: []const u8, toks: []const Token, file: u32, pos: source.Pos) Error!void {
    if (std.mem.eql(u8, name, "elif")) return p.doElif(toks, file, pos);
    if (std.mem.eql(u8, name, "else")) return p.doElse(file, pos);
    if (std.mem.eql(u8, name, "endif")) return p.doEndif(file, pos);
    return p.pushCond(name, toks, file, pos);
}

/// Opens a new conditional group for #if/#ifdef/#ifndef. The controlling
/// expression is evaluated only when the enclosing region is live; inside an
/// already skipped region the directive only balances nesting and never errors
/// on its operand.
fn pushCond(p: *Preprocessor, name: []const u8, toks: []const Token, file: u32, pos: source.Pos) Error!void {
    const parent_active = p.emitting();
    var cond = false;
    if (parent_active) {
        cond = try p.evalCondDirective(name, toks, file, pos);
    }
    try p.conds.append(p.arena, .{
        .parent_active = parent_active,
        .taken = parent_active and cond,
        .active = parent_active and cond,
        .frame_depth = p.includes.items.len,
    });
}

/// Evaluates the controlling condition of #if/#ifdef/#ifndef.
fn evalCondDirective(p: *Preprocessor, name: []const u8, toks: []const Token, file: u32, pos: source.Pos) Error!bool {
    if (std.mem.eql(u8, name, "ifdef") or std.mem.eql(u8, name, "ifndef")) {
        const mac = try p.ifdefName(name, toks, file, pos);
        const defined = p.macros.contains(mac);
        return if (std.mem.eql(u8, name, "ifndef")) !defined else defined;
    }
    return p.evalIf(toks[1..], file, pos);
}

/// Extracts the single macro name that #ifdef/#ifndef tests.
fn ifdefName(p: *Preprocessor, name: []const u8, toks: []const Token, file: u32, pos: source.Pos) Error![]const u8 {
    if (toks.len < 2) {
        return p.fail(file, pos, "#{s} is missing a macro name", .{name});
    }
    switch (toks[1].kind) {
        .ident => |s| return s,
        else => return p.fail(toks[1].span.file, toks[1].span.pos, "#{s} expects a macro name", .{name}),
    }
}

/// #elif: take this branch iff the group's parent is live, no earlier branch
/// was taken, and the expression is true.
fn doElif(p: *Preprocessor, toks: []const Token, file: u32, pos: source.Pos) Error!void {
    const n = p.conds.items.len;
    if (n == 0) return p.fail(file, pos, "#elif without #if", .{});
    const st = &p.conds.items[n - 1];
    if (st.saw_else) return p.fail(file, pos, "#elif after #else", .{});
    if (!st.parent_active or st.taken) {
        st.active = false;
        return;
    }
    const cond = try p.evalIf(toks[1..], file, pos);
    st.active = cond;
    st.taken = st.taken or cond;
}

/// #else: take it iff the parent is live and no earlier branch was.
fn doElse(p: *Preprocessor, file: u32, pos: source.Pos) Error!void {
    const n = p.conds.items.len;
    if (n == 0) return p.fail(file, pos, "#else without #if", .{});
    const st = &p.conds.items[n - 1];
    if (st.saw_else) return p.fail(file, pos, "#else after #else", .{});
    st.saw_else = true;
    st.active = st.parent_active and !st.taken;
    st.taken = st.taken or st.active;
}

/// Closes the innermost conditional group.
fn doEndif(p: *Preprocessor, file: u32, pos: source.Pos) Error!void {
    if (p.conds.items.len == 0) return p.fail(file, pos, "#endif without #if", .{});
    _ = p.conds.pop();
}

/// Evaluates the controlling expression of #if/#elif and reports whether it is
/// non-zero. It follows C's #if rules adapted to HolyC: `defined NAME` /
/// `defined(NAME)` is resolved against the macro table first (so the operand
/// is never expanded), the rest is object-like macro-expanded, any identifier
/// still surviving is taken as 0, and the result is evaluated as an integer
/// constant expression in HolyC precedence.
fn evalIf(p: *Preprocessor, toks: []const Token, file: u32, pos: source.Pos) Error!bool {
    if (toks.len == 0) return p.fail(file, pos, "#if has no expression", .{});
    const resolved = try p.resolveDefined(toks, file, pos);
    var ev: CondEval = .{
        .p = p,
        .toks = try p.expandSlice(resolved),
        .file = file,
        .pos = pos,
    };
    const v = try ev.parse();
    return v != 0;
}

/// Replaces every `defined NAME` / `defined(NAME)` in toks with the integer 1
/// or 0, before macro expansion, so the operand name is itself never expanded.
fn resolveDefined(p: *Preprocessor, toks: []const Token, file: u32, pos: source.Pos) Error![]const Token {
    var out: std.ArrayList(Token) = .empty;
    var i: usize = 0;
    while (i < toks.len) : (i += 1) {
        const t = toks[i];
        const is_defined = switch (t.kind) {
            .ident => |s| std.mem.eql(u8, s, "defined"),
            else => false,
        };
        if (is_defined) {
            const name, const last = try p.definedOperand(toks, i + 1, file, pos);
            i = last;
            try out.append(p.arena, .{
                .kind = .{ .int = @intFromBool(p.macros.contains(name)) },
                .span = t.span,
            });
            continue;
        }
        try out.append(p.arena, t);
    }
    return out.items;
}

/// Parses the operand of `defined`, either `NAME` or `(NAME)`, starting at
/// index i. Returns the name and the index of its last consumed token.
fn definedOperand(p: *Preprocessor, toks: []const Token, i: usize, file: u32, pos: source.Pos) Error!struct { []const u8, usize } {
    if (i >= toks.len) {
        return p.fail(file, pos, "`defined` is missing a macro name", .{});
    }
    if (toks[i].kind == .l_paren) {
        if (i + 2 >= toks.len or toks[i + 1].kind != .ident or toks[i + 2].kind != .r_paren) {
            return p.fail(toks[i].span.file, toks[i].span.pos, "`defined(` expects a macro name then `)`", .{});
        }
        return .{ toks[i + 1].kind.ident, i + 2 };
    }
    switch (toks[i].kind) {
        .ident => |s| return .{ s, i },
        else => return p.fail(toks[i].span.file, toks[i].span.pos, "`defined` expects a macro name", .{}),
    }
}

/// Fully macro-expands a standalone token slice (object-like and function-like)
/// for #if/#elif expressions, reusing the argument expander. Surviving
/// identifiers are left for the evaluator to read as 0.
fn expandSlice(p: *Preprocessor, toks: []const Token) Error![]const Token {
    const pps = try p.expandArg(try p.toPp(toks, null));
    const out = try p.arena.alloc(Token, pps.len);
    for (pps, 0..) |pt, i| out[i] = pt.tok;
    return out;
}

/// A recursive-descent evaluator for a preprocessor #if integer constant
/// expression. It walks an already-expanded token slice using HolyC's operator
/// precedence (mirroring the language's infix table); a name that reaches it
/// is an undefined macro and reads as 0.
const CondEval = struct {
    p: *Preprocessor,
    toks: []const Token,
    i: usize = 0,
    /// The directive's file/position, for end-of-input errors.
    file: u32,
    pos: source.Pos,

    fn parse(e: *CondEval) Error!i64 {
        const v = try e.expr(1);
        if (e.i != e.toks.len) {
            const t = e.toks[e.i];
            return e.p.fail(t.span.file, t.span.pos, "unexpected {s} in #if expression", .{Token.Kind.describe(t.kind)});
        }
        return v;
    }

    /// Precedence climbing: parses a unary operand then folds in any infix
    /// operator whose binding power is at least min_bp. All #if operators are
    /// left-associative, so the right operand is parsed at bp+1.
    fn expr(e: *CondEval, min_bp: u8) Error!i64 {
        var lhs = try e.unary();
        while (e.i < e.toks.len) {
            const op_tok = e.toks[e.i];
            const bp = condInfixBp(op_tok.kind) orelse break;
            if (bp < min_bp) break;
            e.i += 1;
            const rhs = try e.expr(bp + 1);
            lhs = try e.applyBinop(op_tok, lhs, rhs);
        }
        return lhs;
    }

    fn unary(e: *CondEval) Error!i64 {
        if (e.i >= e.toks.len) {
            return e.p.fail(e.file, e.pos, "unexpected end of #if expression", .{});
        }
        switch (e.toks[e.i].kind) {
            .not => {
                e.i += 1;
                return @intFromBool((try e.unary()) == 0);
            },
            .tilde => {
                e.i += 1;
                return ~(try e.unary());
            },
            .minus => {
                e.i += 1;
                return -%(try e.unary());
            },
            .plus => {
                e.i += 1;
                return e.unary();
            },
            else => return e.primary(),
        }
    }

    fn primary(e: *CondEval) Error!i64 {
        const t = e.toks[e.i];
        switch (t.kind) {
            .l_paren => {
                e.i += 1;
                const v = try e.expr(1);
                if (e.i >= e.toks.len or e.toks[e.i].kind != .r_paren) {
                    return e.p.fail(t.span.file, t.span.pos, "missing `)` in #if expression", .{});
                }
                e.i += 1;
                return v;
            },
            .int => |v| {
                e.i += 1;
                return v;
            },
            .char => |v| {
                e.i += 1;
                return v;
            },
            .ident, .keyword => {
                // A name (or type/keyword) that survived expansion is not a
                // defined macro, so per C #if rules it reads as 0.
                e.i += 1;
                return 0;
            },
            .float => return e.p.fail(t.span.file, t.span.pos, "floating-point value is not allowed in #if", .{}),
            else => return e.p.fail(t.span.file, t.span.pos, "unexpected {s} in #if expression", .{Token.Kind.describe(t.kind)}),
        }
    }

    /// Applies an integer #if binary operator. Logical/relational results are
    /// 0 or 1; division or modulo by zero is an error (the expression is not
    /// short-circuited). Arithmetic wraps and out-of-range shift counts are
    /// defined (0 / sign-fill), matching the reference implementation.
    fn applyBinop(e: *CondEval, op_tok: Token, a: i64, b: i64) Error!i64 {
        return switch (op_tok.kind) {
            .star => a *% b,
            .slash => if (b == 0)
                e.p.fail(op_tok.span.file, op_tok.span.pos, "division by zero in #if", .{})
            else if (b == -1)
                -%a
            else
                @divTrunc(a, b),
            .percent => if (b == 0)
                e.p.fail(op_tok.span.file, op_tok.span.pos, "division by zero in #if", .{})
            else if (b == -1)
                0
            else
                @rem(a, b),
            .plus => a +% b,
            .minus => a -% b,
            .shl => shlWide(a, b),
            .shr => shrWide(a, b),
            .lt => @intFromBool(a < b),
            .gt => @intFromBool(a > b),
            .le => @intFromBool(a <= b),
            .ge => @intFromBool(a >= b),
            .eq_eq => @intFromBool(a == b),
            .ne => @intFromBool(a != b),
            .amp => a & b,
            .caret => a ^ b,
            .pipe => a | b,
            .and_and => @intFromBool(a != 0 and b != 0),
            .caret_caret => @intFromBool((a != 0) != (b != 0)),
            .or_or => @intFromBool(a != 0 or b != 0),
            else => e.p.fail(op_tok.span.file, op_tok.span.pos, "internal: unknown #if operator", .{}),
        };
    }
};

/// The binding power of an infix operator valid in an #if integer expression,
/// mirroring the language's infix table (higher binds tighter).
fn condInfixBp(k: Token.Kind) ?u8 {
    return switch (k) {
        .or_or => 1,
        .caret_caret => 2,
        .and_and => 3,
        .eq_eq, .ne => 4,
        .lt, .gt, .le, .ge => 5,
        .plus, .minus => 6,
        .pipe => 7,
        .caret => 8,
        .amp => 9,
        .star, .slash, .percent => 10,
        .shl, .shr => 11,
        else => null,
    };
}

/// `a << b` with the count treated as unsigned and counts >= 64 giving 0.
fn shlWide(a: i64, b: i64) i64 {
    const ub: u64 = @bitCast(b);
    if (ub >= 64) return 0;
    return a << @intCast(ub);
}

/// `a >> b` (arithmetic) with counts >= 64 giving the sign fill.
fn shrWide(a: i64, b: i64) i64 {
    const ub: u64 = @bitCast(b);
    if (ub >= 64) return a >> 63;
    return a >> @intCast(ub);
}

// ---- #define / #undef / #include ----

fn doDefine(p: *Preprocessor, toks: []const Token) Error!void {
    if (toks.len < 2) {
        return p.fail(toks[0].span.file, toks[0].span.pos, "#define is missing a macro name", .{});
    }
    const name = switch (toks[1].kind) {
        .ident => |s| s,
        else => return p.fail(toks[1].span.file, toks[1].span.pos, "macro name must be an identifier", .{}),
    };
    // Function-like macro iff a `(` directly abuts the name with no whitespace
    // (the C rule that distinguishes `#define F(x) …` from `#define F (x) …`).
    // Adjacency is read from the spans: same file, `(` starting where the name
    // ended.
    if (toks.len >= 3 and toks[2].kind == .l_paren and
        toks[2].span.file == toks[1].span.file and toks[2].span.start == toks[1].span.end)
    {
        var params: std.ArrayList([]const u8) = .empty;
        var variadic = false;
        var i: usize = 3;
        if (i < toks.len and toks[i].kind == .r_paren) {
            i += 1; // empty parameter list: F()
        } else {
            while (true) {
                if (i >= toks.len) return p.fail(toks[0].span.file, toks[0].span.pos, "unterminated macro parameter list", .{});
                switch (toks[i].kind) {
                    .ident => |pn| try params.append(p.arena, pn),
                    .dot_dot_dot => variadic = true,
                    else => return p.fail(toks[i].span.file, toks[i].span.pos, "macro parameter must be an identifier", .{}),
                }
                i += 1;
                if (i >= toks.len) return p.fail(toks[0].span.file, toks[0].span.pos, "unterminated macro parameter list", .{});
                if (toks[i].kind == .r_paren) {
                    i += 1;
                    break;
                }
                if (variadic) return p.fail(toks[i].span.file, toks[i].span.pos, "`...` must be the last macro parameter", .{});
                if (toks[i].kind != .comma) return p.fail(toks[i].span.file, toks[i].span.pos, "expected `,` or `)` in macro parameters", .{});
                i += 1;
            }
        }
        try p.macros.put(p.arena, name, .{
            .params = params.items,
            .variadic = variadic,
            .body = try p.arena.dupe(Token, toks[i..]),
        });
        return;
    }
    // Object-like: everything after the name is the replacement body.
    try p.macros.put(p.arena, name, .{ .body = try p.arena.dupe(Token, toks[2..]) });
}

fn doUndef(p: *Preprocessor, toks: []const Token) Error!void {
    if (toks.len < 2 or toks[1].kind != .ident) {
        return p.fail(toks[0].span.file, toks[0].span.pos, "#undef is missing a macro name", .{});
    }
    _ = p.macros.swapRemove(toks[1].kind.ident);
}

/// Resolves and opens an include directive: read the file and push it onto the
/// source stack so its tokens stream in next. A plain "path" resolves relative
/// to the including file's directory; a "::"-prefixed path searches the
/// current directory and each ancestor (TempleOS upward search). Cycles and
/// excessive nesting are rejected.
fn doInclude(p: *Preprocessor, toks: []const Token) Error!void {
    const file = toks[0].span.file;
    const pos = toks[0].span.pos;
    // Angle-bracket form #include <path>: a library/package include resolved
    // against the include path, never relative to the including file.
    if (toks.len >= 2 and toks[1].kind == .lt) {
        return p.doIncludeAngle(toks, file, pos);
    }
    if (toks.len < 2 or toks[1].kind != .str) {
        return p.fail(file, pos, "#include expects a \"path\" or <path>", .{});
    }
    const path_str = toks[1].kind.str;
    var cur_dir = p.base_dir;
    var embedded = false;
    const n = p.includes.items.len;
    if (n > 0) {
        cur_dir = p.includes.items[n - 1].dir;
        embedded = p.includes.items[n - 1].embedded;
    }
    if (std.mem.startsWith(u8, path_str, "::")) {
        var suffix = path_str[2..];
        suffix = std.mem.trimStart(u8, suffix, "/");
        if (!embedded) {
            if (p.reservedPrelude(suffix)) |name| {
                return p.reservedPreludeErr(name, file, pos);
            }
        }
        return p.includeUpward(suffix, cur_dir, embedded, path_str, file, pos);
    }
    if (embedded) {
        // The prelude (and anything it #includes) lives in the embedded table;
        // resolve there with forward-slash paths, never touching the disk.
        const joined = try posixJoinClean(p.arena, cur_dir, path_str);
        return p.openIncludeEmbedded(joined, path_str, file, pos);
    }
    // User (disk) #include: a path naming a prelude file is reserved.
    if (p.reservedPrelude(path_str)) |name| {
        return p.reservedPreludeErr(name, file, pos);
    }
    const joined = try std.fs.path.join(p.arena, &.{ cur_dir, path_str });
    const canon = canonicalizeExisting(p.io, p.arena, joined) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return p.fail(file, pos, "cannot open #include \"{s}\": {s}", .{ path_str, @errorName(e) }),
    };
    return p.openInclude(canon, path_str, file, pos, try fileInfoForDisk(p.arena, canon));
}

/// Resolves an angle-bracket #include <path> against the include path. The
/// lexer has no directive context, so <path> arrives as `lt … gt` operator
/// tokens rather than a string; the path is recovered from the raw source
/// between the brackets (whitespace-insensitive, exact). Each include-path
/// directory is tried in order; the first that resolves wins. Unlike "...",
/// this never searches relative to the including file — library and package
/// names live only on the include path.
fn doIncludeAngle(p: *Preprocessor, toks: []const Token, file: u32, pos: source.Pos) Error!void {
    var gt_idx: ?usize = null;
    for (toks[2..], 2..) |t, i| {
        if (t.kind == .gt) {
            gt_idx = i;
            break;
        }
    }
    const gt = gt_idx orelse
        return p.fail(file, pos, "unterminated #include <...>: missing '>'", .{});
    // The header name is the raw text between '<' and '>' in the file the
    // directive is in. All directive-line tokens share that file, so the
    // innermost frame's (or base) source is the right buffer to slice.
    const src = p.currentSource();
    const name = std.mem.trim(u8, src[toks[1].span.end..toks[gt].span.start], " \t");
    if (name.len == 0) return p.fail(file, pos, "#include <> has an empty path", .{});
    // A dependency alias (from hcc.toml) expands to its full import path before
    // resolution; a bare `<Str.HC>` has no leading segment to match and falls
    // through to the stdlib path unchanged.
    const resolved = try p.expandAlias(name);
    // A prelude file is implicit and always in scope, angle brackets or not.
    if (p.reservedPrelude(resolved)) |pn| return p.reservedPreludeErr(pn, file, pos);
    // A local (submodule) alias expands to an absolute directory, so it resolves
    // straight to a file rather than being searched on the pkg/std path.
    if (std.fs.path.isAbsolute(resolved)) {
        if (canonicalizeExisting(p.io, p.arena, resolved)) |canon| {
            return p.openInclude(canon, name, file, pos, try fileInfoForDisk(p.arena, canon));
        } else |e| if (e == error.OutOfMemory) return error.OutOfMemory;
        return p.fail(file, pos, "cannot find #include <{s}> (local dependency {s})", .{ name, resolved });
    }
    for (p.include_path) |root| {
        const joined = try std.fs.path.join(p.arena, &.{ root, resolved });
        if (canonicalizeExisting(p.io, p.arena, joined)) |canon| {
            return p.openInclude(canon, name, file, pos, try fileInfoForDisk(p.arena, canon));
        } else |e| if (e == error.OutOfMemory) return error.OutOfMemory;
    }
    return p.fail(file, pos, "cannot find #include <{s}> on the include path", .{name});
}

/// Expands a leading dependency alias in an angle-include path to its full
/// import path: `json/Json.HC` → `github.com/terry/json/Json.HC` when hcc.toml
/// maps `json`. Only the first path segment is matched; a single-segment name
/// (no `/`) or an unknown segment is returned unchanged, so stdlib and
/// full-path includes are unaffected.
fn expandAlias(p: *Preprocessor, name: []const u8) Error![]const u8 {
    if (p.aliases.count() == 0) return name;
    const slash = std.mem.indexOfScalar(u8, name, '/') orelse return name;
    const full = p.aliases.get(name[0..slash]) orelse return name;
    return std.fmt.allocPrint(p.arena, "{s}{s}", .{ full, name[slash..] });
}

/// The source buffer of the file currently being read (the innermost include
/// frame, or the base source at the top level). Recovers raw text the token
/// stream doesn't preserve, e.g. an angle-bracket header name.
fn currentSource(p: *Preprocessor) []const u8 {
    const n = p.includes.items.len;
    if (n > 0) return p.includes.items[n - 1].lexer.src;
    return p.inner.src;
}

/// Handles an #exe compile-time block: `#exe { …HolyC… }`. The block is
/// compiled and run at compile time (via the driver-injected executor); its
/// stdout is spliced back in as source exactly where the directive stood, so it
/// can generate declarations or tables. The block sees the current file's
/// preceding text (its own functions and types are in scope) and the implicit
/// prelude; its body runs as top-level statements.
///
/// The lexer has no directive context, so the body arrives as ordinary tokens.
/// The block is delimited by matching braces, and the raw body text is
/// recovered from the source between the opening '{' and its matching '}'.
fn doExe(p: *Preprocessor, toks: []const Token, hash: Token) Error!void {
    const file = toks[0].span.file;
    const pos = toks[0].span.pos;

    // Scan for the opening '{' and its matching '}'. Tokens come from the
    // collected directive-line tokens first (index 1 skips the "exe" name),
    // then the live stream, which may span many lines.
    var ti: usize = 1;
    const open = try p.nextExeTok(toks, &ti);
    if (open.kind != .l_brace)
        return p.fail(open.span.file, open.span.pos, "#exe expects a '{{' to open its block", .{});
    var depth: usize = 1;
    var close: Token = undefined;
    while (true) {
        const t = try p.nextExeTok(toks, &ti);
        switch (t.kind) {
            .l_brace => depth += 1,
            .r_brace => {
                depth -= 1;
                if (depth == 0) {
                    close = t;
                    break;
                }
            },
            .eof => return p.fail(file, pos, "unterminated #exe block: missing '}}'", .{}),
            else => {},
        }
    }

    // The body and the file text preceding the directive both live in the
    // buffer currently being read. All the scanned tokens share it, so the
    // brace spans index into it directly.
    const src = p.currentSource();
    const body = src[open.span.end..close.span.start];
    const prefix = src[0..hash.span.start];
    const leftover = toks[ti..]; // any same-line tokens after '}'

    // With no executor (the language server and tests supply none, so the
    // backend stays out of the frontend module), the block cannot run: skip it
    // silently rather than erroring, so an #exe file still analyzes in the
    // editor. Any same-line tokens after '}' still resume in order.
    const runner = p.exe_runner orelse {
        var i = leftover.len;
        while (i > 0) {
            i -= 1;
            try p.pushback.append(p.arena, leftover[i]);
        }
        return;
    };

    // The compile-time unit: the file up to the directive (so the block can
    // call functions and reference types declared earlier), then the body as
    // top-level statements. Its stdout becomes the spliced source.
    const unit = try std.fmt.allocPrint(p.arena, "{s}\n{s}\n", .{ prefix, body });

    // A generated frame inherits the current file's include base and privacy.
    var dir_for_includes = p.base_dir;
    var embedded = false;
    if (p.includes.items.len > 0) {
        const top = p.includes.items[p.includes.items.len - 1];
        dir_for_includes = top.dir;
        embedded = top.embedded;
    }

    switch (runner(p.exe_ctx, p.arena, p.io, unit, p.base_dir)) {
        .err => |msg| return p.fail(file, pos, "#exe block failed: {s}", .{msg}),
        .ok => |out_text| {
            p.exe_gen += 1;
            const gen_path = try std.fmt.allocPrint(p.arena, "exe:{d}", .{p.exe_gen});
            const info = source.FileInfo{ .dir = p.files.items[file].dir, .name = "<exe>" };
            try p.pushFrame(gen_path, dir_for_includes, out_text, "<exe>", file, pos, info, embedded, leftover);
        },
    }
}

/// The next token of an #exe block scan: the collected directive-line tokens
/// (toks[ti..]) first, then the live inner stream.
fn nextExeTok(p: *Preprocessor, toks: []const Token, ti: *usize) Error!Token {
    if (ti.* < toks.len) {
        const t = toks[ti.*];
        ti.* += 1;
        return t;
    }
    return p.innerNext();
}

/// Resolves a "::"-prefixed include (TempleOS upward search): tries suffix in
/// cur_dir, then in each ancestor directory, taking the first that exists.
fn includeUpward(p: *Preprocessor, suffix: []const u8, cur_dir: []const u8, embedded: bool, display: []const u8, file: u32, pos: source.Pos) Error!void {
    if (embedded) {
        var dir = try posixClean(p.arena, cur_dir);
        while (true) {
            const cand = try posixJoinClean(p.arena, dir, suffix);
            if (core.exists(cand)) {
                return p.openIncludeEmbedded(cand, display, file, pos);
            }
            const parent = posixDirname(dir);
            if (std.mem.eql(u8, parent, dir)) break;
            dir = parent;
        }
        return p.fail(file, pos, "cannot find #include \"{s}\" by upward search", .{display});
    }
    var dir = canonicalizeExisting(p.io, p.arena, cur_dir) catch cur_dir;
    while (true) {
        const joined = try std.fs.path.join(p.arena, &.{ dir, suffix });
        if (canonicalizeExisting(p.io, p.arena, joined)) |canon| {
            return p.openInclude(canon, display, file, pos, try fileInfoForDisk(p.arena, canon));
        } else |e| if (e == error.OutOfMemory) return error.OutOfMemory;
        const parent = std.fs.path.dirname(dir) orelse break;
        if (std.mem.eql(u8, parent, dir)) break;
        dir = parent;
    }
    return p.fail(file, pos, "cannot find #include \"{s}\" by upward search", .{display});
}

/// Whether a user (disk) #include path names a file in the injected prelude,
/// returning the cleaned name. Prelude files are implicit and always in scope,
/// so a program must not #include them directly.
fn reservedPrelude(p: *Preprocessor, path_str: []const u8) ?[]const u8 {
    if (!p.prelude_injected) return null;
    const clean = posixClean(p.arena, path_str) catch return null;
    if (clean.len == 0 or std.mem.eql(u8, clean, ".")) return null;
    if (core.exists(clean)) return clean;
    return null;
}

/// The diagnostic for a program that tries to #include a prelude file directly.
fn reservedPreludeErr(p: *Preprocessor, name: []const u8, file: u32, pos: source.Pos) Error {
    return p.fail(file, pos, "cannot #include \"{s}\": it is part of the implicit prelude and is always in scope", .{name});
}

/// Reads an already-resolved canonical include path from disk and pushes it
/// onto the source stack, after the cycle and depth checks. display is the
/// original spelling, used in error messages.
fn openInclude(p: *Preprocessor, canon: []const u8, display: []const u8, file: u32, pos: source.Pos, info: source.FileInfo) Error!void {
    const contents = std.Io.Dir.cwd().readFileAlloc(p.io, canon, p.arena, .limited(64 << 20)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return p.fail(file, pos, "cannot read #include \"{s}\": {s}", .{ display, @errorName(e) }),
    };
    const dir = std.fs.path.dirname(canon) orelse ".";
    return p.pushFrame(canon, dir, contents, display, file, pos, info, false, &.{});
}

/// Reads an include resolved within the embedded prelude table and pushes it
/// onto the source stack. fs_path is the cleaned forward-slash path, which the
/// new frame inherits for its own relative #includes.
fn openIncludeEmbedded(p: *Preprocessor, fs_path: []const u8, display: []const u8, file: u32, pos: source.Pos) Error!void {
    const contents = core.get(fs_path) orelse
        return p.fail(file, pos, "cannot read #include \"{s}\": FileNotFound", .{display});
    const key = try std.fmt.allocPrint(p.arena, "fs:{s}", .{fs_path});
    return p.pushFrame(key, posixDirname(fs_path), contents, display, file, pos, try fileInfoForPath(p.arena, fs_path), true, &.{});
}

/// Pushes an include (or #exe-generated) source onto the source stack, after
/// the cycle and depth checks. path identifies the frame for the cycle check;
/// dir is the base for that file's relative includes. extra_resume tokens (the
/// same-line leftovers after an #exe block; empty for a plain #include) replay
/// first when the frame is exhausted, ahead of the token parked past the
/// directive line.
fn pushFrame(p: *Preprocessor, path: []const u8, dir: []const u8, contents: []const u8, display: []const u8, file: u32, pos: source.Pos, info: source.FileInfo, embedded: bool, extra_resume: []const Token) Error!void {
    for (p.includes.items) |f| {
        if (std.mem.eql(u8, f.path, path)) {
            return p.fail(file, pos, "recursive #include of \"{s}\"", .{display});
        }
    }
    if (p.includes.items.len >= max_include_depth) {
        return p.fail(file, pos, "#include nested too deeply", .{});
    }
    // Resume tokens replayed once the frame is exhausted: the extra_resume
    // leftovers first, then the single token already read past the directive
    // line.
    var resume_list: std.ArrayList(Token) = .empty;
    try resume_list.appendSlice(p.arena, extra_resume);
    if (p.lookahead) |t| try resume_list.append(p.arena, t);
    p.lookahead = null;
    p.hashSource(contents); // every included / #exe-spliced buffer feeds the digest
    // Register this file; its id is stamped onto the frame's tokens and the
    // table never shrinks, so ids stay valid for the whole parse.
    const file_id: u32 = @intCast(p.files.items.len);
    try p.files.append(p.arena, info);
    var lexer = Lexer.init(p.arena, p.diags, contents);
    lexer.file = file_id;
    try p.includes.append(p.arena, .{
        .lexer = lexer,
        .resume_toks = resume_list.items,
        .dir = dir,
        .path = path,
        .embedded = embedded,
        .file_id = file_id,
    });
}

// ---- layer B: macro expansion ----

fn ensurePending(p: *Preprocessor) Error!void {
    if (p.pending.items.len == 0) {
        const t = try p.pull();
        try p.pending.append(p.arena, .{ .tok = t });
    }
}

fn take(p: *Preprocessor) Error!PpTok {
    try p.ensurePending();
    return p.pending.pop().?;
}

/// The fully-expanded next token. Object-like macros prepend their body for
/// rescan; a function-like macro expands only when its name is immediately
/// followed by `(`, otherwise the name is left as an ordinary identifier.
fn nextExpanded(p: *Preprocessor) Error!Token {
    while (true) {
        const pt = try p.take();
        if (pt.tok.kind == .ident) {
            const name = pt.tok.kind.ident;
            if (!HideSet.contains(pt.hide, name)) {
                if (p.macros.get(name)) |m| {
                    if (m.params == null) {
                        try p.pushExpansion(&p.pending, try p.toPp(m.body, pt.hide), name);
                        continue;
                    }
                    // Function-like: peek for the `(` that makes it a call.
                    const nxt = try p.take();
                    if (nxt.tok.kind == .l_paren) {
                        const raw = try p.collectArgsStream();
                        const args = try p.checkArgs(m, raw, pt.tok);
                        const exp = try p.substitute(m, args, pt.hide);
                        try p.pushExpansion(&p.pending, exp, name);
                        continue;
                    }
                    // Not a call: put the peeked token back and emit the name.
                    try p.pending.append(p.arena, nxt);
                    return pt.tok;
                }
            }
        }
        return pt.tok;
    }
}

/// Wraps plain body tokens as PpToks carrying a base hide set (for object-like
/// bodies, whose tokens have no per-token hide of their own).
fn toPp(p: *Preprocessor, body: []const Token, hide: ?*const HideSet) Error![]const PpTok {
    const out = try p.arena.alloc(PpTok, body.len);
    for (body, 0..) |t, i| out[i] = .{ .tok = t, .hide = hide };
    return out;
}

/// Pushes an expansion onto the front of a queue (nearest LAST), adding `mac`
/// to each token's hide set so `mac` is not re-expanded within its own
/// expansion. Each token keeps whatever hide it already carried (e.g. from
/// argument pre-expansion), so nested expansions stay correctly guarded.
fn pushExpansion(p: *Preprocessor, queue: *std.ArrayList(PpTok), exp: []const PpTok, mac: []const u8) Error!void {
    try queue.ensureUnusedCapacity(p.arena, exp.len);
    var i = exp.len;
    while (i > 0) {
        i -= 1;
        const node = try p.arena.create(HideSet);
        node.* = .{ .name = mac, .parent = exp[i].hide };
        queue.appendAssumeCapacity(.{ .tok = exp[i].tok, .hide = node });
    }
}

/// Whether tok is a parameter of m, returning its index.
fn paramIndex(m: Macro, tok: Token) ?usize {
    const ps = m.params orelse return null;
    if (tok.kind != .ident) return null;
    for (ps, 0..) |pn, i| {
        if (std.mem.eql(u8, pn, tok.kind.ident)) return i;
    }
    return null;
}

/// Whether tok is `__VA_ARGS__` in a variadic macro.
fn isVaArgs(m: Macro, tok: Token) bool {
    return m.variadic and tok.kind == .ident and std.mem.eql(u8, tok.kind.ident, "__VA_ARGS__");
}

/// Whether body[i], body[i+1] form the `##` paste operator: two `#` tokens with
/// no space between them (so a stray `# #` is not mistaken for a paste).
fn isPasteOp(body: []const Token, i: usize) bool {
    return i + 1 < body.len and body[i].kind == .hash and body[i + 1].kind == .hash and
        body[i].span.file == body[i + 1].span.file and body[i].span.end == body[i + 1].span.start;
}

/// Collects a function-like macro's arguments from the main token stream, the
/// opening `(` already consumed, up to the matching `)`. Arguments are split on
/// top-level commas; commas inside nested parentheses stay within an argument.
fn collectArgsStream(p: *Preprocessor) Error![]const []const PpTok {
    var args: std.ArrayList([]const PpTok) = .empty;
    var cur: std.ArrayList(PpTok) = .empty;
    var depth: usize = 0;
    var comma_seen = false;
    while (true) {
        const pt = try p.take();
        switch (pt.tok.kind) {
            .eof => return p.fail(pt.tok.span.file, pt.tok.span.pos, "unterminated macro argument list", .{}),
            .r_paren => {
                if (depth == 0) break;
                depth -= 1;
                try cur.append(p.arena, pt);
            },
            .l_paren => {
                depth += 1;
                try cur.append(p.arena, pt);
            },
            .comma => {
                if (depth == 0) {
                    try args.append(p.arena, cur.items);
                    cur = .empty;
                    comma_seen = true;
                } else try cur.append(p.arena, pt);
            },
            else => try cur.append(p.arena, pt),
        }
    }
    if (!comma_seen and cur.items.len == 0) return &.{}; // `()`
    try args.append(p.arena, cur.items);
    return args.items;
}

/// Like collectArgsStream but reading from a local work stack (used while
/// pre-expanding an argument), the opening `(` already popped.
fn collectArgsStack(p: *Preprocessor, work: *std.ArrayList(PpTok)) Error![]const []const PpTok {
    var args: std.ArrayList([]const PpTok) = .empty;
    var cur: std.ArrayList(PpTok) = .empty;
    var depth: usize = 0;
    var comma_seen = false;
    while (true) {
        if (work.items.len == 0) return p.fail(0, .{}, "unterminated macro argument list", .{});
        const pt = work.pop().?;
        switch (pt.tok.kind) {
            .r_paren => {
                if (depth == 0) break;
                depth -= 1;
                try cur.append(p.arena, pt);
            },
            .l_paren => {
                depth += 1;
                try cur.append(p.arena, pt);
            },
            .comma => {
                if (depth == 0) {
                    try args.append(p.arena, cur.items);
                    cur = .empty;
                    comma_seen = true;
                } else try cur.append(p.arena, pt);
            },
            else => try cur.append(p.arena, pt),
        }
    }
    if (!comma_seen and cur.items.len == 0) return &.{};
    try args.append(p.arena, cur.items);
    return args.items;
}

/// Validates argument arity and normalizes the `F()` case (a single empty
/// argument when one is expected). Returns the possibly-adjusted arg list.
fn checkArgs(p: *Preprocessor, m: Macro, args: []const []const PpTok, name_tok: Token) Error![]const []const PpTok {
    const named = m.params.?.len;
    var a = args;
    if (a.len == 0 and named >= 1) {
        const one = try p.arena.alloc([]const PpTok, 1);
        one[0] = &.{};
        a = one;
    }
    const nm = name_tok.kind.ident;
    if (m.variadic) {
        if (a.len < named) return p.fail(name_tok.span.file, name_tok.span.pos, "macro `{s}` expects at least {d} argument(s), got {d}", .{ nm, named, a.len });
    } else if (a.len != named) {
        return p.fail(name_tok.span.file, name_tok.span.pos, "macro `{s}` expects {d} argument(s), got {d}", .{ nm, named, a.len });
    }
    return a;
}

/// The variadic arguments (those past the named parameters) rejoined with the
/// commas that separated them, for `__VA_ARGS__`.
fn vaRaw(p: *Preprocessor, m: Macro, args: []const []const PpTok) Error![]const PpTok {
    var out: std.ArrayList(PpTok) = .empty;
    var idx = m.params.?.len;
    var first = true;
    while (idx < args.len) : (idx += 1) {
        if (!first) try out.append(p.arena, .{ .tok = .{ .kind = .comma } });
        first = false;
        try out.appendSlice(p.arena, args[idx]);
    }
    return out.items;
}

/// Fully expands a token sequence in isolation, used to pre-expand a macro
/// argument before it is substituted into positions not adjacent to `#`/`##`
/// (the C rule that makes nested calls and the STR/XSTR idiom work). A
/// function-like macro whose `(` lies outside the sequence is left unexpanded.
fn expandArg(p: *Preprocessor, input: []const PpTok) Error![]const PpTok {
    var out: std.ArrayList(PpTok) = .empty;
    var work: std.ArrayList(PpTok) = .empty;
    var i = input.len;
    while (i > 0) {
        i -= 1;
        try work.append(p.arena, input[i]);
    }
    while (work.items.len > 0) {
        const pt = work.pop().?;
        if (pt.tok.kind == .ident and !HideSet.contains(pt.hide, pt.tok.kind.ident)) {
            const name = pt.tok.kind.ident;
            if (p.macros.get(name)) |m| {
                if (m.params == null) {
                    try p.pushExpansion(&work, try p.toPp(m.body, pt.hide), name);
                    continue;
                }
                if (work.items.len > 0 and work.items[work.items.len - 1].tok.kind == .l_paren) {
                    _ = work.pop();
                    const raw = try p.collectArgsStack(&work);
                    const args = try p.checkArgs(m, raw, pt.tok);
                    const exp = try p.substitute(m, args, pt.hide);
                    try p.pushExpansion(&work, exp, name);
                    continue;
                }
            }
        }
        try out.append(p.arena, pt);
    }
    return out.items;
}

/// A stringized form of an argument: the tokens' spellings joined by single
/// spaces. Stored as the (already-decoded) value of a string token.
fn stringize(p: *Preprocessor, arg: []const PpTok) Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (arg, 0..) |a, idx| {
        if (idx > 0) try buf.append(p.arena, ' ');
        try buf.appendSlice(p.arena, try p.spell(a.tok));
    }
    return buf.items;
}

/// The source spelling of a token, for `#` stringize and `##` paste.
fn spell(p: *Preprocessor, t: Token) Error![]const u8 {
    return switch (t.kind) {
        .ident => |s| s,
        .keyword => |k| k.spelling(),
        .int => |v| try std.fmt.allocPrint(p.arena, "{d}", .{v}),
        .float => |v| try std.fmt.allocPrint(p.arena, "{d}", .{v}),
        .str => |s| try std.fmt.allocPrint(p.arena, "\"{s}\"", .{s}),
        .char => |v| try std.fmt.allocPrint(p.arena, "'{d}'", .{v}),
        else => token_mod.Token.Kind.describe(t.kind),
    };
}

/// Pastes two tokens by concatenating their spellings and re-lexing; null if
/// that yields nothing.
fn paste(p: *Preprocessor, a: Token, b: Token) Error!?Token {
    const text = try std.fmt.allocPrint(p.arena, "{s}{s}", .{ try p.spell(a), try p.spell(b) });
    if (text.len == 0) return null;
    var lx = Lexer.init(p.arena, p.diags, text);
    const first = lx.next() catch return null;
    if (first.kind == .eof) return null;
    return first;
}

/// Produces a function-like macro's expansion for a call, given the collected
/// (raw) arguments. Parameters in ordinary positions are pre-expanded;
/// parameters that are operands of `#` or `##` use their raw form. `base_hide`
/// is the hide set of the invoking name, applied to body-origin tokens.
fn substitute(p: *Preprocessor, m: Macro, args: []const []const PpTok, base_hide: ?*const HideSet) Error![]const PpTok {
    var out: std.ArrayList(PpTok) = .empty;
    const body = m.body;
    var i: usize = 0;
    while (i < body.len) {
        // `##` token paste: operands are the last emitted token and the token
        // (or raw argument) after the operator.
        if (isPasteOp(body, i)) {
            const ri = i + 2;
            // GNU comma elision: `, ## __VA_ARGS__` drops the comma when the
            // variadic arguments are empty, and otherwise just appends them.
            if (ri < body.len and isVaArgs(m, body[ri])) {
                const va = try p.vaRaw(m, args);
                if (va.len == 0) {
                    if (out.items.len > 0 and out.items[out.items.len - 1].tok.kind == .comma) _ = out.pop();
                } else {
                    for (va) |a| try out.append(p.arena, .{ .tok = a.tok, .hide = base_hide });
                }
                i = ri + 1;
                continue;
            }
            const left: ?Token = if (out.items.len > 0) out.pop().?.tok else null;
            var right: ?Token = null;
            var rest: []const PpTok = &.{};
            if (ri < body.len) {
                if (paramIndex(m, body[ri])) |pi| {
                    if (args[pi].len > 0) {
                        right = args[pi][0].tok;
                        rest = args[pi][1..];
                    }
                } else right = body[ri];
            }
            if (left != null and right != null) {
                if (try p.paste(left.?, right.?)) |tok| try out.append(p.arena, .{ .tok = tok, .hide = base_hide });
            } else if (left) |l| {
                try out.append(p.arena, .{ .tok = l, .hide = base_hide });
            } else if (right) |r| {
                try out.append(p.arena, .{ .tok = r, .hide = base_hide });
            }
            for (rest) |a| try out.append(p.arena, .{ .tok = a.tok, .hide = base_hide });
            i = if (ri < body.len) ri + 1 else ri;
            continue;
        }
        // `#` stringize: a single `#` before a parameter.
        if (body[i].kind == .hash and i + 1 < body.len) {
            if (paramIndex(m, body[i + 1])) |pi| {
                const s = try p.stringize(args[pi]);
                try out.append(p.arena, .{ .tok = .{ .kind = .{ .str = s } }, .hide = base_hide });
                i += 2;
                continue;
            }
            if (isVaArgs(m, body[i + 1])) {
                const s = try p.stringize(try p.vaRaw(m, args));
                try out.append(p.arena, .{ .tok = .{ .kind = .{ .str = s } }, .hide = base_hide });
                i += 2;
                continue;
            }
        }
        // A parameter (not consumed as a `##` right operand above): raw when it
        // is the left operand of a following `##`, else pre-expanded.
        if (paramIndex(m, body[i])) |pi| {
            if (isPasteOp(body, i + 1)) {
                for (args[pi]) |a| try out.append(p.arena, .{ .tok = a.tok, .hide = base_hide });
            } else {
                try out.appendSlice(p.arena, try p.expandArg(args[pi]));
            }
            i += 1;
            continue;
        }
        if (isVaArgs(m, body[i])) {
            const va = try p.vaRaw(m, args);
            if (isPasteOp(body, i + 1)) {
                for (va) |a| try out.append(p.arena, .{ .tok = a.tok, .hide = base_hide });
            } else {
                try out.appendSlice(p.arena, try p.expandArg(va));
            }
            i += 1;
            continue;
        }
        try out.append(p.arena, .{ .tok = body[i], .hide = base_hide });
        i += 1;
    }
    return out.items;
}

// ---- free helpers ----

/// The directive keyword after `#`, or null if tok is not a directive name.
/// Most directive names lex as identifiers; `if` and `else` are keywords, so
/// they are mapped back here.
fn directiveName(tok: Token) ?[]const u8 {
    switch (tok.kind) {
        .ident => |s| return s,
        .keyword => |k| switch (k) {
            .@"else" => return "else",
            .@"if" => return "if",
            else => return null,
        },
        else => return null,
    }
}

/// Resolves path to an absolute, symlink-free path, erroring if it does not
/// exist. The include resolver uses that error to detect a missing file.
fn canonicalizeExisting(io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(io, path, arena);
}

/// The meaningful path components of a directory (skipping the root, `.`, and
/// `..`), giving each source file a directory for `_`-privacy.
fn dirComponents(arena: std.mem.Allocator, dir: []const u8) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, dir, std.fs.path.sep);
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) continue;
        try out.append(arena, part);
    }
    return out.items;
}

/// The FileInfo of a file on disk, from its parent directory and its own
/// filename.
fn fileInfoForDisk(arena: std.mem.Allocator, path: []const u8) Error!source.FileInfo {
    const dir = std.fs.path.dirname(path) orelse "";
    return .{
        .dir = try dirComponents(arena, dir),
        .name = std.fs.path.basename(path),
    };
}

/// The FileInfo of a file in the embedded prelude, from its forward-slash
/// path: the directory components (for `_`-privacy) and the base name.
fn fileInfoForPath(arena: std.mem.Allocator, fs_path: []const u8) Error!source.FileInfo {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, posixDirname(fs_path), '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) continue;
        try out.append(arena, part);
    }
    var base = fs_path;
    if (std.mem.lastIndexOfScalar(u8, fs_path, '/')) |i| base = fs_path[i + 1 ..];
    return .{ .dir = out.items, .name = base };
}

/// The directory of a forward-slash path, mirroring Go's path.Dir: no slash
/// gives ".", and the parent of "." is "." (which terminates upward walks).
fn posixDirname(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return ".";
    if (i == 0) return "/";
    return path[0..i];
}

/// Lexically cleans a forward-slash path (resolving "." and ".."), mirroring
/// Go's path.Clean for the relative paths the prelude uses.
fn posixClean(arena: std.mem.Allocator, path: []const u8) Error![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len > 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
                _ = parts.pop();
                continue;
            }
            try parts.append(arena, part);
            continue;
        }
        try parts.append(arena, part);
    }
    if (parts.items.len == 0) return ".";
    const joined = try std.mem.join(arena, "/", parts.items);
    return joined;
}

fn posixJoinClean(arena: std.mem.Allocator, dir: []const u8, path: []const u8) Error![]const u8 {
    const joined = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, path });
    return posixClean(arena, joined);
}

/// The predefined platform object-like macros for a target (each expands
/// to 1), available for conditional compilation. __HCC__ is always defined
/// separately; the arch/OS macros follow the target's arch and OS.
fn targetMacros(tgt: target_mod.Target) []const Define {
    const one = struct {
        fn d(name: []const u8) Define {
            return .{ .name = name, .value = "1" };
        }
    }.d;
    const arch: []const Define = switch (tgt.arch) {
        .amd64 => &.{one("__amd64__")},
        .arm64 => &.{one("__arm64__")},
        .riscv64 => &.{one("__riscv64__")},
        .ppc64le => &.{one("__ppc64le__")},
        .s390x => &.{one("__s390x__")},
    };
    const os: []const Define = switch (tgt.os) {
        .darwin => &.{ one("__APPLE__"), one("__MACH__"), one("__unix__") },
        .linux => &.{ one("__linux__"), one("__unix__") },
        .windows => &.{ one("_WIN32"), one("_WIN64") },
    };
    // Both lists are comptime-known singletons; concatenate into a static
    // buffer per combination via a small switch instead of allocating.
    return concatDefines(arch, os);
}

/// Concatenates two small comptime-backed Define slices without allocating,
/// by returning a slice of a static table when possible.
fn concatDefines(a: []const Define, b: []const Define) []const Define {
    // The combinations are tiny and callers copy the macros out immediately via
    // addDefines, so a thread-local scratch buffer suffices.
    const S = struct {
        threadlocal var buf: [8]Define = undefined;
    };
    var n: usize = 0;
    for (a) |d| {
        S.buf[n] = d;
        n += 1;
    }
    for (b) |d| {
        S.buf[n] = d;
        n += 1;
    }
    return S.buf[0..n];
}

// ---- tests ----

const testing = std.testing;

const TestPp = struct {
    arena_state: *std.heap.ArenaAllocator,
    diags: *diag.Diagnostics,
    pp: *Preprocessor,

    fn init(src: []const u8, opts: Options) !TestPp {
        const arena_state = try testing.allocator.create(std.heap.ArenaAllocator);
        errdefer testing.allocator.destroy(arena_state);
        arena_state.* = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();
        const diags = try arena.create(diag.Diagnostics);
        diags.* = diag.Diagnostics.init(arena);
        const pp = try arena.create(Preprocessor);
        pp.* = try Preprocessor.init(arena, diags, testing.io, src, opts);
        return .{ .arena_state = arena_state, .diags = diags, .pp = pp };
    }

    fn deinit(t: *TestPp) void {
        t.arena_state.deinit();
        testing.allocator.destroy(t.arena_state);
    }

    /// Drains the stream, returning the tokens before eof.
    fn drain(t: *TestPp) ![]Token {
        var out: std.ArrayList(Token) = .empty;
        while (true) {
            const tok = try t.pp.next();
            if (tok.kind == .eof) return out.items;
            try out.append(t.arena_state.allocator(), tok);
        }
    }
};

test "object-like define expands with hide set" {
    var t = try TestPp.init(
        \\#define N 42
        \\#define SELF SELF
        \\N SELF
    , .{ .inject_prelude = false });
    defer t.deinit();
    const toks = try t.drain();
    try testing.expectEqual(@as(usize, 2), toks.len);
    try testing.expectEqual(@as(i64, 42), toks[0].kind.int);
    try testing.expectEqualStrings("SELF", toks[1].kind.ident);
}

test "define body is a token sequence and undef removes it" {
    var t = try TestPp.init(
        \\#define TWO 1 + 1
        \\TWO
        \\#undef TWO
        \\TWO
    , .{ .inject_prelude = false });
    defer t.deinit();
    const toks = try t.drain();
    // "1 + 1" then the bare identifier TWO.
    try testing.expectEqual(@as(usize, 4), toks.len);
    try testing.expect(toks[1].kind == .plus);
    try testing.expectEqualStrings("TWO", toks[3].kind.ident);
}

test "function-like macro expands with arguments" {
    var t = try TestPp.init(
        \\#define SQ(x) ((x) * (x))
        \\SQ(3 + 1)
    , .{ .inject_prelude = false });
    defer t.deinit();
    const toks = try t.drain();
    // ((3 + 1) * (3 + 1)), 13 tokens.
    try testing.expectEqual(@as(usize, 13), toks.len);
    try testing.expect(toks[0].kind == .l_paren);
    try testing.expectEqual(@as(i64, 3), toks[2].kind.int);
    try testing.expect(toks[6].kind == .star);
}

test "function-like name without parens stays an identifier" {
    var t = try TestPp.init(
        \\#define F(x) x
        \\F + F(5)
    , .{ .inject_prelude = false });
    defer t.deinit();
    const toks = try t.drain();
    // The bare F is left alone; F(5) expands to 5.
    try testing.expectEqual(@as(usize, 3), toks.len);
    try testing.expectEqualStrings("F", toks[0].kind.ident);
    try testing.expect(toks[1].kind == .plus);
    try testing.expectEqual(@as(i64, 5), toks[2].kind.int);
}

test "argument pre-expansion: nested calls and STR/XSTR idiom" {
    var t = try TestPp.init(
        \\#define STR(x) #x
        \\#define XSTR(x) STR(x)
        \\#define VER 3
        \\STR(VER) XSTR(VER)
    , .{ .inject_prelude = false });
    defer t.deinit();
    const toks = try t.drain();
    // STR(VER) is raw -> "VER"; XSTR(VER) pre-expands -> "3".
    try testing.expectEqual(@as(usize, 2), toks.len);
    try testing.expectEqualStrings("VER", toks[0].kind.str);
    try testing.expectEqualStrings("3", toks[1].kind.str);
}

test "token paste with ##" {
    var t = try TestPp.init(
        \\#define CAT(a, b) a ## b
        \\CAT(foo, bar)
    , .{ .inject_prelude = false });
    defer t.deinit();
    const toks = try t.drain();
    try testing.expectEqual(@as(usize, 1), toks.len);
    try testing.expectEqualStrings("foobar", toks[0].kind.ident);
}

test "variadic macro and GNU comma elision" {
    var t = try TestPp.init(
        \\#define P(fmt, ...) fmt, ## __VA_ARGS__
        \\P(1)
        \\P(1, 2, 3)
    , .{ .inject_prelude = false });
    defer t.deinit();
    const toks = try t.drain();
    // P(1) -> 1 (comma dropped); P(1,2,3) -> 1 , 2 , 3
    try testing.expectEqual(@as(usize, 6), toks.len);
    try testing.expectEqual(@as(i64, 1), toks[0].kind.int);
    try testing.expectEqual(@as(i64, 1), toks[1].kind.int);
    try testing.expect(toks[2].kind == .comma);
    try testing.expectEqual(@as(i64, 2), toks[3].kind.int);
    try testing.expect(toks[4].kind == .comma);
    try testing.expectEqual(@as(i64, 3), toks[5].kind.int);
}

test "wrong function-like macro arity is rejected" {
    var t = try TestPp.init(
        \\#define ADD(a, b) a + b
        \\ADD(1)
    , .{ .inject_prelude = false });
    defer t.deinit();
    try testing.expectError(error.CompileFailed, t.drain());
    try testing.expect(std.mem.indexOf(u8, t.diags.firstError().?.message, "expects 2") != null);
}

test "conditionals: ifdef/else/endif and #if expressions" {
    var t = try TestPp.init(
        \\#define YES 1
        \\#ifdef YES
        \\1
        \\#else
        \\2
        \\#endif
        \\#ifndef NO
        \\3
        \\#endif
        \\#if defined(YES) && (2 + 2 == 4) && !UNDEF_NAME
        \\4
        \\#elif 1
        \\5
        \\#endif
    , .{ .inject_prelude = false });
    defer t.deinit();
    const toks = try t.drain();
    try testing.expectEqual(@as(usize, 3), toks.len);
    try testing.expectEqual(@as(i64, 1), toks[0].kind.int);
    try testing.expectEqual(@as(i64, 3), toks[1].kind.int);
    try testing.expectEqual(@as(i64, 4), toks[2].kind.int);
}

test "target macros seed conditionals" {
    var t = try TestPp.init(
        \\#ifdef __linux__
        \\1
        \\#endif
        \\#ifdef __APPLE__
        \\2
        \\#endif
        \\#if __HCC__
        \\3
        \\#endif
    , .{
        .inject_prelude = false,
        .target = .{ .arch = .amd64, .os = .linux },
    });
    defer t.deinit();
    const toks = try t.drain();
    try testing.expectEqual(@as(usize, 2), toks.len);
    try testing.expectEqual(@as(i64, 1), toks[0].kind.int);
    try testing.expectEqual(@as(i64, 3), toks[1].kind.int);
}

test "unbalanced #if is reported at end of file" {
    var t = try TestPp.init("#if 1\n1\n", .{ .inject_prelude = false });
    defer t.deinit();
    var got_err = false;
    while (true) {
        const tok = t.pp.next() catch {
            got_err = true;
            break;
        };
        if (tok.kind == .eof) break;
    }
    try testing.expect(got_err);
    try testing.expect(std.mem.indexOf(u8, t.diags.firstError().?.message, "missing #endif") != null);
}

test "#exe with no executor is skipped, not an error" {
    // The language server runs the frontend without an executor; an #exe file
    // must still analyze without a spurious error. The block is dropped and the
    // following code resumes.
    var t = try TestPp.init("#exe { anything(); }\n30\n", .{ .inject_prelude = false });
    defer t.deinit();
    const toks = try t.drain();
    try testing.expectEqual(@as(usize, 1), toks.len);
    try testing.expectEqual(@as(i64, 30), toks[0].kind.int);
}

/// A fake #exe executor for the hermetic tests: it ignores the unit and splices
/// a fixed source string, so the splice/resume machinery is exercised without
/// the backend (which the frontend module must not link).
fn fakeExeRunner(ctx: *anyopaque, arena: std.mem.Allocator, io: std.Io, unit: []const u8, base_dir: []const u8) ExeResult {
    _ = arena;
    _ = io;
    _ = unit;
    _ = base_dir;
    const out: *const []const u8 = @ptrCast(@alignCast(ctx));
    return .{ .ok = out.* };
}

test "#exe splices the executor output as source" {
    var generated: []const u8 = "10 + 20";
    var t = try TestPp.init("#exe { anything }\n30\n", .{
        .inject_prelude = false,
        .exe_runner = fakeExeRunner,
        .exe_ctx = @ptrCast(&generated),
    });
    defer t.deinit();
    const toks = try t.drain();
    // The spliced "10 + 20" streams in where the directive stood, then the 30
    // that followed it resumes after the generated frame.
    try testing.expectEqual(@as(usize, 4), toks.len);
    try testing.expectEqual(@as(i64, 10), toks[0].kind.int);
    try testing.expect(toks[1].kind == .plus);
    try testing.expectEqual(@as(i64, 20), toks[2].kind.int);
    try testing.expectEqual(@as(i64, 30), toks[3].kind.int);
}

test "#exe multi-line block with nested braces, then following code resumes" {
    var generated: []const u8 = "1";
    var t = try TestPp.init(
        \\#exe {
        \\  if (x) { y; }
        \\}
        \\2
    , .{
        .inject_prelude = false,
        .exe_runner = fakeExeRunner,
        .exe_ctx = @ptrCast(&generated),
    });
    defer t.deinit();
    const toks = try t.drain();
    // The nested { } inside the block does not end it early; the block is
    // replaced by "1" and the trailing 2 resumes after it.
    try testing.expectEqual(@as(usize, 2), toks.len);
    try testing.expectEqual(@as(i64, 1), toks[0].kind.int);
    try testing.expectEqual(@as(i64, 2), toks[1].kind.int);
}

test "unterminated #exe block is reported" {
    var generated: []const u8 = "";
    var t = try TestPp.init("#exe { no close brace\n", .{
        .inject_prelude = false,
        .exe_runner = fakeExeRunner,
        .exe_ctx = @ptrCast(&generated),
    });
    defer t.deinit();
    try testing.expectError(error.CompileFailed, t.drain());
    try testing.expect(std.mem.indexOf(u8, t.diags.firstError().?.message, "unterminated") != null);
}

test "prelude injection streams the whole embedded library" {
    var t = try TestPp.init("I64 x;\n", .{
        .target = target_mod.Target.host(),
    });
    defer t.deinit();
    const toks = try t.drain();
    // The prelude contributes thousands of tokens ahead of the base source,
    // and the base source's tokens come last.
    try testing.expect(toks.len > 1000);
    try testing.expect(toks[toks.len - 1].kind == .semicolon);
    const kw = toks[toks.len - 3].kind.keyword;
    try testing.expectEqual(token_mod.Keyword.I64, kw);
    // Every prelude file (plus the base source) landed in the file table.
    try testing.expectEqual(core.files.len + 1, t.pp.sourceFiles().len);
    try testing.expect(!t.diags.hasErrors());
}

test "user #include of a prelude file is reserved" {
    var t = try TestPp.init("#include \"KConfig.HC\"\n", .{
        .target = target_mod.Target.host(),
    });
    defer t.deinit();
    var failed = false;
    while (true) {
        const tok = t.pp.next() catch {
            failed = true;
            break;
        };
        if (tok.kind == .eof) break;
    }
    try testing.expect(failed);
    try testing.expect(std.mem.indexOf(u8, t.diags.firstError().?.message, "implicit prelude") != null);
}

test "disk includes: relative, nested, upward search, and cycles" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub/inner");
    try tmp.dir.writeFile(io, .{ .sub_path = "top.HC", .data = "1\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/a.HC", .data = "#include \"inner/b.HC\"\n2\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/inner/b.HC", .data = "#include \"::top.HC\"\n3\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "cycle.HC", .data = "#include \"cycle.HC\"\n" });

    const base = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base);

    {
        var t = try TestPp.init("#include \"sub/a.HC\"\n9\n", .{
            .inject_prelude = false,
            .base_dir = base,
        });
        defer t.deinit();
        const toks = try t.drain();
        // b.HC's upward search finds top.HC (1), then b's own 3, a's 2, base 9.
        try testing.expectEqual(@as(usize, 4), toks.len);
        try testing.expectEqual(@as(i64, 1), toks[0].kind.int);
        try testing.expectEqual(@as(i64, 3), toks[1].kind.int);
        try testing.expectEqual(@as(i64, 2), toks[2].kind.int);
        try testing.expectEqual(@as(i64, 9), toks[3].kind.int);
        // File table: base + a.HC + b.HC + top.HC.
        try testing.expectEqual(@as(usize, 4), t.pp.sourceFiles().len);
    }
    {
        var t = try TestPp.init("#include \"cycle.HC\"\n", .{
            .inject_prelude = false,
            .base_dir = base,
        });
        defer t.deinit();
        try testing.expectError(error.CompileFailed, t.pp.next());
        try testing.expect(std.mem.indexOf(u8, t.diags.firstError().?.message, "recursive #include") != null);
    }
    {
        var t = try TestPp.init("#include \"missing.HC\"\n", .{
            .inject_prelude = false,
            .base_dir = base,
        });
        defer t.deinit();
        try testing.expectError(error.CompileFailed, t.pp.next());
    }
}

test "angle-bracket includes resolve against the search path in order" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "a");
    try tmp.dir.createDirPath(io, "b");
    try tmp.dir.createDirPath(io, "pkg/example.com/lib");
    // Dup.HC exists in both roots; the first on the path must win.
    try tmp.dir.writeFile(io, .{ .sub_path = "a/Dup.HC", .data = "10\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b/Dup.HC", .data = "20\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b/Only.HC", .data = "30\n" });
    // A domain-qualified (subdir) name, as a third-party package would use.
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/example.com/lib/Pkg.HC", .data = "40\n" });

    const a = try tmp.dir.realPathFileAlloc(io, "a", testing.allocator);
    defer testing.allocator.free(a);
    const b = try tmp.dir.realPathFileAlloc(io, "b", testing.allocator);
    defer testing.allocator.free(b);
    const pkg = try tmp.dir.realPathFileAlloc(io, "pkg", testing.allocator);
    defer testing.allocator.free(pkg);
    const path = [_][]const u8{ a, b, pkg };

    {
        // Dup resolves in `a` (10, not `b`'s 20); Only only in `b` (30); Pkg by
        // its subdir path under `pkg` (40). The header name is recovered from
        // the raw `<...>` span, which the token stream doesn't preserve.
        var t = try TestPp.init(
            "#include <Dup.HC>\n#include <Only.HC>\n#include <example.com/lib/Pkg.HC>\n",
            .{ .inject_prelude = false, .include_path = &path },
        );
        defer t.deinit();
        const toks = try t.drain();
        try testing.expectEqual(@as(usize, 3), toks.len);
        try testing.expectEqual(@as(i64, 10), toks[0].kind.int);
        try testing.expectEqual(@as(i64, 30), toks[1].kind.int);
        try testing.expectEqual(@as(i64, 40), toks[2].kind.int);
    }
    {
        // Not on any root → a clear "include path" error.
        var t = try TestPp.init("#include <Nope.HC>\n", .{
            .inject_prelude = false,
            .include_path = &path,
        });
        defer t.deinit();
        try testing.expectError(error.CompileFailed, t.pp.next());
        try testing.expect(std.mem.indexOf(u8, t.diags.firstError().?.message, "include path") != null);
    }
}

test "an hcc.toml alias expands to its import path in angle includes" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "pkg/example.com/lib");
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/example.com/lib/Pkg.HC", .data = "40\n" });

    const pkg = try tmp.dir.realPathFileAlloc(io, "pkg", testing.allocator);
    defer testing.allocator.free(pkg);
    const path = [_][]const u8{pkg};

    // hcc.toml aliases `lib` to the import path `example.com/lib`.
    var aliases: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer aliases.deinit(testing.allocator);
    try aliases.put(testing.allocator, "lib", "example.com/lib");

    {
        // <lib/Pkg.HC> expands to <example.com/lib/Pkg.HC> and resolves (40).
        var t = try TestPp.init(
            "#include <lib/Pkg.HC>\n",
            .{ .inject_prelude = false, .include_path = &path, .aliases = aliases },
        );
        defer t.deinit();
        const toks = try t.drain();
        try testing.expectEqual(@as(usize, 1), toks.len);
        try testing.expectEqual(@as(i64, 40), toks[0].kind.int);
    }
    {
        // The full import path still works with the alias map present.
        var t = try TestPp.init(
            "#include <example.com/lib/Pkg.HC>\n",
            .{ .inject_prelude = false, .include_path = &path, .aliases = aliases },
        );
        defer t.deinit();
        const toks = try t.drain();
        try testing.expectEqual(@as(usize, 1), toks.len);
        try testing.expectEqual(@as(i64, 40), toks[0].kind.int);
    }
    {
        // An unknown leading segment is left untouched (no false expansion).
        var t = try TestPp.init("#include <nope/Pkg.HC>\n", .{
            .inject_prelude = false,
            .include_path = &path,
            .aliases = aliases,
        });
        defer t.deinit();
        try testing.expectError(error.CompileFailed, t.pp.next());
        try testing.expect(std.mem.indexOf(u8, t.diags.firstError().?.message, "include path") != null);
    }
}

test "a local (absolute) alias resolves directly, off the search path" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "mylib");
    try tmp.dir.writeFile(io, .{ .sub_path = "mylib/Sub.HC", .data = "50\n" });

    const libdir = try tmp.dir.realPathFileAlloc(io, "mylib", testing.allocator);
    defer testing.allocator.free(libdir);

    // A local submodule alias maps to an absolute directory.
    var aliases: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer aliases.deinit(testing.allocator);
    try aliases.put(testing.allocator, "sub", libdir);

    // No include_path at all: the alias resolves straight to the file.
    var t = try TestPp.init(
        "#include <sub/Sub.HC>\n",
        .{ .inject_prelude = false, .aliases = aliases },
    );
    defer t.deinit();
    const toks = try t.drain();
    try testing.expectEqual(@as(usize, 1), toks.len);
    try testing.expectEqual(@as(i64, 50), toks[0].kind.int);
}

test "include guards make double inclusion a no-op" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "g.HC", .data =
        \\#ifndef G_HC
        \\#define G_HC
        \\7
        \\#endif
    });
    const base = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base);

    var t = try TestPp.init("#include \"g.HC\"\n#include \"g.HC\"\n8\n", .{
        .inject_prelude = false,
        .base_dir = base,
    });
    defer t.deinit();
    const toks = try t.drain();
    try testing.expectEqual(@as(usize, 2), toks.len);
    try testing.expectEqual(@as(i64, 7), toks[0].kind.int);
    try testing.expectEqual(@as(i64, 8), toks[1].kind.int);
}
