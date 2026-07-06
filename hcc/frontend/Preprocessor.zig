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

/// A compiler-predefined object-like macro: NAME expands to the integer value
/// (or 1 when value is not a decimal integer). Used to seed platform macros.
pub const Define = struct {
    name: []const u8,
    value: []const u8,
};

/// One entry in the macro table. HolyC has only object-like macros, so a macro
/// is just its replacement body.
const Macro = struct {
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
    /// Token read past the #include line in the parent, re-queued on
    /// exhaustion.
    resume_tok: ?Token,
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
/// Buffered, expanded tokens awaiting output. Stored as a stack with the
/// nearest token LAST, so taking the front and prepending macro expansions are
/// both O(1).
pending: std.ArrayList(PpTok) = .empty,
macros: std.StringArrayHashMapUnmanaged(Macro) = .empty,
base_dir: []const u8,
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
    };

    // File 0, the base/top-level source. Its privacy comes from base_dir; the
    // source has no filename, so it gets directory-based privacy only.
    // Canonicalised so its directory components line up with the canonical
    // paths of #include'd files.
    const canon = canonicalizeExisting(io, arena, opts.base_dir) catch opts.base_dir;
    try p.files.append(arena, .{ .dir = try dirComponents(arena, canon), .name = "" });

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
    var lexer = Lexer.init(p.arena, p.diags, core.get(core.root).?);
    lexer.file = file_id;
    try p.includes.append(p.arena, .{
        .lexer = lexer,
        .resume_tok = null,
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
                    p.lookahead = frame.resume_tok;
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
    if (std.mem.eql(u8, name, "exe")) {
        // #exe (compile-time execution) is not supported. Report it explicitly
        // rather than dropping it like an unknown directive, since its `{ … }`
        // body would otherwise leak into the stream as ordinary code.
        return p.fail(hash.span.file, hash.span.pos, "#exe (compile-time execution) is no longer supported", .{});
    }
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
/// already skipped region the directive just balances nesting and never errors
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

/// Fully object-like-macro-expands a standalone token slice, mirroring the
/// main expander (nextExpanded) but over a private queue rather than the
/// output stream. Used for #if/#elif expressions; surviving identifiers are
/// left for the evaluator to read as 0.
fn expandSlice(p: *Preprocessor, toks: []const Token) Error![]const Token {
    // A stack with the nearest token last.
    var queue: std.ArrayList(PpTok) = .empty;
    try queue.ensureTotalCapacity(p.arena, toks.len);
    var i = toks.len;
    while (i > 0) {
        i -= 1;
        queue.appendAssumeCapacity(.{ .tok = toks[i] });
    }
    var out: std.ArrayList(Token) = .empty;
    while (queue.pop()) |pt| {
        if (pt.tok.kind == .ident) {
            const name = pt.tok.kind.ident;
            if (!HideSet.contains(pt.hide, name)) {
                if (p.macros.get(name)) |m| {
                    try p.prependWithHide(&queue, m.body, name, pt.hide);
                    continue;
                }
            }
        }
        try out.append(p.arena, pt.tok);
    }
    return out.items;
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
    // HolyC has only object-like #define (no function-like macros), so
    // everything after the name is the replacement body. `#define F(x) x+1`
    // defines F as the token sequence `(x) x+1`.
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
    if (toks.len < 2 or toks[1].kind != .str) {
        return p.fail(file, pos, "#include expects a \"path\"", .{});
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
    return p.pushFrame(canon, dir, contents, display, file, pos, info, false);
}

/// Reads an include resolved within the embedded prelude table and pushes it
/// onto the source stack. fs_path is the cleaned forward-slash path, which the
/// new frame inherits for its own relative #includes.
fn openIncludeEmbedded(p: *Preprocessor, fs_path: []const u8, display: []const u8, file: u32, pos: source.Pos) Error!void {
    const contents = core.get(fs_path) orelse
        return p.fail(file, pos, "cannot read #include \"{s}\": FileNotFound", .{display});
    const key = try std.fmt.allocPrint(p.arena, "fs:{s}", .{fs_path});
    return p.pushFrame(key, posixDirname(fs_path), contents, display, file, pos, try fileInfoForPath(p.arena, fs_path), true);
}

/// Pushes an include source onto the source stack, after the cycle and depth
/// checks. path identifies the frame for the cycle check; dir is the base for
/// that file's relative includes.
fn pushFrame(p: *Preprocessor, path: []const u8, dir: []const u8, contents: []const u8, display: []const u8, file: u32, pos: source.Pos, info: source.FileInfo, embedded: bool) Error!void {
    for (p.includes.items) |f| {
        if (std.mem.eql(u8, f.path, path)) {
            return p.fail(file, pos, "recursive #include of \"{s}\"", .{display});
        }
    }
    if (p.includes.items.len >= max_include_depth) {
        return p.fail(file, pos, "#include nested too deeply", .{});
    }
    // The token already read past the #include line resumes the parent once
    // the included file is exhausted.
    const resume_tok = p.lookahead;
    p.lookahead = null;
    // Register this file; its id is stamped onto the frame's tokens and the
    // table never shrinks, so ids stay valid for the whole parse.
    const file_id: u32 = @intCast(p.files.items.len);
    try p.files.append(p.arena, info);
    var lexer = Lexer.init(p.arena, p.diags, contents);
    lexer.file = file_id;
    try p.includes.append(p.arena, .{
        .lexer = lexer,
        .resume_tok = resume_tok,
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

/// The fully-expanded next token.
fn nextExpanded(p: *Preprocessor) Error!Token {
    while (true) {
        const pt = try p.take();
        if (pt.tok.kind == .ident) {
            const name = pt.tok.kind.ident;
            if (!HideSet.contains(pt.hide, name)) {
                if (p.macros.get(name)) |m| {
                    try p.prependWithHide(&p.pending, m.body, name, pt.hide);
                    continue;
                }
            }
        }
        return pt.tok;
    }
}

/// Pushes replacement tokens to the front of a pending stack (nearest last),
/// each carrying base_hide plus mac so mac is not re-expanded within its own
/// expansion.
fn prependWithHide(p: *Preprocessor, queue: *std.ArrayList(PpTok), body: []const Token, mac: []const u8, base_hide: ?*const HideSet) Error!void {
    const node = try p.arena.create(HideSet);
    node.* = .{ .name = mac, .parent = base_hide };
    try queue.ensureUnusedCapacity(p.arena, body.len);
    var i = body.len;
    while (i > 0) {
        i -= 1;
        queue.appendAssumeCapacity(.{ .tok = body[i], .hide = node });
    }
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
    // The combinations are tiny; build a global fixed table lazily is
    // overkill. Since callers immediately copy the macros into the table via
    // addDefines, use a static thread-local scratch.
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

test "#exe is rejected" {
    var t = try TestPp.init("#exe {1;}\n", .{ .inject_prelude = false });
    defer t.deinit();
    try testing.expectError(error.CompileFailed, t.pp.next());
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
