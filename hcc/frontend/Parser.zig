//! The HolyC parser: turns the preprocessor's token stream into an AST
//! Program.
//!
//! It is a hand-written recursive-descent parser with precedence climbing for
//! expressions. It pulls tokens from the Preprocessor on demand through a
//! small look-ahead buffer, lexing only as far ahead as the grammar needs.
//! The first parse error stops the pass: it is recorded in the shared
//! Diagnostics and `error.CompileFailed` unwinds the recursion out of parse.
//!
//! The pass covers functions, variable declarations, classes (including
//! anonymous embedded unions/structs and inline instance declarations), the
//! full statement and expression grammar, inline asm, and
//! base/pointer/array/function-pointer types. It stops at the syntactic
//! Program; semantic analysis and layout are later passes.

const std = @import("std");
const source = @import("source.zig");
const diag = @import("diag.zig");
const token_mod = @import("token.zig");
const Token = token_mod.Token;
const Keyword = token_mod.Keyword;
const Preprocessor = @import("Preprocessor.zig");
const ast = @import("ast.zig");

const Parser = @This();

pub const Error = diag.Error;

/// Bounds expression/statement/type nesting so pathological input fails with a
/// parse error instead of overflowing the stack.
const max_parse_depth = 256;

/// Bounds how far the declaration-shape probes scan ahead (e.g. past a
/// parameter list to decide whether an implicit-return function definition
/// follows). Real parameter lists are far shorter; the cap guards pathological
/// input.
const max_decl_lookahead = 8192;

arena: std.mem.Allocator,
diags: *diag.Diagnostics,
/// The token source.
pp: *Preprocessor,
/// The look-ahead buffer; buf.items[head] is the current token. Tokens before
/// head are consumed. Once every buffered token is consumed the buffer resets,
/// so it only grows as far as the deepest look-ahead probe.
buf: std.ArrayList(Token) = .empty,
head: usize = 0,
/// Byte offset just past the last consumed token, used as the end of node
/// spans.
prev_end: usize = 0,
/// Names known to be class/union types. Grows during parsing: a class name
/// becomes a type-start only after its definition is seen, which drives
/// cast-vs-paren and declaration disambiguation.
known: std.StringArrayHashMapUnmanaged(void) = .empty,
depth: usize = 0,
/// Statements a single parse step produced in addition to its primary result.
/// Inline instance declarations (`class Foo {…} a;`) yield both a ClassDef and
/// a following VarDecl, and anonymous embedded unions/structs yield a
/// synthetic aggregate. The statement-list loops (top level and blocks) drain
/// it after each item.
queued: std.ArrayList(*ast.Stmt) = .empty,
/// Synthetic ClassDefs for anonymous aggregate *types* (`class {…} x;`), which
/// may be written deep inside a local declaration or parameter list but must
/// surface as top-level items so the type table and layout pass register them.
/// parse() appends these to the program's items after the main loop.
hoisted: std.ArrayList(*ast.Stmt) = .empty,
/// Names successive anonymous embedded aggregates uniquely.
anon_count: usize = 0,

pub fn init(arena: std.mem.Allocator, diags: *diag.Diagnostics, pp: *Preprocessor) Parser {
    return .{ .arena = arena, .diags = diags, .pp = pp };
}

/// Consumes the whole token stream and returns the AST Program, with the
/// preprocessor's source-file table copied on as parse provenance.
pub fn parse(p: *Parser) Error!ast.Program {
    var items: std.ArrayList(*ast.Stmt) = .empty;
    while (true) {
        const t = try p.peek();
        if (t.kind == .eof) break;
        const s = try p.parseTopLevel();
        try items.append(p.arena, s);
        try p.drainQueuedInto(&items);
    }
    // Anonymous aggregate types synthesized anywhere (including inside
    // function bodies) are appended as top-level ClassDefs so they reach the
    // type table. The layout pass is order-independent, so trailing
    // definitions resolve.
    try items.appendSlice(p.arena, p.hoisted.items);
    p.hoisted.clearRetainingCapacity();
    return .{
        .items = try items.toOwnedSlice(p.arena),
        .files = p.pp.sourceFiles(),
    };
}

/// Appends and clears any statements queued by the last parse step.
fn drainQueuedInto(p: *Parser, list: *std.ArrayList(*ast.Stmt)) Error!void {
    if (p.queued.items.len == 0) return;
    try list.appendSlice(p.arena, p.queued.items);
    p.queued.clearRetainingCapacity();
}

/// Captures the start of a node at the current token.
const Mark = struct {
    start: usize,
    pos: source.Pos,
    file: u32,
};

fn enterRecursion(p: *Parser) Error!void {
    p.depth += 1;
    if (p.depth > max_parse_depth) {
        return p.failAt(p.curSpan(), "input nested too deeply", .{});
    }
}

/// Records a positioned parse error and returns error.CompileFailed.
fn failAt(p: *Parser, span: source.Span, comptime fmt: []const u8, args: anytype) Error {
    return p.diags.fail(.parse, span.file, span.pos, fmt, args);
}

// ---- token buffer / look-ahead ----

/// Lexes forward until the buffer holds more than n unconsumed tokens, or the
/// stream ends.
fn ensure(p: *Parser, n: usize) Error!void {
    while (p.buf.items.len - p.head <= n) {
        if (p.buf.items.len > p.head and p.buf.items[p.buf.items.len - 1].kind == .eof) {
            return;
        }
        const t = try p.pp.next();
        try p.buf.append(p.arena, t);
    }
}

/// Looks n tokens ahead (0 == current), lexing as needed. Past the end of the
/// stream it reports end-of-input.
fn peekN(p: *Parser, n: usize) Error!Token {
    try p.ensure(n);
    if (p.head + n < p.buf.items.len) return p.buf.items[p.head + n];
    if (p.buf.items.len > p.head) {
        const last = p.buf.items[p.buf.items.len - 1];
        if (last.kind == .eof) return last;
        return .{ .kind = .eof, .span = .{
            .start = last.span.end,
            .end = last.span.end,
            .pos = last.span.pos,
            .file = last.span.file,
        } };
    }
    return .{ .kind = .eof };
}

fn peek(p: *Parser) Error!Token {
    return p.peekN(0);
}

fn advance(p: *Parser) Error!Token {
    const t = try p.peek();
    if (t.kind != .eof) {
        p.head += 1;
        if (p.head == p.buf.items.len) {
            p.buf.clearRetainingCapacity();
            p.head = 0;
        }
    }
    p.prev_end = t.span.end;
    return t;
}

/// The current token's span, for diagnostics. It reads only the
/// already-buffered token (never lexes), so it cannot fail; call sites reach
/// it after a successful peek, with the current token in hand.
fn curSpan(p: *Parser) source.Span {
    if (p.head < p.buf.items.len) return p.buf.items[p.head].span;
    return .{};
}

fn mark(p: *Parser) Error!Mark {
    const t = try p.peek();
    return .{ .start = t.span.start, .pos = t.span.pos, .file = t.span.file };
}

fn finish(p: *Parser, m: Mark) source.Span {
    return .{ .start = m.start, .end = p.prev_end, .pos = m.pos, .file = m.file };
}

fn newExpr(p: *Parser, kind: ast.Expr.Kind, m: Mark) Error!*ast.Expr {
    const e = try p.arena.create(ast.Expr);
    e.* = .{ .kind = kind, .span = p.finish(m) };
    return e;
}

fn newStmt(p: *Parser, kind: ast.Stmt.Kind, m: Mark) Error!*ast.Stmt {
    const s = try p.arena.create(ast.Stmt);
    s.* = .{ .kind = kind, .span = p.finish(m) };
    return s;
}

fn allocType(p: *Parser, ty: ast.Type) Error!*ast.Type {
    const out = try p.arena.create(ast.Type);
    out.* = ty;
    return out;
}

fn at(p: *Parser, kind: Token.Kind.Tag) Error!bool {
    const t = try p.peek();
    return t.kind == kind;
}

fn atKw(p: *Parser, kw: Keyword) Error!bool {
    const t = try p.peek();
    return t.kind == .keyword and t.kind.keyword == kw;
}

fn eat(p: *Parser, kind: Token.Kind.Tag) Error!bool {
    if (!(try p.at(kind))) return false;
    _ = try p.advance();
    return true;
}

