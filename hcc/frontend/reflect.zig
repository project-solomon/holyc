//! Runtime class reflection (HolyC's class metadata). For each named class
//! (user classes and prelude classes alike), this pass synthesizes the
//! descriptor tables that KClass.HC's CHashClass / CMemberLst describe, plus
//! the body of Class(name):
//!
//!   - a `CMemberLst $reflm_<C>[n]` global holding one entry per member, and
//!     a `CHashClass $refl_<C>` global heading the chain;
//!   - top-level statements that fill them (member name (string), offset
//!     (offset(C.m)), size (sizeof(member type)), type spelling (string), and
//!     the `next` links); they run at program entry before user code;
//!   - `Class(name)` returning the matching descriptor (or NULL).
//!
//! It runs after parsing and before sema, so the synthesized AST is
//! type-checked, laid out, and lowered like any other code; no new backend
//! machinery is needed. Descriptor globals are ordinary BSS filled by
//! entry-time stores, and names are ordinary string literals. It is emitted
//! only when the program uses Class/ClassRep.

const std = @import("std");
const source = @import("source.zig");
const ast = @import("ast.zig");

const Oom = error{OutOfMemory};

const prim_u8: ast.Type = .{ .prim = .U8 };
const u8_ptr: ast.Type = .{ .ptr = &prim_u8 };
const cmemberlst_named: ast.Type = .{ .named = "CMemberLst" };
const cmembermeta_named: ast.Type = .{ .named = "CMemberMeta" };
const chashclass_named: ast.Type = .{ .named = "CHashClass" };
const chashclass_ptr: ast.Type = .{ .ptr = &chashclass_named };

/// Appends class-reflection descriptors and the Class() body to prog, in
/// place. A no-op unless the user program calls Class or ClassRep.
pub fn synthReflectMeta(arena: std.mem.Allocator, prog: *ast.Program) Oom!void {
    if (!usesReflection(prog)) return;

    // by_name indexes every class definition (any file, including synthetic
    // anonymous aggregates), so member flattening can follow base classes and
    // expand anonymous embedded unions/structs.
    var by_name: std.StringArrayHashMapUnmanaged(*const ast.ClassDef) = .empty;
    for (prog.items) |it| {
        switch (it.kind) {
            .class_def => |cd| try by_name.put(arena, cd.name, cd),
            else => {},
        }
    }

    var classes: std.ArrayList(*const ast.ClassDef) = .empty;
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (prog.items) |it| {
        const cd = switch (it.kind) {
            .class_def => |cd| cd,
            else => continue,
        };
        // Every named class is reflectable: user classes and prelude classes
        // alike. Skip only compiler-synthesized anonymous aggregates (their
        // members are promoted into their enclosing class) and any duplicate
        // (a prototype plus its definition both reach here).
        if (ast.isAnonField(cd.name)) continue;
        if (seen.contains(cd.name)) continue;
        try seen.put(arena, cd.name, {});
        try classes.append(arena, cd);
    }

    var g = Gen{ .arena = arena };
    var decls: std.ArrayList(*ast.Stmt) = .empty;
    var inits: std.ArrayList(*ast.Stmt) = .empty;

    for (classes.items) |cd| {
        const hc = try std.fmt.allocPrint(arena, "$refl_{s}", .{cd.name});
        const ml = try std.fmt.allocPrint(arena, "$reflm_{s}", .{cd.name});
        var flatten_seen: std.StringArrayHashMapUnmanaged(void) = .empty;
        var members: std.ArrayList(MemberRef) = .empty;
        try flattenMembers(arena, cd, &by_name, &flatten_seen, &members);
        const n = members.items.len;

        if (n > 0) {
            try decls.append(arena, try g.varDecl(ml, try g.arrayType(&cmemberlst_named, @intCast(n))));
        }
        try decls.append(arena, try g.varDecl(hc, chashclass_named));

        for (members.items, 0..) |f, i| {
            try inits.append(arena, try g.assign(try g.elemField(ml, @intCast(i), "str"), try g.str(f.name)));
            try inits.append(arena, try g.assign(try g.elemField(ml, @intCast(i), "off"), try g.offsetExpr(cd.name, f.name)));
            try inits.append(arena, try g.assign(try g.elemField(ml, @intCast(i), "size"), try g.sizeofType(f.ty)));
            try inits.append(arena, try g.assign(try g.elemField(ml, @intCast(i), "member_class"), try g.str(try ast.Type.string(f.ty, arena))));
            if (i + 1 < n) {
                try inits.append(arena, try g.assign(try g.elemField(ml, @intCast(i), "next"), try g.addr(try g.index(try g.ident(ml), @intCast(i + 1)))));
            } else {
                try inits.append(arena, try g.assign(try g.elemField(ml, @intCast(i), "next"), try g.int(0)));
            }

            // Member metadata chain (format/data/...), when present.
            const k = f.meta.len;
            if (k > 0) {
                const mm = try std.fmt.allocPrint(arena, "$reflmeta_{s}_{d}", .{ cd.name, i });
                try decls.append(arena, try g.varDecl(mm, try g.arrayType(&cmembermeta_named, @intCast(k))));
                for (f.meta, 0..) |md, j| {
                    try inits.append(arena, try g.assign(try g.elemField(mm, @intCast(j), "key"), try g.str(md.key)));
                    switch (md.value) {
                        .str => |s| try inits.append(arena, try g.assign(try g.elemField(mm, @intCast(j), "str"), try g.str(s))),
                        .int => |v| try inits.append(arena, try g.assign(try g.elemField(mm, @intCast(j), "val"), try g.int(v))),
                    }
                    if (j + 1 < k) {
                        try inits.append(arena, try g.assign(try g.elemField(mm, @intCast(j), "next"), try g.addr(try g.index(try g.ident(mm), @intCast(j + 1)))));
                    } else {
                        try inits.append(arena, try g.assign(try g.elemField(mm, @intCast(j), "next"), try g.int(0)));
                    }
                }
                try inits.append(arena, try g.assign(try g.elemField(ml, @intCast(i), "meta"), try g.addr(try g.index(try g.ident(mm), 0))));
            } else {
                try inits.append(arena, try g.assign(try g.elemField(ml, @intCast(i), "meta"), try g.int(0)));
            }
        }

        try inits.append(arena, try g.assign(try g.member(try g.ident(hc), "str"), try g.str(cd.name)));
        try inits.append(arena, try g.assign(try g.member(try g.ident(hc), "size"), try g.sizeofType(.{ .named = cd.name })));
        if (n > 0) {
            try inits.append(arena, try g.assign(try g.member(try g.ident(hc), "member_lst_and_root"), try g.addr(try g.index(try g.ident(ml), 0))));
        } else {
            try inits.append(arena, try g.assign(try g.member(try g.ident(hc), "member_lst_and_root"), try g.int(0)));
        }
    }

    // Descriptor globals and Class() are declarations (their order is
    // irrelevant). The init statements must run before user code, so the
    // whole block is prepended: it executes first in the synthesized entry.
    var new_items: std.ArrayList(*ast.Stmt) = .empty;
    try new_items.appendSlice(arena, decls.items);
    try new_items.append(arena, try classFunc(&g, classes.items));
    try new_items.appendSlice(arena, inits.items);
    try new_items.appendSlice(arena, prog.items);
    prog.items = try new_items.toOwnedSlice(arena);
}

