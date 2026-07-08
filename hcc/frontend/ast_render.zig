//! Human-readable AST dump: one node per line, indented children, inferred
//! types shown when sema has run. Drives `hcc --emit ast` and serves as a
//! regression net for parser changes.

const std = @import("std");
const ast = @import("ast.zig");
const source = @import("source.zig");

pub const Options = struct {
    /// Hide items from the injected core (any file other than the root source),
    /// so the dump shows only the user's code.
    user_code_only: bool = true,
};

pub fn renderProgram(prog: *const ast.Program, w: *std.Io.Writer, opts: Options) std.Io.Writer.Error!void {
    for (prog.items) |item| {
        if (opts.user_code_only and item.span.file != 0) continue;
        try renderStmt(item, w, 0);
    }
}

fn indent(w: *std.Io.Writer, depth: usize) !void {
    for (0..depth) |_| try w.writeAll("  ");
}

fn renderType(ty: ?ast.Type, w: *std.Io.Writer) !void {
    try ast.Type.render(ty, w);
}

pub fn renderStmt(stmt: *const ast.Stmt, w: *std.Io.Writer, depth: usize) std.Io.Writer.Error!void {
    try indent(w, depth);
    switch (stmt.kind) {
        .empty => try w.writeAll("Empty\n"),
        .expr => |e| {
            try w.writeAll("ExprStmt\n");
            try renderExpr(e, w, depth + 1);
        },
        .block => |stmts| {
            try w.writeAll("Block\n");
            for (stmts) |s| try renderStmt(s, w, depth + 1);
        },
        .lock => |stmts| {
            try w.writeAll("Lock\n");
            for (stmts) |s| try renderStmt(s, w, depth + 1);
        },
        .no_warn => |names| {
            try w.writeAll("NoWarn");
            for (names) |n| try w.print(" {s}", .{n});
            try w.writeAll("\n");
        },
        .var_decl => |decls| {
            try w.writeAll("VarDecl\n");
            for (decls) |d| try renderDeclarator(&d, w, depth + 1);
        },
        .if_stmt => |k| {
            try w.writeAll("If\n");
            try renderExpr(k.cond, w, depth + 1);
            try renderStmt(k.then, w, depth + 1);
            if (k.els) |e| {
                try indent(w, depth);
                try w.writeAll("Else\n");
                try renderStmt(e, w, depth + 1);
            }
        },
        .while_stmt => |k| {
            try w.writeAll("While\n");
            try renderExpr(k.cond, w, depth + 1);
            try renderStmt(k.body, w, depth + 1);
        },
        .do_while => |k| {
            try w.writeAll("DoWhile\n");
            try renderStmt(k.body, w, depth + 1);
            try renderExpr(k.cond, w, depth + 1);
        },
        .for_stmt => |k| {
            try w.writeAll("For\n");
            if (k.init) |i| try renderStmt(i, w, depth + 1);
            if (k.cond) |c| try renderExpr(c, w, depth + 1);
            if (k.step) |s| try renderExpr(s, w, depth + 1);
            try renderStmt(k.body, w, depth + 1);
        },
        .switch_stmt => |k| {
            try w.writeAll("Switch");
            if (k.no_bounds) try w.writeAll(" [nobounds]");
            if (k.sub) try w.writeAll(" [sub]");
            try w.writeAll("\n");
            try renderExpr(k.cond, w, depth + 1);
            try renderStmt(k.body, w, depth + 1);
        },
        .case => |k| {
            try w.writeAll("Case\n");
            if (k.lo) |lo| try renderExpr(lo, w, depth + 1);
            if (k.hi) |hi| try renderExpr(hi, w, depth + 1);
        },
        .default => try w.writeAll("Default\n"),
        .switch_start => try w.writeAll("SwitchStart\n"),
        .switch_end => try w.writeAll("SwitchEnd\n"),
        .break_stmt => try w.writeAll("Break\n"),
        .return_stmt => |v| {
            try w.writeAll("Return\n");
            if (v) |e| try renderExpr(e, w, depth + 1);
        },
        .goto_stmt => |label| try w.print("Goto {s}\n", .{label}),
        .label => |name| try w.print("Label {s}\n", .{name}),
        .try_stmt => |k| {
            try w.writeAll("Try\n");
            for (k.body) |s| try renderStmt(s, w, depth + 1);
            try indent(w, depth);
            try w.writeAll("Catch\n");
            for (k.handler) |s| try renderStmt(s, w, depth + 1);
        },
        .throw => |v| {
            try w.writeAll("Throw\n");
            if (v) |e| try renderExpr(e, w, depth + 1);
        },
        .func_def => |f| {
            try w.print("FuncDef {s} ret=", .{f.name});
            try renderType(f.ret, w);
            if (f.varargs) try w.writeAll(" varargs");
            if (f.is_public) try w.writeAll(" public");
            if (f.asm_label.len > 0) try w.print(" asm_label={s}", .{f.asm_label});
            if (f.import) try w.writeAll(" import");
            if (f.isPrototype()) try w.writeAll(" prototype");
            try w.writeAll("\n");
            for (f.params) |p| {
                try indent(w, depth + 1);
                try w.print("Param {s}: ", .{if (p.name.len > 0) p.name else "_"});
                try renderType(p.ty, w);
                try w.writeAll("\n");
                if (p.default_value) |d| try renderExpr(d, w, depth + 2);
            }
            if (f.body) |body| {
                for (body) |s| try renderStmt(s, w, depth + 1);
            }
        },
        .class_def => |c| {
            try w.print("{s} {s}", .{ @as([]const u8, if (c.is_union) "Union" else "Class"), c.name });
            if (c.base.len > 0) try w.print(" : {s}", .{c.base});
            if (c.is_public) try w.writeAll(" public");
            try w.writeAll("\n");
            for (c.fields) |f| try renderDeclarator(&f, w, depth + 1);
        },
        .asm_stmt => |a| {
            try w.print("Asm {s}\n", .{a.arch});
            for (a.insts) |inst| {
                try indent(w, depth + 1);
                if (inst.isLabel()) {
                    try w.print("Label {s}\n", .{inst.label});
                    continue;
                }
                try w.print("{s}", .{inst.mnemonic});
                for (inst.operands, 0..) |op, i| {
                    try w.writeAll(if (i == 0) " " else ", ");
                    try renderAsmOperand(op, w);
                }
                try w.writeAll("\n");
            }
        },
    }
}