fn eatKw(p: *Parser, kw: Keyword) Error!bool {
    if (!(try p.atKw(kw))) return false;
    _ = try p.advance();
    return true;
}

fn expect(p: *Parser, kind: Token.Kind.Tag, what: []const u8) Error!Token {
    const t = try p.peek();
    if (t.kind != kind) {
        return p.failAt(t.span, "expected {s}, found {s}", .{ what, Token.Kind.describe(t.tag()) });
    }
    return p.advance();
}

fn expectIdent(p: *Parser) Error![]const u8 {
    const t = try p.peek();
    switch (t.kind) {
        .ident => |s| {
            _ = try p.advance();
            return s;
        },
        else => return p.failAt(t.span, "expected identifier, found {s}", .{Token.Kind.describe(t.tag())}),
    }
}

// ---- program ----

/// Parses one program-level item. Unlike parseStmt it permits the constructs
/// that are legal only at file scope: function definitions, `public`
/// declarations, and the extern forms. A plain type start may introduce either
/// a function or a global variable, so it routes through parseTopLevelDecl;
/// class definitions and every other construct are ordinary statements and
/// defer to parseStmtInner.
fn parseTopLevel(p: *Parser) Error!*ast.Stmt {
    try p.enterRecursion();
    defer p.depth -= 1;

    const m = try p.mark();
    const t = try p.peek();

    if (t.kind == .keyword) {
        switch (t.kind.keyword) {
            // A leading `public` introduces an exported declaration.
            .public => {
                _ = try p.advance();
                return p.parsePublicDecl(m);
            },
            // `_extern <LABEL> <sig>;` (and `_import`): a typed HolyC name
            // forward-bound to an asm-defined label. The declaration has no
            // body; call sites emit a call to the label, which a top-level
            // `asm {}` block defines.
            ._extern, ._import => {
                _ = try p.advance();
                return p.parseAsmExternDecl(m);
            },
            // `extern <ret> <name>(<params>);`: a function imported from a
            // shared library.
            .@"extern" => {
                _ = try p.advance();
                return p.parseExternImportDecl(m);
            },
            else => {},
        }
    }
    // `class`/`union` are type starts but introduce a definition, not a
    // function; leave them to the statement parser.
    const is_class = t.kind == .keyword and
        (t.kind.keyword == .class or t.kind.keyword == .@"union");
    if (!is_class) {
        if (try p.isTypeStart()) return p.parseTopLevelDecl(m, false);
        if (try p.looksLikeImplicitRetFnDef()) return p.parseImplicitRetFnDef(m, false);
    }
    return p.parseStmtInner();
}

/// Whether the upcoming tokens are a function definition whose return type is
/// omitted (HolyC defaults it to I64), i.e. `Name ( params ) {`. It scans to
/// the `(`'s matching `)` and checks for a `{`, so it never mistakes a
/// paren-less call statement (`Name();`) for a definition.
fn looksLikeImplicitRetFnDef(p: *Parser) Error!bool {
    const t0 = try p.peekN(0);
    if (t0.kind != .ident) return false;
    const t1 = try p.peekN(1);
    if (t1.kind != .l_paren) return false;
    var paren_depth: i64 = 0;
    var i: usize = 1;
    while (i < max_decl_lookahead) : (i += 1) {
        const t = try p.peekN(i);
        switch (t.kind) {
            .l_paren => paren_depth += 1,
            .r_paren => {
                paren_depth -= 1;
                if (paren_depth == 0) {
                    const nt = try p.peekN(i + 1);
                    return nt.kind == .l_brace;
                }
            },
            .eof => return false,
            else => {},
        }
    }
    return false;
}

/// Whether the current token begins an untyped parameter (HolyC default-type
/// rule): a bare identifier that is not a known type, immediately followed by
/// `,`, `)`, or `=`.
fn looksLikeImplicitParam(p: *Parser) Error!bool {
    const cur = try p.peekN(0);
    if (cur.kind != .ident or p.kindIsTypeStart(cur)) return false;
    const nxt = try p.peekN(1);
    return switch (nxt.kind) {
        .comma, .r_paren, .eq => true,
        else => false,
    };
}

/// Parses a function definition whose return type was omitted, defaulting it
/// to I64 (HolyC's default-type rule). The current token is the name.
fn parseImplicitRetFnDef(p: *Parser, m: Mark, is_public: bool) Error!*ast.Stmt {
    const name = try p.expectIdent();
    const params = try p.parseParams();
    const body = try p.parseBlock();
    const f = try p.arena.create(ast.FuncDef);
    f.* = .{
        .ret = .{ .prim = .I64 },
        .name = name,
        .params = params.params,
        .varargs = params.varargs,
        .body = body,
        .is_public = is_public,
    };
    return p.newStmt(.{ .func_def = f }, m);
}

// ---- type detection ----

fn kindIsTypeStart(p: *Parser, t: Token) bool {
    switch (t.kind) {
        .keyword => |kw| return kw.isType() or kw == .class or kw == .@"union",
        .ident => |s| return p.known.contains(s),
        else => return false,
    }
}

fn isTypeStart(p: *Parser) Error!bool {
    const t = try p.peek();
    return p.kindIsTypeStart(t);
}

// ---- types ----

fn parseBaseType(p: *Parser) Error!ast.Type {
    try p.enterRecursion();
    defer p.depth -= 1;

    const t0 = try p.peek();
    if (t0.kind == .keyword and (t0.kind.keyword == .class or t0.kind.keyword == .@"union")) {
        const t1 = try p.peekN(1);
        if (t1.kind == .l_brace) return p.parseAnonAggregate();
    }
    const t = try p.advance();
    switch (t.kind) {
        .keyword => |kw| {
            if (ast.Type.Prim.fromString(kw.spelling())) |prim| return .{ .prim = prim };
            return p.failAt(t.span, "`{s}` is not a type", .{kw.spelling()});
        },
        .ident => |s| return .{ .named = s },
        else => return p.failAt(t.span, "expected a type, found {s}", .{Token.Kind.describe(t.tag())}),
    }
}

/// A parsed declarator: the declared name and its fully built type.
const Declared = struct {
    name: []const u8,
    ty: ast.Type,
};

/// Parses `*`… name `[dim]`…, returning the declared name and its fully built
/// type. A `(` after the stars introduces a function-pointer declarator.
fn parseDeclarator(p: *Parser, base: ast.Type) Error!Declared {
    var ty = base;
    while (try p.eat(.star)) {
        const inner = try p.allocType(ty);
        ty = .{ .ptr = inner };
    }
    if (try p.at(.l_paren)) return p.parseFuncPtrDeclarator(ty);
    const name = try p.expectIdent();
    ty = try p.parseArraySuffix(ty);
    return .{ .name = name, .ty = ty };
}

fn parseFuncPtrDeclarator(p: *Parser, ret: ast.Type) Error!Declared {
    _ = try p.expect(.l_paren, "`(`");
    _ = try p.expect(.star, "`*` in a function-pointer declarator");
    const name = try p.expectIdent();
    var dims: std.ArrayList(?*ast.Expr) = .empty;
    while (try p.eat(.l_bracket)) {
        var dim: ?*ast.Expr = null;
        if (!(try p.at(.r_bracket))) dim = try p.parseExpr();
        _ = try p.expect(.r_bracket, "`]`");
        try dims.append(p.arena, dim);
    }
    _ = try p.expect(.r_paren, "`)`");
    const params = try p.parseParamTypes();
    var ty: ast.Type = .{ .func_ptr = .{ .ret = try p.allocType(ret), .params = params } };
    var i = dims.items.len;
    while (i > 0) {
        i -= 1;
        const elem = try p.allocType(ty);
        ty = .{ .array = .{ .elem = elem, .size = dims.items[i] } };
    }
    return .{ .name = name, .ty = ty };
}

fn parseParamTypes(p: *Parser) Error![]const ast.Type {
    _ = try p.expect(.l_paren, "`(`");
    var params: std.ArrayList(ast.Type) = .empty;
    if (!(try p.at(.r_paren))) {
        while (true) {
            var ty = try p.parseBaseType();
            while (try p.eat(.star)) {
                const inner = try p.allocType(ty);
                ty = .{ .ptr = inner };
            }
            if (try p.at(.ident)) {
                _ = try p.advance(); // optional parameter name, ignored
            }
            try params.append(p.arena, ty);
            if (!(try p.eat(.comma))) break;
        }
    }
    _ = try p.expect(.r_paren, "`)`");
    return params.toOwnedSlice(p.arena);
}