/// Whether the user's own code (file 0) calls Class or ClassRep. The resident
/// ClassRep always calls Class, so checking the whole program would always be
/// true. Restricting to file 0 limits the check to user code.
fn usesReflection(prog: *const ast.Program) bool {
    const names = [_][]const u8{ "Class", "ClassRep" };
    for (prog.items) |it| {
        if (it.span.file == 0 and ast.Stmt.callsFn(it, &names)) return true;
    }
    return false;
}

/// One reflectable member after flattening: its name within the class, its
/// type, and any metadata. Inherited and anonymous-union-promoted members are
/// reached by their flat name, which offset()/sizeof() resolve against the
/// class's flattened layout.
const MemberRef = struct {
    name: []const u8,
    ty: ast.Type,
    meta: []const ast.FieldMeta,
};

/// Appends a class's reflectable members in layout order: first the base
/// class's members (a base subobject sits at offset 0), then each own field,
/// with anonymous embedded unions/structs expanded in place into the members
/// they promote. seen guards against a malformed base cycle (the layout pass
/// reports it).
fn flattenMembers(
    arena: std.mem.Allocator,
    cd: *const ast.ClassDef,
    by_name: *const std.StringArrayHashMapUnmanaged(*const ast.ClassDef),
    seen: *std.StringArrayHashMapUnmanaged(void),
    out: *std.ArrayList(MemberRef),
) Oom!void {
    if (seen.contains(cd.name)) return;
    try seen.put(arena, cd.name, {});

    if (cd.base.len > 0) {
        if (by_name.get(cd.base)) |b| {
            try flattenMembers(arena, b, by_name, seen, out);
        }
    }
    for (cd.fields) |f| {
        if (ast.isAnonField(f.name)) {
            switch (f.ty) {
                .named => |nt| {
                    if (by_name.get(nt)) |anon| {
                        try flattenMembers(arena, anon, by_name, seen, out);
                    }
                },
                else => {},
            }
            continue;
        }
        try out.append(arena, .{ .name = f.name, .ty = f.ty, .meta = f.meta });
    }
}