fn renderDeclarator(d: *const ast.Declarator, w: *std.Io.Writer, depth: usize) std.Io.Writer.Error!void {
    try indent(w, depth);
    try w.print("Declarator {s}: ", .{d.name});
    try renderType(d.ty, w);
    switch (d.reg_mode) {
        .none => {},
        .reg => {
            try w.writeAll(" reg");
            if (d.reg_name.len > 0) try w.print("({s})", .{d.reg_name});
        },
        .noreg => try w.writeAll(" noreg"),
    }
    if (d.is_public) try w.writeAll(" public");
    for (d.meta) |m| {
        switch (m.value) {
            .str => |s| try w.print(" meta({s}=\"{s}\")", .{ m.key, s }),
            .int => |v| try w.print(" meta({s}={d})", .{ m.key, v }),
        }
    }
    try w.writeAll("\n");
    if (d.init) |init_expr| try renderExpr(init_expr, w, depth + 1);
}

fn renderAsmOperand(op: ast.AsmOperand, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (op.kind) {
        .reg => |r| try w.print("%{s}", .{r}),
        .imm => |v| try w.print("{d}", .{v}),
        .variable => |n| try w.print("var({s})", .{n}),
        .sym => |n| try w.print("&{s}", .{n}),
        .mem => |m| {
            if (m.ty.len > 0) try w.print("{s} ", .{m.ty});
            try w.writeAll("[");
            var first = true;
            if (m.base.len > 0) {
                try w.print("%{s}", .{m.base});
                first = false;
            }
            if (m.index.len > 0) {
                if (!first) try w.writeAll(" + ");
                try w.print("%{s}*{d}", .{ m.index, m.scale });
                first = false;
            }
            if (m.disp_sym.len > 0) {
                if (!first) try w.writeAll(" + ");
                try w.print("{s}", .{m.disp_sym});
                first = false;
            }
            if (m.disp != 0 or first) {
                if (!first) try w.writeAll(" + ");
                try w.print("{d}", .{m.disp});
            }
            try w.writeAll("]");
        },
    }
}