fn parseArraySuffix(p: *Parser, ty: ast.Type) Error!ast.Type {
    var dims: std.ArrayList(?*ast.Expr) = .empty;
    while (try p.eat(.l_bracket)) {
        var dim: ?*ast.Expr = null;
        if (!(try p.at(.r_bracket))) dim = try p.parseExpr();
        _ = try p.expect(.r_bracket, "`]`");
        try dims.append(p.arena, dim);
    }
    var out = ty;
    var i = dims.items.len;
    while (i > 0) {
        i -= 1;
        const elem = try p.allocType(out);
        out = .{ .array = .{ .elem = elem, .size = dims.items[i] } };
    }
    return out;
}

// ---- statements ----

fn parseStmt(p: *Parser) Error!*ast.Stmt {
    try p.enterRecursion();
    defer p.depth -= 1;
    return p.parseStmtInner();
}

fn parseStmtInner(p: *Parser) Error!*ast.Stmt {
    const m = try p.mark();
    const t = try p.peek();

    // Label: `name:`, but not `name::` (a scope operator).
    if (t.kind == .ident) {
        const t1 = try p.peekN(1);
        if (t1.kind == .colon) {
            const name = try p.expectIdent();
            _ = try p.advance(); // ':'
            return p.newStmt(.{ .label = name }, m);
        }
    }

    switch (t.kind) {
        .semicolon => {
            _ = try p.advance();
            return p.newStmt(.empty, m);
        },
        .l_brace => {
            const stmts = try p.parseBlock();
            return p.newStmt(.{ .block = stmts }, m);
        },
        .hash => return p.failAt(t.span, "preprocessor directives are not yet supported", .{}),
        .keyword => |kw| switch (kw) {
            .@"if" => return p.parseIf(m),
            .@"while" => return p.parseWhile(m),
            .do => return p.parseDoWhile(m),
            .@"for" => return p.parseFor(m),
            .@"switch" => return p.parseSwitch(m, false),
            .sub_switch => return p.parseSwitch(m, true),
            .case => return p.parseCase(m),
            .default => {
                _ = try p.advance();
                _ = try p.expect(.colon, "`:`");
                return p.newStmt(.default, m);
            },
            .start => {
                _ = try p.advance();
                _ = try p.expect(.colon, "`:`");
                return p.newStmt(.switch_start, m);
            },
            .end => {
                _ = try p.advance();
                _ = try p.expect(.colon, "`:`");
                return p.newStmt(.switch_end, m);
            },
            .@"break" => {
                _ = try p.advance();
                _ = try p.expect(.semicolon, "`;`");
                return p.newStmt(.break_stmt, m);
            },
            .@"return" => return p.parseReturn(m),
            .goto => {
                _ = try p.advance();
                const name = try p.expectIdent();
                _ = try p.expect(.semicolon, "`;`");
                return p.newStmt(.{ .goto_stmt = name }, m);
            },
            .lock => {
                _ = try p.advance();
                const body = try p.parseBlock();
                return p.newStmt(.{ .lock = body }, m);
            },
            .no_warn => return p.parseNoWarn(m),
            .@"asm" => return p.parseAsm(m),
            .@"try" => {
                _ = try p.advance();
                const body = try p.parseBlock();
                if (!(try p.eatKw(.@"catch"))) {
                    return p.failAt(p.curSpan(), "expected `catch`", .{});
                }
                const handler = try p.parseBlock();
                return p.newStmt(.{ .try_stmt = .{ .body = body, .handler = handler } }, m);
            },
            .throw => {
                _ = try p.advance();
                var value: ?*ast.Expr = null;
                if (!(try p.at(.semicolon))) value = try p.parseExpr();
                _ = try p.expect(.semicolon, "`;`");
                return p.newStmt(.{ .throw = value }, m);
            },
            // `class Name { … }` is a definition; `class { … } v;` is a
            // declaration.
            .class, .@"union" => {
                const t1 = try p.peekN(1);
                if (t1.kind == .l_brace) return p.parseLocalDecl(m);
                return p.parseClass(m, false);
            },
            .public => return p.failAt(t.span, "`public` is only allowed at the top level", .{}),
            else => {
                if (kw.isType()) return p.parseLocalDecl(m);
                return p.parseExprStmt(m);
            },
        },
        else => {
            if (try p.isTypeStart()) return p.parseLocalDecl(m);
            return p.parseExprStmt(m);
        },
    }
}

fn parseExprStmt(p: *Parser, m: Mark) Error!*ast.Stmt {
    const e = try p.parseExpr();
    _ = try p.expect(.semicolon, "`;`");
    return p.newStmt(.{ .expr = e }, m);
}

fn parseBlock(p: *Parser) Error![]const *ast.Stmt {
    _ = try p.expect(.l_brace, "`{`");
    var stmts: std.ArrayList(*ast.Stmt) = .empty;
    while (true) {
        const t = try p.peek();
        if (t.kind == .r_brace) break;
        if (t.kind == .eof) {
            return p.failAt(t.span, "unexpected end of input, expected `}}`", .{});
        }
        const s = try p.parseStmt();
        try stmts.append(p.arena, s);
        try p.drainQueuedInto(&stmts);
    }
    _ = try p.expect(.r_brace, "`}`");
    return stmts.toOwnedSlice(p.arena);
}

/// Parses `no_warn a, b, ...;`, a directive naming locals whose
/// unused-variable warning should be suppressed.
fn parseNoWarn(p: *Parser, m: Mark) Error!*ast.Stmt {
    _ = try p.advance(); // no_warn
    var names: std.ArrayList([]const u8) = .empty;
    while (true) {
        const name = try p.expectIdent();
        try names.append(p.arena, name);
        if (!(try p.eat(.comma))) break;
    }
    _ = try p.expect(.semicolon, "`;`");
    return p.newStmt(.{ .no_warn = try names.toOwnedSlice(p.arena) }, m);
}

// ---- inline assembly ----

/// Parses an `asm [arch] { … }` block. A bare `asm` defaults to amd64; an
/// optional `amd64`/`arm64` qualifier before the `{` states the architecture.
/// The body is a sequence of `MNEMONIC op, op` instructions and `LABEL::`
/// label declarations. Instructions are newline-terminated (operands run to
/// end of line; a comma continues across lines); a `;` may also terminate one.
fn parseAsm(p: *Parser, m: Mark) Error!*ast.Stmt {
    const asm_tok = try p.advance(); // asm
    var arch: []const u8 = "amd64";
    var arch_span = asm_tok.span;
    const t = try p.peek();
    if (t.kind == .ident) {
        arch = t.kind.ident;
        arch_span = t.span;
        _ = try p.advance(); // arch qualifier
    }
    _ = try p.expect(.l_brace, "`{`");
    var insts: std.ArrayList(ast.AsmInst) = .empty;
    while (true) {
        if (try p.eat(.r_brace)) break;
        if (try p.at(.eof)) {
            return p.failAt(p.curSpan(), "unterminated asm block (missing `}}`)", .{});
        }
        try insts.append(p.arena, try p.parseAsmInst(arch));
    }
    const a = try p.arena.create(ast.AsmStmt);
    a.* = .{ .arch = arch, .arch_span = arch_span, .insts = try insts.toOwnedSlice(p.arena) };
    return p.newStmt(.{ .asm_stmt = a }, m);
}