/// Builds `CHashClass *Class(U8 *name)`: one
/// `if (_ReflStrEq(name, "C")) return &$refl_C;` per class, then
/// `return NULL`.
fn classFunc(g: *Gen, classes: []const *const ast.ClassDef) Oom!*ast.Stmt {
    var body: std.ArrayList(*ast.Stmt) = .empty;
    for (classes) |cd| {
        const args = try g.arena.alloc(?*ast.Expr, 2);
        args[0] = try g.ident("name");
        args[1] = try g.str(cd.name);
        const cond = try g.expr(.{ .call = .{ .callee = try g.ident("_ReflStrEq"), .args = args } });
        const refl_name = try std.fmt.allocPrint(g.arena, "$refl_{s}", .{cd.name});
        const ret = try g.stmt(.{ .return_stmt = try g.addr(try g.ident(refl_name)) });
        try body.append(g.arena, try g.stmt(.{ .if_stmt = .{ .cond = cond, .then = ret, .els = null } }));
    }
    try body.append(g.arena, try g.stmt(.{ .return_stmt = try g.int(0) }));

    const params = try g.arena.alloc(ast.Param, 1);
    params[0] = .{ .ty = u8_ptr, .name = "name", .span = Gen.genSpan() };
    const f = try g.arena.create(ast.FuncDef);
    f.* = .{
        .ret = chashclass_ptr,
        .name = "Class",
        .params = params,
        .body = try body.toOwnedSlice(g.arena),
        .is_public = true,
    };
    return g.stmt(.{ .func_def = f });
}

// ---- synthetic-node constructors ----
//
// Every synthesized node carries ast.generated_file as its span's file id, so
// sema treats it as compiler-generated and exempt from file-privacy checks
// (it may reference any user class/member and the resident reflection
// helpers).

const Gen = struct {
    arena: std.mem.Allocator,

    fn genSpan() source.Span {
        return .{ .file = ast.generated_file };
    }

    fn expr(g: *Gen, kind: ast.Expr.Kind) Oom!*ast.Expr {
        const e = try g.arena.create(ast.Expr);
        e.* = .{ .kind = kind, .span = genSpan() };
        return e;
    }

    fn stmt(g: *Gen, kind: ast.Stmt.Kind) Oom!*ast.Stmt {
        const s = try g.arena.create(ast.Stmt);
        s.* = .{ .kind = kind, .span = genSpan() };
        return s;
    }

    fn int(g: *Gen, v: i64) Oom!*ast.Expr {
        return g.expr(.{ .int_lit = v });
    }

    fn str(g: *Gen, s: []const u8) Oom!*ast.Expr {
        return g.expr(.{ .str_lit = s });
    }

    fn ident(g: *Gen, n: []const u8) Oom!*ast.Expr {
        return g.expr(.{ .ident = n });
    }

    fn member(g: *Gen, base: *ast.Expr, field: []const u8) Oom!*ast.Expr {
        return g.expr(.{ .member = .{ .base = base, .field = field, .arrow = false } });
    }

    fn index(g: *Gen, base: *ast.Expr, i: i64) Oom!*ast.Expr {
        return g.expr(.{ .index = .{ .base = base, .index = try g.int(i) } });
    }

    fn addr(g: *Gen, e: *ast.Expr) Oom!*ast.Expr {
        return g.expr(.{ .unary = .{ .op = .addr_of, .expr = e } });
    }

    /// `<arr_name>[i].<field>`, the recurring descriptor-slot target.
    fn elemField(g: *Gen, arr_name: []const u8, i: i64, field: []const u8) Oom!*ast.Expr {
        return g.member(try g.index(try g.ident(arr_name), i), field);
    }

    fn sizeofType(g: *Gen, ty: ast.Type) Oom!*ast.Expr {
        return g.expr(.{ .sizeof = .{ .ty = ty, .expr = null } });
    }

    fn offsetExpr(g: *Gen, class: []const u8, field: []const u8) Oom!*ast.Expr {
        const path = try g.arena.alloc([]const u8, 1);
        path[0] = field;
        return g.expr(.{ .offset = .{ .class = class, .path = path } });
    }

    fn assign(g: *Gen, target: *ast.Expr, value: *ast.Expr) Oom!*ast.Stmt {
        return g.stmt(.{ .expr = try g.expr(.{ .assign = .{ .op = .assign, .target = target, .value = value } }) });
    }

    fn varDecl(g: *Gen, name: []const u8, ty: ast.Type) Oom!*ast.Stmt {
        const decls = try g.arena.alloc(ast.Declarator, 1);
        decls[0] = .{ .name = name, .ty = ty, .span = genSpan(), .is_public = true };
        return g.stmt(.{ .var_decl = decls });
    }

    fn arrayType(g: *Gen, elem: *const ast.Type, count: i64) Oom!ast.Type {
        return .{ .array = .{ .elem = elem, .size = try g.int(count) } };
    }
};