pub fn renderExpr(e: *const ast.Expr, w: *std.Io.Writer, depth: usize) std.Io.Writer.Error!void {
    try indent(w, depth);
    switch (e.kind) {
        .int_lit => |v| try w.print("Int {d}", .{v}),
        .float_lit => |v| try w.print("Float {d}", .{v}),
        .str_lit => |s| {
            try w.writeAll("Str \"");
            try writeEscaped(s, w);
            try w.writeAll("\"");
        },
        .char_lit => |v| try w.print("Char {d}", .{v}),
        .ident => |n| try w.print("Ident {s}", .{n}),
        .unary => |k| try w.print("Unary {s}", .{k.op.spelling()}),
        .postfix => |k| try w.print("Postfix {s}", .{k.op.spelling()}),
        .binary => |k| try w.print("Binary {s}", .{k.op.spelling()}),
        .assign => |k| try w.print("Assign {s}", .{k.op.spelling()}),
        .call => try w.writeAll("Call"),
        .index => try w.writeAll("Index"),
        .member => |k| try w.print("Member {s}{s}", .{ @as([]const u8, if (k.arrow) "->" else "."), k.field }),
        .cast => |k| {
            try w.writeAll("Cast to ");
            try renderType(k.ty, w);
        },
        .sizeof => |k| {
            try w.writeAll("Sizeof");
            if (k.ty) |t| {
                try w.writeAll(" ");
                try renderType(t, w);
            }
        },
        .offset => |k| {
            try w.print("Offset {s}", .{k.class});
            for (k.path) |p| try w.print(".{s}", .{p});
        },
        .init_list => try w.writeAll("InitList"),
        .designated_init => try w.writeAll("DesignatedInit"),
        .comma => try w.writeAll("Comma"),
        .lastclass => try w.writeAll("Lastclass"),
    }
    if (e.ty) |t| {
        try w.writeAll(" :: ");
        try renderType(t, w);
    }
    try w.writeAll("\n");

    switch (e.kind) {
        .unary => |k| try renderExpr(k.expr, w, depth + 1),
        .postfix => |k| try renderExpr(k.expr, w, depth + 1),
        .binary => |k| {
            try renderExpr(k.lhs, w, depth + 1);
            try renderExpr(k.rhs, w, depth + 1);
        },
        .assign => |k| {
            try renderExpr(k.target, w, depth + 1);
            try renderExpr(k.value, w, depth + 1);
        },
        .call => |k| {
            try renderExpr(k.callee, w, depth + 1);
            for (k.args) |arg| {
                if (arg) |a| {
                    try renderExpr(a, w, depth + 1);
                } else {
                    try indent(w, depth + 1);
                    try w.writeAll("SkippedArg\n");
                }
            }
        },
        .index => |k| {
            try renderExpr(k.base, w, depth + 1);
            try renderExpr(k.index, w, depth + 1);
        },
        .member => |k| try renderExpr(k.base, w, depth + 1),
        .cast => |k| try renderExpr(k.expr, w, depth + 1),
        .sizeof => |k| {
            if (k.expr) |inner| try renderExpr(inner, w, depth + 1);
        },
        .init_list, .comma => |items| {
            for (items) |item| try renderExpr(item, w, depth + 1);
        },
        .designated_init => |fields| {
            for (fields) |f| {
                try indent(w, depth + 1);
                try w.print(".{s} =\n", .{f.name});
                try renderExpr(f.value, w, depth + 2);
            }
        },
        else => {},
    }
}

fn writeEscaped(s: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (s) |c| {
        switch (c) {
            '\n' => try w.writeAll("\\n"),
            '\t' => try w.writeAll("\\t"),
            '\r' => try w.writeAll("\\r"),
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            else => {
                if (c < 0x20) {
                    try w.print("\\x{X:0>2}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
}