/// Parses one item: a `LABEL::`/`LABEL:` declaration or an instruction
/// `MNEMONIC op, op`. arch selects the register-name set used to classify
/// operands.
fn parseAsmInst(p: *Parser, arch: []const u8) Error!ast.AsmInst {
    const m = try p.mark();
    const head_tok = try p.peek();
    const line = head_tok.span.pos.line;
    var ident = try p.expectIdent();

    // LABEL:: or LABEL: — a label declaration (no mnemonic, no operands).
    const c1 = try p.peek();
    if (c1.kind == .colon) {
        _ = try p.advance(); // first ':'
        const c2 = try p.peek();
        if (c2.kind == .colon) {
            _ = try p.advance(); // second ':' of `::`
        }
        return .{ .label = ident, .span = p.finish(m) };
    }

    // A dotted mnemonic suffix (AArch64 `b.eq`, `b.lt`, …): the lexer splits
    // it into `b` `.` `eq`, so rejoin it into one mnemonic.
    if (c1.kind == .dot) {
        _ = try p.advance(); // '.'
        const suffix = try p.expectIdent();
        ident = try std.fmt.allocPrint(p.arena, "{s}.{s}", .{ ident, suffix });
    }

    // Instruction operands run to end of line; commas continue the list
    // across lines.
    var operands: std.ArrayList(ast.AsmOperand) = .empty;
    if (try p.atAsmOperand(line)) {
        try operands.append(p.arena, try p.parseAsmOperand(arch));
        while (try p.eat(.comma)) {
            try operands.append(p.arena, try p.parseAsmOperand(arch));
        }
    }
    _ = try p.eat(.semicolon); // optional terminator
    return .{
        .mnemonic = ident,
        .operands = try operands.toOwnedSlice(p.arena),
        .span = p.finish(m),
    };
}

/// Whether the next token begins an operand on the mnemonic's line. A token on
/// a later line (or `;`/`}`/EOF) ends the instruction.
fn atAsmOperand(p: *Parser, line: u32) Error!bool {
    const t = try p.peek();
    if (t.span.pos.line != line) return false;
    return switch (t.kind) {
        .semicolon, .r_brace, .eof => false,
        else => true,
    };
}

/// Parses one asm operand: an immediate, a register, a `&name` symbol
/// reference, a bare-name HolyC variable, or a memory operand (optionally
/// type-prefixed as in `U64 disp[base]`).
fn parseAsmOperand(p: *Parser, arch: []const u8) Error!ast.AsmOperand {
    const m = try p.mark();
    const t = try p.peek();
    switch (t.kind) {
        .int => |v| {
            _ = try p.advance();
            return .{ .kind = .{ .imm = v }, .span = p.finish(m) };
        },
        .char => |v| {
            _ = try p.advance();
            return .{ .kind = .{ .imm = v }, .span = p.finish(m) };
        },
        .minus => {
            _ = try p.advance(); // '-'
            const it = try p.expect(.int, "an integer");
            return .{ .kind = .{ .imm = -it.kind.int }, .span = p.finish(m) };
        },
        .amp => {
            _ = try p.advance(); // '&'
            const nt = try p.expect(.ident, "a name after `&`");
            return .{ .kind = .{ .sym = nt.kind.ident }, .span = p.finish(m) };
        },
        .l_bracket => return p.parseAsmMem(arch, "", m),
        .keyword => |kw| {
            // A width type introduces a typed memory operand: `U64 disp[base]`.
            if (kw.isType()) {
                _ = try p.advance(); // type
                return p.parseAsmMem(arch, kw.spelling(), m);
            }
            return p.failAt(t.span, "unexpected keyword {s} in asm operand", .{kw.spelling()});
        },
        .ident => |name| {
            _ = try p.advance();
            if (ast.isAsmRegister(arch, name)) {
                return .{ .kind = .{ .reg = name }, .span = p.finish(m) };
            }
            return .{ .kind = .{ .variable = name }, .span = p.finish(m) };
        },
        else => return p.failAt(
            t.span,
            "expected an asm operand (register, immediate, &symbol, variable, or memory), found {s}",
            .{Token.Kind.describe(t.tag())},
        ),
    }
}

/// Parses a memory operand `[base + index*scale ± disp]`, with the type prefix
/// (if any) already consumed into ty and an optional displacement before the
/// `[` (TempleOS `U64 SF_ARG1[RBP]`). m marks the operand start.
fn parseAsmMem(p: *Parser, arch: []const u8, ty: []const u8, m: Mark) Error!ast.AsmOperand {
    const mem = try p.arena.create(ast.AsmMem);
    mem.* = .{ .ty = ty };

    // Optional leading displacement before '[': a number or a symbolic
    // constant.
    const t = try p.peek();
    switch (t.kind) {
        .int => |v| {
            _ = try p.advance();
            mem.disp = v;
        },
        .minus => {
            _ = try p.advance();
            const it = try p.expect(.int, "an integer displacement");
            mem.disp = -it.kind.int;
        },
        .ident => |name| {
            // A symbolic displacement (e.g. SF_ARG1), only when it precedes
            // the '['.
            if (!ast.isAsmRegister(arch, name)) {
                const t1 = try p.peekN(1);
                if (t1.kind == .l_bracket) {
                    _ = try p.advance();
                    mem.disp_sym = name;
                }
            }
        },
        else => {},
    }

    _ = try p.expect(.l_bracket, "`[`");
    // Optional base register.
    const bt = try p.peek();
    if (bt.kind == .ident and ast.isAsmRegister(arch, bt.kind.ident)) {
        _ = try p.advance();
        mem.base = bt.kind.ident;
    }
    // + index*scale and/or ± disp.
    while (true) {
        if (try p.eat(.plus)) {
            const nt = try p.peek();
            if (nt.kind == .ident and ast.isAsmRegister(arch, nt.kind.ident)) {
                _ = try p.advance();
                if (try p.eat(.star)) {
                    const st = try p.expect(.int, "an index scale");
                    mem.index = nt.kind.ident;
                    mem.scale = st.kind.int;
                } else if (mem.base.len == 0) {
                    mem.base = nt.kind.ident;
                } else {
                    mem.index = nt.kind.ident;
                    mem.scale = 1;
                }
            } else if (nt.kind == .int) {
                _ = try p.advance();
                mem.disp += nt.kind.int;
            } else {
                return p.failAt(nt.span, "expected a register or displacement after `+` in a memory operand", .{});
            }
            continue;
        }
        if (try p.eat(.minus)) {
            const it = try p.expect(.int, "an integer displacement");
            mem.disp -= it.kind.int;
            continue;
        }
        break;
    }
    _ = try p.expect(.r_bracket, "`]`");
    return .{ .kind = .{ .mem = mem }, .span = p.finish(m) };
}

// ---- control flow ----

fn parseIf(p: *Parser, m: Mark) Error!*ast.Stmt {
    _ = try p.advance(); // if
    _ = try p.expect(.l_paren, "`(`");
    const cond = try p.parseExpr();
    _ = try p.expect(.r_paren, "`)`");
    const then = try p.parseStmt();
    var els: ?*ast.Stmt = null;
    if (try p.eatKw(.@"else")) els = try p.parseStmt();
    return p.newStmt(.{ .if_stmt = .{ .cond = cond, .then = then, .els = els } }, m);
}

fn parseWhile(p: *Parser, m: Mark) Error!*ast.Stmt {
    _ = try p.advance(); // while
    _ = try p.expect(.l_paren, "`(`");
    const cond = try p.parseExpr();
    _ = try p.expect(.r_paren, "`)`");
    const body = try p.parseStmt();
    return p.newStmt(.{ .while_stmt = .{ .cond = cond, .body = body } }, m);
}

fn parseDoWhile(p: *Parser, m: Mark) Error!*ast.Stmt {
    _ = try p.advance(); // do
    const body = try p.parseStmt();
    if (!(try p.eatKw(.@"while"))) {
        return p.failAt(p.curSpan(), "expected `while`", .{});
    }
    _ = try p.expect(.l_paren, "`(`");
    const cond = try p.parseExpr();
    _ = try p.expect(.r_paren, "`)`");
    _ = try p.expect(.semicolon, "`;`");
    return p.newStmt(.{ .do_while = .{ .body = body, .cond = cond } }, m);
}

