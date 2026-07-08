//! Navigation helpers for go-to-definition and find-references.
//!
//! These are pure functions over a parsed program and its source text: the
//! identifier under a cursor, the name-range of a top-level declaration, the
//! bare-identifier uses of a name, and file:// URI construction for the
//! cross-file (workspace) definition index. Like the rest of the server they
//! are name-based and scope-free: a name resolves to the top-level declaration
//! of that name and to every bare-identifier use of it; member accesses
//! (`x.field`) are not uses of a top-level `field`. Only the user's own file
//! (spans with file == 0) is considered; the core and #include'd frames have
//! no position in the buffer.

const std = @import("std");
const hcc = @import("hcc");
const position = @import("position.zig");

pub const Range = struct {
    start: position.Position,
    end: position.Position,
};

/// A top-level declaration's name and the LSP range covering just that name.
pub const Def = struct {
    name: []const u8,
    range: Range,
};

/// Byte offsets [start, end) of a name within the source text.
pub const Offsets = struct { start: usize, end: usize };

/// True for bytes valid in a HolyC identifier (ASCII letters, digits,
/// underscore); matches the lexer's identifier-continuation set.
fn isIdentByte(b: u8) bool {
    return b == '_' or (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9');
}

/// The identifier covering `offset` in `src`, or "" if none. An offset one past
/// the last identifier byte still counts as inside it (where the caret sits
/// right after a name).
pub fn wordAt(src: []const u8, offset_in: usize) []const u8 {
    const offset = @min(offset_in, src.len);
    var start = offset;
    while (start > 0 and isIdentByte(src[start - 1])) start -= 1;
    var end = offset;
    while (end < src.len and isIdentByte(src[end])) end += 1;
    return src[start..end];
}

/// The byte offsets of the first whole-word occurrence of `name` in
/// src[lo..hi], or null when absent.
fn findWord(src: []const u8, lo: usize, hi_in: usize, name: []const u8) ?Offsets {
    if (name.len == 0) return null;
    const hi = @min(hi_in, src.len);
    if (lo >= hi or lo + name.len > hi) return null;
    var i = lo;
    while (i + name.len <= hi) : (i += 1) {
        if (!std.mem.eql(u8, src[i .. i + name.len], name)) continue;
        if (i > 0 and isIdentByte(src[i - 1])) continue;
        if (i + name.len < src.len and isIdentByte(src[i + name.len])) continue;
        return .{ .start = i, .end = i + name.len };
    }
    return null;
}

/// The byte offsets of `name` within `span`. The compiler gives a whole
/// declaration's span (a function's includes its body), so scan for the first
/// whole-word occurrence to land on the name; fall back to a zero-width range
/// at the span start.
pub fn nameOffsets(src: []const u8, span: hcc.source.Span, name: []const u8) Offsets {
    return findWord(src, span.start, span.end, name) orelse .{ .start = span.start, .end = span.start };
}

pub fn rangeFromOffsets(src: []const u8, off: Offsets) Range {
    return .{
        .start = position.offsetToPosition(src, off.start),
        .end = position.offsetToPosition(src, off.end),
    };
}

/// Locates the declaration of `name` among the top-level items of the user's
/// file (span.file == 0), preferring a real definition over a prototype so the
/// jump lands on the body. Returns the name's byte offsets, or null when the
/// name is not declared in this file.
pub fn findDef(src: []const u8, items: []const *hcc.ast.Stmt, name: []const u8) ?Offsets {
    if (name.len == 0) return null;
    var best: ?Offsets = null;
    var best_is_proto = false;
    for (items) |item| {
        if (item.span.file != 0) continue;
        switch (item.kind) {
            .func_def => |f| if (std.mem.eql(u8, f.name, name)) {
                const proto = f.isPrototype();
                if (best == null or (best_is_proto and !proto)) {
                    best = nameOffsets(src, item.span, name);
                    best_is_proto = proto;
                }
            },
            .class_def => |c| if (std.mem.eql(u8, c.name, name)) {
                if (best == null) best = nameOffsets(src, item.span, name);
            },
            .var_decl => |decls| for (decls) |d| {
                if (std.mem.eql(u8, d.name, name) and best == null) best = nameOffsets(src, d.span, name);
            },
            else => {},
        }
    }
    return best;
}

/// A core declaration located for go-to-definition into the embedded core:
/// the core file's name (e.g. "StrPrint.HC") and the range covering the name in
/// that file's source.
pub const CoreDef = struct {
    core_name: []const u8,
    range: Range,
};

/// Locates the declaration of `name` among the top-level items that came from
/// the embedded core (an item whose file, via `files`, is a core file),
/// preferring a real definition over a prototype. Ranges are computed against
/// the core file's own source (from `hcc.core`), which is byte-identical to the
/// extracted cache copy the returned range will point into. Returns null when
/// `name` is not declared in the core.
pub fn findCoreDef(
    items: []const *hcc.ast.Stmt,
    files: []const hcc.source.FileInfo,
    name: []const u8,
) ?CoreDef {
    if (name.len == 0) return null;
    var best: ?CoreDef = null;
    var best_is_proto = false;
    for (items) |item| {
        const fid = item.span.file;
        if (fid == 0 or fid >= files.len) continue;
        const core_name = files[fid].name;
        const text = hcc.core.get(core_name) orelse continue;
        switch (item.kind) {
            .func_def => |f| if (std.mem.eql(u8, f.name, name)) {
                const proto = f.isPrototype();
                if (best == null or (best_is_proto and !proto)) {
                    best = .{ .core_name = core_name, .range = rangeFromOffsets(text, nameOffsets(text, item.span, name)) };
                    best_is_proto = proto;
                }
            },
            .class_def => |c| if (std.mem.eql(u8, c.name, name)) {
                if (best == null) best = .{ .core_name = core_name, .range = rangeFromOffsets(text, nameOffsets(text, item.span, name)) };
            },
            .var_decl => |decls| for (decls) |d| {
                if (std.mem.eql(u8, d.name, name) and best == null)
                    best = .{ .core_name = core_name, .range = rangeFromOffsets(text, nameOffsets(text, d.span, name)) };
            },
            else => {},
        }
    }
    return best;
}

/// Collects every top-level declaration's name and name-range in the user's
/// file, for the workspace index. Names are duped into `alloc`; a real
/// definition's range wins over a prototype's.
pub fn collectDefs(
    alloc: std.mem.Allocator,
    src: []const u8,
    items: []const *hcc.ast.Stmt,
) error{OutOfMemory}![]const Def {
    var list: std.ArrayList(Def) = .empty;
    errdefer list.deinit(alloc);
    for (items) |item| {
        if (item.span.file != 0) continue;
        switch (item.kind) {
            .func_def => |f| {
                if (f.name.len != 0) try putDef(alloc, &list, src, item.span, f.name, f.isPrototype());
            },
            .class_def => |c| {
                if (c.name.len != 0) try putDef(alloc, &list, src, item.span, c.name, false);
            },
            .var_decl => |decls| for (decls) |d| {
                if (d.name.len != 0) try putDef(alloc, &list, src, d.span, d.name, false);
            },
            else => {},
        }
    }
    return list.toOwnedSlice(alloc);
}

fn putDef(
    alloc: std.mem.Allocator,
    list: *std.ArrayList(Def),
    src: []const u8,
    span: hcc.source.Span,
    name: []const u8,
    is_proto: bool,
) error{OutOfMemory}!void {
    const range = rangeFromOffsets(src, nameOffsets(src, span, name));
    for (list.items) |*existing| {
        if (std.mem.eql(u8, existing.name, name)) {
            // A real definition replaces an earlier prototype; a prototype never
            // overrides an existing entry.
            if (!is_proto) existing.range = range;
            return;
        }
    }
    try list.append(alloc, .{ .name = try alloc.dupe(u8, name), .range = range });
}

/// A bare-identifier use: the name and the range covering it. Backs the
/// workspace-wide use index for cross-file find-references.
pub const Use = struct {
    name: []const u8,
    range: Range,
};

/// Collects the range of every bare-identifier use of `name` in the user's
/// file. Declaration sites are not uses (the declared name is not an identifier
/// expression), so they are excluded.
pub fn collectRefs(
    alloc: std.mem.Allocator,
    src: []const u8,
    items: []const *hcc.ast.Stmt,
    name: []const u8,
) error{OutOfMemory}![]const Range {
    var sink: RefSink = .{ .alloc = alloc, .src = src, .name = name };
    errdefer sink.list.deinit(alloc);
    for (items) |item| {
        if (item.span.file == 0) try walkStmt(&sink, item);
    }
    return sink.list.toOwnedSlice(alloc);
}

/// Collects every bare-identifier use in the user's file, with its name (duped
/// into `alloc`). For the workspace index, so another file's uses of a symbol
/// can be found without re-parsing it.
pub fn collectUses(
    alloc: std.mem.Allocator,
    src: []const u8,
    items: []const *hcc.ast.Stmt,
) error{OutOfMemory}![]const Use {
    var sink: UseSink = .{ .alloc = alloc, .src = src };
    errdefer sink.list.deinit(alloc);
    for (items) |item| {
        if (item.span.file == 0) try walkStmt(&sink, item);
    }
    return sink.list.toOwnedSlice(alloc);
}

/// Appends the ranges of uses whose name matches `name`.
const RefSink = struct {
    alloc: std.mem.Allocator,
    src: []const u8,
    name: []const u8,
    list: std.ArrayList(Range) = .empty,

    fn onIdent(self: *RefSink, name: []const u8, span: hcc.source.Span) error{OutOfMemory}!void {
        if (span.file == 0 and std.mem.eql(u8, name, self.name)) {
            try self.list.append(self.alloc, rangeFromOffsets(self.src, .{ .start = span.start, .end = span.end }));
        }
    }
};

/// Appends every use, duping its name into `alloc`.
const UseSink = struct {
    alloc: std.mem.Allocator,
    src: []const u8,
    list: std.ArrayList(Use) = .empty,

    fn onIdent(self: *UseSink, name: []const u8, span: hcc.source.Span) error{OutOfMemory}!void {
        if (span.file != 0) return;
        try self.list.append(self.alloc, .{
            .name = try self.alloc.dupe(u8, name),
            .range = rangeFromOffsets(self.src, .{ .start = span.start, .end = span.end }),
        });
    }
};

// The tree walk, generic over a sink with an `onIdent(name, span)` method. It
// mirrors Server's ExprFinder traversal so every expression-bearing position is
// visited; a member access (`x.field`) descends only into its base, so `field`
// is not treated as a use of a top-level `field`.

fn walkStmts(sink: anytype, stmts: []const *hcc.ast.Stmt) error{OutOfMemory}!void {
    for (stmts) |s| try walkStmt(sink, s);
}

fn walkStmt(sink: anytype, stmt: *const hcc.ast.Stmt) error{OutOfMemory}!void {
    switch (stmt.kind) {
        .expr => |e| try walkExpr(sink, e),
        .block, .lock => |stmts| try walkStmts(sink, stmts),
        .var_decl => |decls| for (decls) |d| try walkOpt(sink, d.init),
        .if_stmt => |k| {
            try walkExpr(sink, k.cond);
            try walkStmt(sink, k.then);
            if (k.els) |els| try walkStmt(sink, els);
        },
        .while_stmt => |k| {
            try walkExpr(sink, k.cond);
            try walkStmt(sink, k.body);
        },
        .do_while => |k| {
            try walkStmt(sink, k.body);
            try walkExpr(sink, k.cond);
        },
        .for_stmt => |k| {
            if (k.init) |i| try walkStmt(sink, i);
            try walkOpt(sink, k.cond);
            try walkOpt(sink, k.step);
            try walkStmt(sink, k.body);
        },
        .switch_stmt => |k| {
            try walkExpr(sink, k.cond);
            try walkStmt(sink, k.body);
        },
        .case => |k| {
            try walkOpt(sink, k.lo);
            try walkOpt(sink, k.hi);
        },
        .return_stmt => |v| try walkOpt(sink, v),
        .throw => |v| try walkOpt(sink, v),
        .try_stmt => |k| {
            try walkStmts(sink, k.body);
            try walkStmts(sink, k.handler);
        },
        .func_def => |fd| {
            for (fd.params) |p| try walkOpt(sink, p.default_value);
            try walkStmts(sink, fd.body orelse &.{});
        },
        .class_def => |c| for (c.fields) |field| try walkOpt(sink, field.init),
        .empty, .no_warn, .default, .switch_start, .switch_end, .break_stmt, .goto_stmt, .label, .asm_stmt => {},
    }
}

fn walkOpt(sink: anytype, expr: ?*const hcc.ast.Expr) error{OutOfMemory}!void {
    if (expr) |e| try walkExpr(sink, e);
}

fn walkExpr(sink: anytype, e: *const hcc.ast.Expr) error{OutOfMemory}!void {
    switch (e.kind) {
        .ident => |n| try sink.onIdent(n, e.span),
        .unary => |k| try walkExpr(sink, k.expr),
        .postfix => |k| try walkExpr(sink, k.expr),
        .binary => |k| {
            try walkExpr(sink, k.lhs);
            try walkExpr(sink, k.rhs);
        },
        .assign => |k| {
            try walkExpr(sink, k.target);
            try walkExpr(sink, k.value);
        },
        .call => |k| {
            try walkExpr(sink, k.callee);
            for (k.args) |arg| try walkOpt(sink, arg);
        },
        .index => |k| {
            try walkExpr(sink, k.base);
            try walkExpr(sink, k.index);
        },
        .member => |k| try walkExpr(sink, k.base),
        .cast => |k| try walkExpr(sink, k.expr),
        .sizeof => |k| try walkOpt(sink, k.expr),
        .init_list, .comma => |elems| for (elems) |el| try walkExpr(sink, el),
        .designated_init => |fields| for (fields) |field| try walkExpr(sink, field.value),
        .int_lit, .float_lit, .str_lit, .char_lit, .offset, .lastclass => {},
    }
}

/// Builds a file:// URI for an absolute filesystem path, percent-encoding bytes
/// outside the unreserved set (path separators are kept literal). Matches the
/// encoding editors send, so a scanned file's URI equals the one the editor
/// uses for the same open document.
pub fn pathToUri(gpa: std.mem.Allocator, path: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "file://");
    const hex = "0123456789ABCDEF";
    for (path) |b| {
        if (isIdentByte(b) or b == '/' or b == '.' or b == '-' or b == '~') {
            try out.append(gpa, b);
        } else {
            try out.appendSlice(gpa, &.{ '%', hex[b >> 4], hex[b & 0x0F] });
        }
    }
    return out.toOwnedSlice(gpa);
}