fn parseFor(p: *Parser, m: Mark) Error!*ast.Stmt {
    _ = try p.advance(); // for
    _ = try p.expect(.l_paren, "`(`");

    var for_init: ?*ast.Stmt = null;
    if (!(try p.eat(.semicolon))) {
        const im = try p.mark();
        if (try p.isTypeStart()) {
            const base = try p.parseBaseType();
            const dm = try p.mark();
            const d = try p.parseDeclarator(base);
            const decls = try p.parseDeclList(base, d.name, d.ty, dm, false, .{});
            for_init = try p.newStmt(.{ .var_decl = decls }, im);
        } else {
            const e = try p.parseExpr();
            for_init = try p.newStmt(.{ .expr = e }, im);
        }
        _ = try p.expect(.semicolon, "`;`");
    }

    var cond: ?*ast.Expr = null;
    if (!(try p.at(.semicolon))) cond = try p.parseExpr();
    _ = try p.expect(.semicolon, "`;`");

    var step: ?*ast.Expr = null;
    if (!(try p.at(.r_paren))) step = try p.parseExpr();
    _ = try p.expect(.r_paren, "`)`");

    const body = try p.parseStmt();
    return p.newStmt(.{ .for_stmt = .{ .init = for_init, .cond = cond, .step = step, .body = body } }, m);
}

fn parseSwitch(p: *Parser, m: Mark, sub: bool) Error!*ast.Stmt {
    _ = try p.advance(); // switch / sub_switch
    // HolyC `switch [expr]` is the no-bounds-check form; `switch (expr)` is
    // checked. `sub_switch` accepts the same two delimiters.
    const no_bounds = try p.eat(.l_bracket);
    if (!no_bounds) _ = try p.expect(.l_paren, "`(`");
    const cond = try p.parseExpr();
    if (no_bounds) {
        _ = try p.expect(.r_bracket, "`]`");
    } else {
        _ = try p.expect(.r_paren, "`)`");
    }
    const body = try p.parseStmt();
    return p.newStmt(.{ .switch_stmt = .{
        .cond = cond,
        .body = body,
        .no_bounds = no_bounds,
        .sub = sub,
    } }, m);
}

fn parseCase(p: *Parser, m: Mark) Error!*ast.Stmt {
    _ = try p.advance(); // case
    var lo: ?*ast.Expr = null;
    var hi: ?*ast.Expr = null;
    if (!(try p.at(.colon))) {
        lo = try p.parseAssign();
        // HolyC range label: `case lo ... hi:`.
        if (try p.eat(.dot_dot_dot)) hi = try p.parseAssign();
    }
    _ = try p.expect(.colon, "`:`");
    return p.newStmt(.{ .case = .{ .lo = lo, .hi = hi } }, m);
}

fn parseReturn(p: *Parser, m: Mark) Error!*ast.Stmt {
    _ = try p.advance(); // return
    var val: ?*ast.Expr = null;
    if (!(try p.at(.semicolon))) val = try p.parseAssign();
    _ = try p.expect(.semicolon, "`;`");
    return p.newStmt(.{ .return_stmt = val }, m);
}

// ---- declarations ----

/// Parses a declaration introduced by a leading `public`, already consumed.
/// The declaration may be a class/union, a typed function or variable, or an
/// implicit-return function definition.
fn parsePublicDecl(p: *Parser, m: Mark) Error!*ast.Stmt {
    const t = try p.peek();
    if (t.kind == .keyword and (t.kind.keyword == .class or t.kind.keyword == .@"union")) {
        const t1 = try p.peekN(1);
        if (t1.kind == .l_brace) return p.parseTopLevelDecl(m, true);
        return p.parseClass(m, true);
    }
    if (try p.isTypeStart()) return p.parseTopLevelDecl(m, true);
    if (try p.looksLikeImplicitRetFnDef()) return p.parseImplicitRetFnDef(m, true);
    return p.failAt(p.curSpan(), "expected a declaration after `public`", .{});
}

/// The type and declarator shared by every declaration: the base type, the
/// declared name and its built type, a mark at the start of the declarator,
/// and any `reg`/`noreg` storage class that preceded the name.
const DeclHead = struct {
    base: ast.Type,
    name: []const u8,
    ty: ast.Type,
    mark: Mark,
    storage: StorageSpec,
};

/// Parses `<LABEL> <return-type> <name>(<params>);` introduced by a leading
/// `_extern` (or `_import`), already consumed. The asm label plus declarator
/// give the function a typed HolyC name bound to an asm-defined label of a
/// different spelling; the declaration has no body.
fn parseAsmExternDecl(p: *Parser, m: Mark) Error!*ast.Stmt {
    const label = try p.expectIdent();
    const h = try p.parseDeclHead();
    if (!(try p.at(.l_paren))) {
        return p.failAt(p.curSpan(), "an _extern declaration must declare a function", .{});
    }
    const params = try p.parseParams();
    _ = try p.expect(.semicolon, "`;` (an _extern declaration has no body)");
    const f = try p.arena.create(ast.FuncDef);
    f.* = .{
        .ret = h.ty,
        .name = h.name,
        .params = params.params,
        .varargs = params.varargs,
        .body = null,
        .is_public = true,
        .asm_label = label,
    };
    return p.newStmt(.{ .func_def = f }, m);
}

/// Parses `extern <ret> <name>(<params>);`, a function imported from a shared
/// library (bound at load time). It has no body.
fn parseExternImportDecl(p: *Parser, m: Mark) Error!*ast.Stmt {
    const h = try p.parseDeclHead();
    if (!(try p.at(.l_paren))) {
        return p.failAt(p.curSpan(), "an `extern` import must declare a function", .{});
    }
    const params = try p.parseParams();
    _ = try p.expect(.semicolon, "`;` (an `extern` import has no body)");
    const f = try p.arena.create(ast.FuncDef);
    f.* = .{
        .ret = h.ty,
        .name = h.name,
        .params = params.params,
        .varargs = params.varargs,
        .body = null,
        .is_public = true,
        .import = true,
    };
    return p.newStmt(.{ .func_def = f }, m);
}

/// A parsed `reg [REG]` / `noreg` storage class preceding a declarator's name.
const StorageSpec = struct {
    mode: ast.RegMode = .none,
    /// Pinned register for `reg <REG> name`, "" otherwise.
    name: []const u8 = "",
};

fn parseDeclHead(p: *Parser) Error!DeclHead {
    const base = try p.parseBaseType();
    const storage = try p.parseStorageSpec();
    const dm = try p.mark();
    const d = try p.parseDeclarator(base);
    return .{ .base = base, .name = d.name, .ty = d.ty, .mark = dm, .storage = storage };
}

/// Parses an optional `reg [REG]` or `noreg` storage class that, in HolyC,
/// sits between a declaration's type and the variable name (`I64 reg R15 i,
/// noreg j;`). The register name (if any) is the physical register the
/// variable is pinned to; it is distinguished from the variable name by being
/// followed by another identifier or a `*` (a lone identifier after `reg` is
/// the variable itself).
fn parseStorageSpec(p: *Parser) Error!StorageSpec {
    if (try p.eatKw(.reg)) {
        var name: []const u8 = "";
        if (try p.atRegName()) {
            const t = try p.advance();
            name = t.kind.ident;
        }
        return .{ .mode = .reg, .name = name };
    }
    if (try p.eatKw(.noreg)) {
        return .{ .mode = .noreg };
    }
    return .{};
}

/// Whether the cursor sits on the physical-register name of a `reg <REG> name`
/// storage class: an identifier followed by another identifier or a pointer
/// `*` (so the declarator continues after it).
fn atRegName(p: *Parser) Error!bool {
    const t = try p.peek();
    if (t.kind != .ident) return false;
    const t1 = try p.peekN(1);
    return t1.kind == .ident or t1.kind == .star;
}

/// Parses a top-level declaration: a function definition or prototype when a
/// `(` follows the declarator, otherwise a variable declaration.
fn parseTopLevelDecl(p: *Parser, m: Mark, is_public: bool) Error!*ast.Stmt {
    const h = try p.parseDeclHead();
    if (try p.at(.l_paren)) {
        const params = try p.parseParams();
        var body: ?[]const *ast.Stmt = null; // null => prototype
        if (try p.at(.l_brace)) {
            body = try p.parseBlock();
        } else {
            _ = try p.expect(.semicolon, "`;` or a function body");
        }
        const f = try p.arena.create(ast.FuncDef);
        f.* = .{
            .ret = h.ty,
            .name = h.name,
            .params = params.params,
            .varargs = params.varargs,
            .body = body,
            .is_public = is_public,
        };
        return p.newStmt(.{ .func_def = f }, m);
    }
    return p.parseDeclStmt(m, h, is_public);
}

/// Parses a variable declaration inside a block. Unlike a top-level
/// declaration it may not introduce a function: a `(` after the declarator is
/// rejected, since functions may only be defined at the top level.
fn parseLocalDecl(p: *Parser, m: Mark) Error!*ast.Stmt {
    const h = try p.parseDeclHead();
    if (try p.at(.l_paren)) {
        return p.failAt(p.curSpan(), "functions may only be defined at the top level", .{});
    }
    return p.parseDeclStmt(m, h, false);
}

fn parseDeclStmt(p: *Parser, m: Mark, h: DeclHead, is_public: bool) Error!*ast.Stmt {
    const decls = try p.parseDeclList(h.base, h.name, h.ty, h.mark, is_public, h.storage);
    _ = try p.expect(.semicolon, "`;`");
    return p.newStmt(.{ .var_decl = decls }, m);
}

fn parseDeclList(
    p: *Parser,
    base: ast.Type,
    first_name: []const u8,
    first_ty: ast.Type,
    first_mark: Mark,
    is_public: bool,
    first_storage: StorageSpec,
) Error![]const ast.Declarator {
    var decls: std.ArrayList(ast.Declarator) = .empty;
    try decls.append(p.arena, try p.finishDeclarator(first_name, first_ty, first_mark, is_public, first_storage));
    while (try p.eat(.comma)) {
        const storage = try p.parseStorageSpec();
        const dm = try p.mark();
        const d = try p.parseDeclarator(base);
        try decls.append(p.arena, try p.finishDeclarator(d.name, d.ty, dm, is_public, storage));
    }
    return decls.toOwnedSlice(p.arena);
}

fn finishDeclarator(
    p: *Parser,
    name: []const u8,
    ty: ast.Type,
    m: Mark,
    is_public: bool,
    storage: StorageSpec,
) Error!ast.Declarator {
    var d_init: ?*ast.Expr = null;
    if (try p.eat(.eq)) d_init = try p.parseInitializer();
    return .{
        .name = name,
        .ty = ty,
        .init = d_init,
        .span = p.finish(m),
        .is_public = is_public,
        .reg_mode = storage.mode,
        .reg_name = storage.name,
    };
}

fn parseInitializer(p: *Parser) Error!*ast.Expr {
    if (try p.at(.l_brace)) return p.parseInitList();
    return p.parseAssign();
}

fn parseInitList(p: *Parser) Error!*ast.Expr {
    const m = try p.mark();
    _ = try p.expect(.l_brace, "`{`");
    if (try p.at(.dot)) return p.parseDesignatedInit(m);
    var items: std.ArrayList(*ast.Expr) = .empty;
    while (true) {
        if (try p.at(.r_brace)) break;
        try items.append(p.arena, try p.parseInitializer());
        if (!(try p.eat(.comma))) break;
    }
    _ = try p.expect(.r_brace, "`}`");
    return p.newExpr(.{ .init_list = try items.toOwnedSlice(p.arena) }, m);
}

fn parseDesignatedInit(p: *Parser, m: Mark) Error!*ast.Expr {
    var items: std.ArrayList(ast.Expr.FieldInit) = .empty;
    while (true) {
        if (try p.at(.r_brace)) break;
        _ = try p.expect(.dot, "`.`");
        const name = try p.expectIdent();
        _ = try p.expect(.eq, "`=`");
        const val = try p.parseInitializer();
        try items.append(p.arena, .{ .name = name, .value = val });
        if (!(try p.eat(.comma))) break;
    }
    _ = try p.expect(.r_brace, "`}`");
    return p.newExpr(.{ .designated_init = try items.toOwnedSlice(p.arena) }, m);
}

const Params = struct {
    params: []const ast.Param,
    varargs: bool,
};

fn parseParams(p: *Parser) Error!Params {
    _ = try p.expect(.l_paren, "`(`");
    var params: std.ArrayList(ast.Param) = .empty;
    var varargs = false;
    if (!(try p.at(.r_paren))) {
        while (true) {
            if (try p.eat(.dot_dot_dot)) {
                varargs = true;
                break;
            }
            const pm = try p.mark();
            // HolyC default-type rule: an untyped parameter (a bare name
            // followed by `,`, `)`, or `=`) has type I64. Only an identifier
            // that is not a known type takes this path, so `F(KnownType)`
            // still means an unnamed parameter of that type.
            var ty: ast.Type = undefined;
            var name: []const u8 = "";
            if (try p.looksLikeImplicitParam()) {
                name = try p.expectIdent();
                ty = .{ .prim = .I64 };
            } else {
                ty = try p.parseBaseType();
                while (try p.eat(.star)) {
                    const inner = try p.allocType(ty);
                    ty = .{ .ptr = inner };
                }
                if (try p.at(.l_paren)) {
                    const d = try p.parseFuncPtrDeclarator(ty);
                    name = d.name;
                    ty = d.ty;
                } else {
                    if (try p.at(.ident)) name = try p.expectIdent();
                    ty = try p.parseArraySuffix(ty);
                }
            }
            var def: ?*ast.Expr = null;
            if (try p.eat(.eq)) def = try p.parseAssign();
            try params.append(p.arena, .{
                .ty = ty,
                .name = name,
                .default_value = def,
                .span = p.finish(pm),
            });
            if (!(try p.eat(.comma))) break;
        }
    }
    _ = try p.expect(.r_paren, "`)`");
    return .{ .params = try params.toOwnedSlice(p.arena), .varargs = varargs };
}

/// Parses an anonymous `class { … }` / `union { … }` written as a type (e.g.
/// `class { I64 x; } a, b;`). It synthesizes a uniquely-named ClassDef, hoists
/// it to the top level, and returns a named type referring to it, so the
/// anonymous type behaves like an ordinary named aggregate wherever a type may
/// appear.
fn parseAnonAggregate(p: *Parser) Error!ast.Type {
    const m = try p.mark();
    const kw_tok = try p.advance(); // class | union
    const is_union = kw_tok.kind.keyword == .@"union";
    const fields = try p.parseClassFields();
    const name = try std.fmt.allocPrint(p.arena, "$anon{d}", .{p.anon_count});
    p.anon_count += 1;
    try p.known.put(p.arena, name, {});
    const def = try p.arena.create(ast.ClassDef);
    def.* = .{ .is_union = is_union, .name = name, .fields = fields, .is_public = true };
    try p.hoisted.append(p.arena, try p.newStmt(.{ .class_def = def }, m));
    return .{ .named = name };
}

fn parseClass(p: *Parser, m: Mark, is_public: bool) Error!*ast.Stmt {
    const kw_tok = try p.advance(); // class | union
    const is_union = kw_tok.kind.keyword == .@"union";
    const name = try p.expectIdent();
    // Register the name up front so self-referential fields (`Foo *next;`)
    // parse.
    try p.known.put(p.arena, name, {});
    if (try p.at(.semicolon)) { // forward declaration
        _ = try p.advance();
        return p.newStmt(.empty, m);
    }
    var base: []const u8 = "";
    if (try p.eat(.colon)) base = try p.expectIdent();
    const fields = try p.parseClassFields();
    // HolyC inline instance declaration: `class Foo {…} a, b;` declares the
    // type and one or more variables of it. The variables become a VarDecl
    // queued right after this ClassDef.
    var inst_stmt: ?*ast.Stmt = null;
    if (try p.looksLikeInlineInstance()) {
        inst_stmt = try p.parseInlineInstances(name, is_public);
    }
    _ = try p.eat(.semicolon); // optional trailing `;`
    if (inst_stmt) |s| try p.queued.append(p.arena, s);
    const def = try p.arena.create(ast.ClassDef);
    def.* = .{
        .is_union = is_union,
        .name = name,
        .base = base,
        .fields = fields,
        .is_public = is_public,
    };
    return p.newStmt(.{ .class_def = def }, m);
}

/// Whether one or more variable declarators follow a class body
/// (`class Foo {…} a, b;`), distinguishing them from a following statement: it
/// accepts `(*)* Ident` followed by `,`, `;`, `=`, or `[`. So
/// `class P {…} OtherType y;` stays a separate declaration.
fn looksLikeInlineInstance(p: *Parser) Error!bool {
    var i: usize = 0;
    while (true) {
        const t = try p.peekN(i);
        if (t.kind != .star) break;
        i += 1;
    }
    const nm = try p.peekN(i);
    if (nm.kind != .ident) return false;
    const nt = try p.peekN(i + 1);
    return switch (nt.kind) {
        .comma, .semicolon, .eq, .l_bracket => true,
        else => false,
    };
}