// ---- tests ----

test wordAt {
    const src = "I64  Sum(I64 n)";
    try std.testing.expectEqualStrings("Sum", wordAt(src, 6)); // inside the word
    try std.testing.expectEqualStrings("Sum", wordAt(src, 5)); // start of the word
    try std.testing.expectEqualStrings("Sum", wordAt(src, 8)); // one past the word
    try std.testing.expectEqualStrings("I64", wordAt(src, 3)); // one past "I64" counts as inside it
    try std.testing.expectEqualStrings("", wordAt(src, 4)); // in the gap between the two spaces
}

test findCoreDef {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var diags = hcc.diag.Diagnostics.init(arena);
    var files: []const hcc.source.FileInfo = &.{};
    const res = try hcc.frontend.run(arena, &diags, std.testing.io, "U0 Main() {}\n", .{
        .target = hcc.target.Target.host(),
        .inject_core = true,
        .files_out = &files,
    });

    // A core function resolves to its core file (FltToBits is in StrPrint.HC).
    const pd = findCoreDef(res.program.items, files, "FltToBits") orelse
        return error.CoreSymbolNotFound;
    try std.testing.expectEqualStrings("StrPrint.HC", pd.core_name);
    try std.testing.expect(hcc.core.exists(pd.core_name));

    // A user-file symbol (file 0) is not a core def, nor is an unknown name.
    try std.testing.expect(findCoreDef(res.program.items, files, "Main") == null);
    try std.testing.expect(findCoreDef(res.program.items, files, "NopeNotReal") == null);
}

test pathToUri {
    const gpa = std.testing.allocator;
    const plain = try pathToUri(gpa, "/tmp/a/main.HC");
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("file:///tmp/a/main.HC", plain);
    const spaced = try pathToUri(gpa, "/tmp/a b/main.HC");
    defer gpa.free(spaced);
    try std.testing.expectEqualStrings("file:///tmp/a%20b/main.HC", spaced);
}