/// Parses the variable declarator list of an inline instance declaration into
/// a VarDecl of the just-defined class type. The terminating `;` is consumed
/// by the caller.
fn parseInlineInstances(p: *Parser, class_name: []const u8, is_public: bool) Error!*ast.Stmt {
    const base: ast.Type = .{ .named = class_name };
    const dm = try p.mark();
    const d = try p.parseDeclarator(base);
    const decls = try p.parseDeclList(base, d.name, d.ty, dm, is_public, .{});
    return p.newStmt(.{ .var_decl = decls }, dm);
}

fn parseClassFields(p: *Parser) Error![]const ast.Declarator {
    _ = try p.expect(.l_brace, "`{`");
    var fields: std.ArrayList(ast.Declarator) = .empty;
    while (true) {
        const t = try p.peek();
        if (t.kind == .r_brace) break;
        if (t.kind == .eof) {
            return p.failAt(t.span, "unexpected end of input in class body, expected `}}`", .{});
        }
        // An anonymous embedded union/struct (`union { … };` or
        // `class { … };`) promotes its members into the enclosing class.
        // Lower it to a synthetic named aggregate plus a `$anon`-prefixed
        // field that sema and the layout pass recognise and promote.
        if (t.kind == .keyword and (t.kind.keyword == .@"union" or t.kind.keyword == .class)) {
            const t1 = try p.peekN(1);
            if (t1.kind == .l_brace) {
                const grp_mark = try p.mark();
                const is_u = t.kind.keyword == .@"union";
                _ = try p.advance(); // class | union
                const inner = try p.parseClassFields();
                _ = try p.expect(.semicolon, "`;`");
                const anon = try std.fmt.allocPrint(p.arena, "$anon{d}", .{p.anon_count});
                p.anon_count += 1;
                try p.known.put(p.arena, anon, {});
                const def = try p.arena.create(ast.ClassDef);
                def.* = .{ .is_union = is_u, .name = anon, .fields = inner, .is_public = true };
                try p.queued.append(p.arena, try p.newStmt(.{ .class_def = def }, grp_mark));
                try fields.append(p.arena, .{
                    .name = anon,
                    .ty = .{ .named = anon },
                    .span = p.finish(grp_mark),
                });
                continue;
            }
        }
        const field_base = try p.parseBaseType();
        var dm = try p.mark();
        var d = try p.parseDeclarator(field_base);
        var meta = try p.parseFieldMeta();
        try fields.append(p.arena, .{ .name = d.name, .ty = d.ty, .span = p.finish(dm), .meta = meta });
        while (try p.eat(.comma)) {
            dm = try p.mark();
            d = try p.parseDeclarator(field_base);
            meta = try p.parseFieldMeta();
            try fields.append(p.arena, .{ .name = d.name, .ty = d.ty, .span = p.finish(dm), .meta = meta });
        }
        _ = try p.expect(.semicolon, "`;`");
    }
    _ = try p.expect(.r_brace, "`}`");
    return fields.toOwnedSlice(p.arena);
}

/// Parses HolyC member metadata that may follow a class-field declarator: zero
/// or more `key value` pairs, where key is an identifier (e.g. `format`,
/// `data`) and value is a string or integer literal. Stops at the `,` or `;`
/// that ends the declarator.
fn parseFieldMeta(p: *Parser) Error![]const ast.FieldMeta {
    var meta: std.ArrayList(ast.FieldMeta) = .empty;
    while (try p.at(.ident)) {
        const key = try p.expectIdent();
        const v = try p.peek();
        switch (v.kind) {
            .str => |s| try meta.append(p.arena, .{ .key = key, .value = .{ .str = s } }),
            .int => |n| try meta.append(p.arena, .{ .key = key, .value = .{ .int = n } }),
            else => return p.failAt(v.span, "member metadata `{s}` expects a string or integer value", .{key}),
        }
        _ = try p.advance();
    }
    return meta.toOwnedSlice(p.arena);
}

// ---- expressions ----

fn parseExpr(p: *Parser) Error!*ast.Expr {
    const m = try p.mark();
    const first = try p.parseAssign();
    if (!(try p.at(.comma))) return first;
    var items: std.ArrayList(*ast.Expr) = .empty;
    try items.append(p.arena, first);
    while (try p.eat(.comma)) {
        try items.append(p.arena, try p.parseAssign());
    }
    return p.newExpr(.{ .comma = try items.toOwnedSlice(p.arena) }, m);
}

/// Handles the assignment level (right-associative). HolyC has no conditional
/// (?:) operator; the assignment level sits directly on top of the
/// binary-operator level.
fn parseAssign(p: *Parser) Error!*ast.Expr {
    const m = try p.mark();
    const lhs = try p.parseBinary(0);
    const t = try p.peek();
    if (assignOp(t.kind)) |op| {
        _ = try p.advance();
        const val = try p.parseAssign();
        return p.newExpr(.{ .assign = .{ .op = op, .target = lhs, .value = val } }, m);
    }
    return lhs;
}

/// Climbs precedence: min_bp is the minimum binding power an operator must
/// have to be consumed at this level.
fn parseBinary(p: *Parser, min_bp: u8) Error!*ast.Expr {
    const m = try p.mark();
    var lhs = try p.parseUnary();
    while (true) {
        const t = try p.peek();
        const info = infixOp(t.kind) orelse break;
        if (info.bp < min_bp) break;
        _ = try p.advance();
        // Left-assoc: the right side binds one tighter. Right-assoc (`` ` ``)
        // recurses at the same power so a`b`c parses as a`(b`c).
        const rhs_min = if (isRightAssoc(info.op)) info.bp else info.bp + 1;
        const rhs = try p.parseBinary(rhs_min);

        // HolyC chained range comparisons: `a < b < c` means `a < b && b < c`.
        if (isChainCmp(info.op) and try p.nextIsChainCmp(info.bp)) {
            var chain = try p.bin(info.op, lhs, rhs, m);
            var prev = rhs;
            while (try p.nextIsChainCmp(info.bp)) {
                const t2 = try p.peek();
                const info2 = infixOp(t2.kind).?;
                _ = try p.advance();
                const next = try p.parseBinary(info.bp + 1);
                chain = try p.bin(.log_and, chain, try p.bin(info2.op, prev, next, m), m);
                prev = next;
            }
            lhs = chain;
        } else {
            lhs = try p.bin(info.op, lhs, rhs, m);
        }
    }
    return lhs;
}

fn bin(p: *Parser, op: ast.BinOp, lhs: *ast.Expr, rhs: *ast.Expr, m: Mark) Error!*ast.Expr {
    return p.newExpr(.{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs } }, m);
}

fn nextIsChainCmp(p: *Parser, bp: u8) Error!bool {
    const t = try p.peek();
    const info = infixOp(t.kind) orelse return false;
    return info.bp == bp and isChainCmp(info.op);
}

fn parseUnary(p: *Parser) Error!*ast.Expr {
    try p.enterRecursion();
    defer p.depth -= 1;

    const m = try p.mark();
    const t = try p.peek();
    if (prefixOp(t.kind)) |op| {
        _ = try p.advance();
        const e = try p.parseUnary();
        return p.newExpr(.{ .unary = .{ .op = op, .expr = e } }, m);
    }
    if (try p.atKw(.sizeof)) return p.parseSizeof(m);
    if (try p.atKw(.offset)) return p.parseOffset(m);
    // Cast: `(` Type `)` unary, distinguished from a parenthesised expression
    // by peeking whether a type name follows the `(`.
    if (t.kind == .l_paren) {
        const t1 = try p.peekN(1);
        if (p.kindIsTypeStart(t1)) return p.parseCast(m);
    }
    return p.parsePostfix();
}

fn parseSizeof(p: *Parser, m: Mark) Error!*ast.Expr {
    _ = try p.advance(); // sizeof
    _ = try p.expect(.l_paren, "`(`");
    var kind: ast.Expr.Kind = undefined;
    if (try p.isTypeStart()) {
        var ty = try p.parseBaseType();
        while (try p.eat(.star)) {
            const inner = try p.allocType(ty);
            ty = .{ .ptr = inner };
        }
        kind = .{ .sizeof = .{ .ty = ty, .expr = null } };
    } else {
        const e = try p.parseExpr();
        kind = .{ .sizeof = .{ .ty = null, .expr = e } };
    }
    _ = try p.expect(.r_paren, "`)`");
    return p.newExpr(kind, m);
}

fn parseOffset(p: *Parser, m: Mark) Error!*ast.Expr {
    _ = try p.advance(); // offset
    _ = try p.expect(.l_paren, "`(`");
    const base = try p.parseBaseType();
    const class_name = switch (base) {
        .named => |n| n,
        else => return p.failAt(
            .{ .pos = m.pos, .file = m.file },
            "offset() expects a class member, e.g. offset(Class.field)",
            .{},
        ),
    };
    var path: std.ArrayList([]const u8) = .empty;
    _ = try p.expect(.dot, "`.`");
    try path.append(p.arena, try p.expectIdent());
    while (try p.eat(.dot)) {
        try path.append(p.arena, try p.expectIdent());
    }
    _ = try p.expect(.r_paren, "`)`");
    return p.newExpr(.{ .offset = .{
        .class = class_name,
        .path = try path.toOwnedSlice(p.arena),
    } }, m);
}

fn parseCast(p: *Parser, m: Mark) Error!*ast.Expr {
    _ = try p.expect(.l_paren, "`(`");
    var ty = try p.parseBaseType();
    while (try p.eat(.star)) {
        const inner = try p.allocType(ty);
        ty = .{ .ptr = inner };
    }
    _ = try p.expect(.r_paren, "`)`");
    const e = try p.parseUnary();
    return p.newExpr(.{ .cast = .{ .ty = ty, .expr = e } }, m);
}

fn parsePostfix(p: *Parser) Error!*ast.Expr {
    const m = try p.mark();
    var e = try p.parsePrimary();
    while (true) {
        const t = try p.peek();
        switch (t.kind) {
            .l_paren => {
                _ = try p.advance();
                const args = try p.parseCallArgs();
                _ = try p.expect(.r_paren, "`)`");
                e = try p.newExpr(.{ .call = .{ .callee = e, .args = args } }, m);
            },
            .l_bracket => {
                _ = try p.advance();
                const index = try p.parseExpr();
                _ = try p.expect(.r_bracket, "`]`");
                e = try p.newExpr(.{ .index = .{ .base = e, .index = index } }, m);
            },
            .dot => {
                _ = try p.advance();
                const field = try p.expectIdent();
                e = try p.newExpr(.{ .member = .{ .base = e, .field = field, .arrow = false } }, m);
            },
            .arrow => {
                _ = try p.advance();
                const field = try p.expectIdent();
                e = try p.newExpr(.{ .member = .{ .base = e, .field = field, .arrow = true } }, m);
            },
            .plus_plus => {
                _ = try p.advance();
                e = try p.newExpr(.{ .postfix = .{ .op = .inc, .expr = e } }, m);
            },
            .minus_minus => {
                _ = try p.advance();
                e = try p.newExpr(.{ .postfix = .{ .op = .dec, .expr = e } }, m);
            },
            else => return e,
        }
    }
}

fn parseCallArgs(p: *Parser) Error![]const ?*ast.Expr {
    var args: std.ArrayList(?*ast.Expr) = .empty;
    if (try p.at(.r_paren)) return args.toOwnedSlice(p.arena);
    while (true) {
        // An empty slot (`F(,6)`, `F(a,,c)`, `F(a,)`) is a skipped argument
        // that takes the parameter's default value (HolyC allows defaults in
        // any position). It is recorded as a null entry in the argument list.
        const t = try p.peek();
        if (t.kind == .comma or t.kind == .r_paren) {
            try args.append(p.arena, null);
        } else {
            try args.append(p.arena, try p.parseAssign());
        }
        if (!(try p.eat(.comma))) break;
    }
    return args.toOwnedSlice(p.arena);
}

fn parsePrimary(p: *Parser) Error!*ast.Expr {
    const m = try p.mark();
    const t = try p.advance();
    switch (t.kind) {
        .int => |v| return p.newExpr(.{ .int_lit = v }, m),
        .float => |v| return p.newExpr(.{ .float_lit = v }, m),
        .str => |s| return p.newExpr(.{ .str_lit = s }, m),
        .char => |v| return p.newExpr(.{ .char_lit = v }, m),
        .keyword => |kw| {
            // `lastclass` is a default-argument value standing for the class
            // name of the preceding argument (resolved per call site during
            // lowering).
            if (kw == .lastclass) return p.newExpr(.lastclass, m);
            return p.failAt(t.span, "expected an expression, found keyword `{s}`", .{kw.spelling()});
        },
        .ident => |s| return p.newExpr(.{ .ident = s }, m),
        .l_paren => {
            const inner = try p.parseAssign();
            _ = try p.expect(.r_paren, "`)`");
            return inner;
        },
        else => return p.failAt(t.span, "expected an expression, found {s}", .{Token.Kind.describe(t.tag())}),
    }
}

// ---- operator tables ----

fn assignOp(k: Token.Kind) ?ast.AssignOp {
    return switch (k) {
        .eq => .assign,
        .plus_eq => .add,
        .minus_eq => .sub,
        .star_eq => .mul,
        .slash_eq => .div,
        .percent_eq => .mod,
        .amp_eq => .bit_and,
        .pipe_eq => .bit_or,
        .caret_eq => .bit_xor,
        .shl_eq => .shl,
        .shr_eq => .shr,
        else => null,
    };
}

fn isChainCmp(op: ast.BinOp) bool {
    return op == .lt or op == .gt or op == .le or op == .ge;
}

const InfixInfo = struct {
    op: ast.BinOp,
    bp: u8,
};

/// Maps an infix-operator token to its BinOp and binding power. Higher power
/// binds tighter; left-associative operators recurse at bp+1. This is HolyC's
/// (not C's) precedence table: `` ` ``/`<<`/`>>` are highest, then `* / %`,
/// then the bitwise operators each on their own tier `&` > `^` > `|`, then
/// `+ -`, then the relational and equality comparisons, then `&& ^^ ||`. So
/// `a & b == c` parses as `(a & b) == c` and `a + b << c` as `a + (b << c)`.
fn infixOp(k: Token.Kind) ?InfixInfo {
    return switch (k) {
        .or_or => .{ .op = .log_or, .bp = 1 },
        .caret_caret => .{ .op = .log_xor, .bp = 2 },
        .and_and => .{ .op = .log_and, .bp = 3 },
        .eq_eq => .{ .op = .eq, .bp = 4 },
        .ne => .{ .op = .ne, .bp = 4 },
        .lt => .{ .op = .lt, .bp = 5 },
        .gt => .{ .op = .gt, .bp = 5 },
        .le => .{ .op = .le, .bp = 5 },
        .ge => .{ .op = .ge, .bp = 5 },
        .plus => .{ .op = .add, .bp = 6 },
        .minus => .{ .op = .sub, .bp = 6 },
        .pipe => .{ .op = .bit_or, .bp = 7 },
        .caret => .{ .op = .bit_xor, .bp = 8 },
        .amp => .{ .op = .bit_and, .bp = 9 },
        .star => .{ .op = .mul, .bp = 10 },
        .slash => .{ .op = .div, .bp = 10 },
        .percent => .{ .op = .mod, .bp = 10 },
        .shl => .{ .op = .shl, .bp = 11 },
        .shr => .{ .op = .shr, .bp = 11 },
        .backtick => .{ .op = .pow, .bp = 11 },
        else => null,
    };
}

/// Whether a binary operator associates right-to-left. HolyC's `` ` ``
/// exponentiation chains as base`(exp`exp), matching mathematical convention;
/// every other binary operator here is left-associative.
fn isRightAssoc(op: ast.BinOp) bool {
    return op == .pow;
}

fn prefixOp(k: Token.Kind) ?ast.UnOp {
    return switch (k) {
        .not => .not,
        .tilde => .bit_not,
        .minus => .neg,
        .plus => .pos,
        .star => .deref,
        .amp => .addr_of,
        .plus_plus => .pre_inc,
        .minus_minus => .pre_dec,
        else => null,
    };
}

// ---- tests ----

test {
    _ = @import("parser_test.zig");
}
