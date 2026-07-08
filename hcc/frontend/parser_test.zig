//! Parser tests: ports of the Go parser_asm_test.go / asm_arch_test.go parse
//! cases, targeted unit tests for HolyC's quirky parses, and the
//! conformance-fixture sweep (every testdata/*.HC file must parse).

const std = @import("std");
const testing = std.testing;
const source = @import("source.zig");
const diag = @import("diag.zig");
const target_mod = @import("target.zig");
const Preprocessor = @import("Preprocessor.zig");
const Parser = @import("Parser.zig");
const ast = @import("ast.zig");

/// A parsed test program plus the state that owns its memory.
const TestParse = struct {
    arena_state: *std.heap.ArenaAllocator,
    diags: *diag.Diagnostics,
    prog: ast.Program,

    fn init(src: []const u8, opts: Preprocessor.Options) !TestParse {
        const arena_state = try testing.allocator.create(std.heap.ArenaAllocator);
        errdefer testing.allocator.destroy(arena_state);
        arena_state.* = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();
        const diags = try arena.create(diag.Diagnostics);
        diags.* = diag.Diagnostics.init(arena);
        const pp = try arena.create(Preprocessor);
        pp.* = try Preprocessor.init(arena, diags, testing.io, src, opts);
        var parser = Parser.init(arena, diags, pp);
        const prog = try parser.parse();
        return .{ .arena_state = arena_state, .diags = diags, .prog = prog };
    }

    fn deinit(t: *TestParse) void {
        t.arena_state.deinit();
        testing.allocator.destroy(t.arena_state);
    }
};

/// The FuncDef named `name` among the program's top-level items.
fn fnDef(prog: ast.Program, name: []const u8) ?*const ast.FuncDef {
    for (prog.items) |it| {
        switch (it.kind) {
            .func_def => |f| if (std.mem.eql(u8, f.name, name)) return f,
            else => {},
        }
    }
    return null;
}

/// The first AsmStmt in F's body, mirroring the Go parseAsmBlock helper.
fn findFnAsm(prog: ast.Program, name: []const u8) ?*const ast.AsmStmt {
    const f = fnDef(prog, name) orelse return null;
    for (f.body orelse &.{}) |s| {
        switch (s.kind) {
            .asm_stmt => |a| return a,
            else => {},
        }
    }
    return null;
}

const AsmFixture = struct {
    tp: TestParse,
    a: *const ast.AsmStmt,

    fn deinit(f: *AsmFixture) void {
        f.tp.deinit();
    }
};

/// Parses body (an `asm { … }` block placed inside a function F) and returns
/// F's AsmStmt — the Zig replica of Go's parseAsmBlock.
fn parseAsmBlock(comptime body: []const u8) !AsmFixture {
    var tp = try TestParse.init("U0 F()\n{\n" ++ body ++ "\n}\n", .{ .inject_core = false });
    errdefer tp.deinit();
    const a = findFnAsm(tp.prog, "F") orelse return error.TestUnexpectedResult;
    return .{ .tp = tp, .a = a };
}

// ---- ports of hcc/parser_asm_test.go ----

test "parse asm arch" {
    var bare = try parseAsmBlock("asm { RET }");
    defer bare.deinit();
    try testing.expectEqualStrings("amd64", bare.a.arch);

    var amd = try parseAsmBlock("asm amd64 { RET }");
    defer amd.deinit();
    try testing.expectEqualStrings("amd64", amd.a.arch);

    var arm = try parseAsmBlock("asm arm64 { ret }");
    defer arm.deinit();
    try testing.expectEqualStrings("arm64", arm.a.arch);
}

test "parse asm instructions and labels" {
    var f = try parseAsmBlock(
        \\asm {
        \\LOOP::
        \\  MOV RAX, 5
        \\  ADD RAX, RBX
        \\  DEC RCX
        \\  JMP &LOOP
        \\  RET
        \\}
    );
    defer f.deinit();
    const a = f.a;
    // 1 label + 5 instructions.
    try testing.expectEqual(@as(usize, 6), a.insts.len);
    try testing.expect(a.insts[0].isLabel());
    try testing.expectEqualStrings("LOOP", a.insts[0].label);
    try testing.expect(a.definesLabel());

    const mov = a.insts[1];
    try testing.expectEqualStrings("MOV", mov.mnemonic);
    try testing.expectEqual(@as(usize, 2), mov.operands.len);
    try testing.expectEqualStrings("RAX", mov.operands[0].kind.reg);
    try testing.expectEqual(@as(i64, 5), mov.operands[1].kind.imm);

    const jmp = a.insts[4];
    try testing.expectEqualStrings("JMP", jmp.mnemonic);
    try testing.expectEqual(@as(usize, 1), jmp.operands.len);
    try testing.expectEqualStrings("LOOP", jmp.operands[0].kind.sym);

    const ret = a.insts[5];
    try testing.expectEqualStrings("RET", ret.mnemonic);
    try testing.expectEqual(@as(usize, 0), ret.operands.len);
}

test "parse asm immediates" {
    var f = try parseAsmBlock(
        \\asm {
        \\  MOV RAX, 0xFF
        \\  MOV RBX, -3
        \\  MOV RCX, 'A'
        \\}
    );
    defer f.deinit();
    const want = [_]i64{ 0xFF, -3, 'A' };
    for (want, 0..) |w, i| {
        try testing.expectEqual(w, f.a.insts[i].operands[1].kind.imm);
    }
}

test "parse asm memory operands" {
    var f = try parseAsmBlock(
        \\asm {
        \\  MOV RAX, [RBP]
        \\  MOV RAX, [RBP-8]
        \\  MOV RAX, [RAX+RBX*4+16]
        \\  MOV RAX, U64 8[RBP]
        \\  MOV RAX, U32 SF_ARG1[RBP]
        \\}
    );
    defer f.deinit();
    const Want = struct {
        ty: []const u8 = "",
        base: []const u8 = "",
        index: []const u8 = "",
        scale: i64 = 0,
        disp: i64 = 0,
        disp_sym: []const u8 = "",
    };
    const wants = [_]Want{
        .{ .base = "RBP" },
        .{ .base = "RBP", .disp = -8 },
        .{ .base = "RAX", .index = "RBX", .scale = 4, .disp = 16 },
        .{ .ty = "U64", .base = "RBP", .disp = 8 },
        .{ .ty = "U32", .base = "RBP", .disp_sym = "SF_ARG1" },
    };
    for (wants, 0..) |w, i| {
        const mem = f.a.insts[i].operands[1].kind.mem;
        try testing.expectEqualStrings(w.ty, mem.ty);
        try testing.expectEqualStrings(w.base, mem.base);
        try testing.expectEqualStrings(w.index, mem.index);
        try testing.expectEqual(w.scale, mem.scale);
        try testing.expectEqual(w.disp, mem.disp);
        try testing.expectEqualStrings(w.disp_sym, mem.disp_sym);
    }
}

test "parse asm variable operand" {
    // A bare name that is not a register is a HolyC variable reference.
    var f = try parseAsmBlock("  I64 x = 0;\n  asm { ADD RAX, x }");
    defer f.deinit();
    try testing.expectEqualStrings("x", f.a.insts[0].operands[1].kind.variable);
}

// ---- ports of the parse-relevant part of hcc/asm_arch_test.go ----
// (The Go tests exercise Lower's arch-mismatch diagnostics, which are a later
// milestone; here the same sources must parse and yield the expected shapes.)

test "arch-paired asm sources parse" {
    var unpaired = try TestParse.init(
        \\I64 F(I64 a) {
        \\  asm arm64 { LDR X9, a }
        \\  return a;
        \\}
        \\"%d\n", F(1);
        \\
    , .{ .inject_core = false });
    defer unpaired.deinit();
    const uf = fnDef(unpaired.prog, "F").?;
    try testing.expectEqualStrings("arm64", uf.body.?[0].kind.asm_stmt.arch);

    var paired = try TestParse.init(
        \\I64 F(I64 a) {
        \\  asm       { MOV RAX, a }
        \\  asm arm64 { LDR X9, a }
        \\  return a;
        \\}
        \\"%d\n", F(1);
        \\
    , .{ .inject_core = false });
    defer paired.deinit();
    const pf = fnDef(paired.prog, "F").?;
    try testing.expectEqualStrings("amd64", pf.body.?[0].kind.asm_stmt.arch);
    try testing.expectEqualStrings("arm64", pf.body.?[1].kind.asm_stmt.arch);

    var global = try TestParse.init(
        \\I64 g = 0;
        \\U0 F() { asm arm64 { STR X9, g } }
        \\F();
        \\
    , .{ .inject_core = false });
    defer global.deinit();
    const ga = findFnAsm(global.prog, "F").?;
    try testing.expectEqualStrings("g", ga.insts[0].operands[1].kind.variable);
}

// ---- targeted unit tests for the quirky parses ----

test "paren-less call statement stays a bare identifier" {
    var tp = try TestParse.init("U0 Hello()\n{\n}\nHello;\n", .{ .inject_core = false });
    defer tp.deinit();
    // The definition has an empty (non-null) body: it is not a prototype.
    const f = fnDef(tp.prog, "Hello").?;
    try testing.expect(!f.isPrototype());
    try testing.expectEqual(@as(usize, 0), f.body.?.len);
    // The parser emits the bare identifier; sema turns it into a call.
    try testing.expectEqualStrings("Hello", tp.prog.items[1].kind.expr.kind.ident);
}

test "implicit print statement is a comma expression" {
    var tp = try TestParse.init("I64 x = 1;\n\"x = %d\\n\", x;\n", .{ .inject_core = false });
    defer tp.deinit();
    const items = tp.prog.items[1].kind.expr.kind.comma;
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("x = %d\n", items[0].kind.str_lit);
    try testing.expectEqualStrings("x", items[1].kind.ident);
}

test "default and skipped arguments" {
    var tp = try TestParse.init(
        \\I64 Box(I64 w = 2, I64 h = 3) { return w * h; }
        \\Box(, 5);
        \\Box();
        \\
    , .{ .inject_core = false });
    defer tp.deinit();
    const f = fnDef(tp.prog, "Box").?;
    try testing.expectEqual(@as(usize, 2), f.params.len);
    try testing.expectEqual(@as(i64, 2), f.params[0].default_value.?.kind.int_lit);
    try testing.expectEqual(@as(i64, 3), f.params[1].default_value.?.kind.int_lit);

    const skipped = tp.prog.items[1].kind.expr.kind.call;
    try testing.expectEqual(@as(usize, 2), skipped.args.len);
    try testing.expectEqual(@as(?*ast.Expr, null), skipped.args[0]);
    try testing.expectEqual(@as(i64, 5), skipped.args[1].?.kind.int_lit);

    const bare = tp.prog.items[2].kind.expr.kind.call;
    try testing.expectEqual(@as(usize, 0), bare.args.len);
}

test "switch: nobounds, case ranges, auto cases, sublabels, sub_switch" {
    var tp = try TestParse.init(
        \\U0 F(I64 n)
        \\{
        \\  switch [n] {
        \\    start:
        \\      n++;
        \\    case 1 ... 3:
        \\      break;
        \\    case:
        \\      break;
        \\    default:
        \\    end:
        \\      n--;
        \\  }
        \\}
        \\U0 G(I64 n)
        \\{
        \\  switch (n) {
        \\    case 0:
        \\      sub_switch [n] {
        \\        case 0:
        \\          break;
        \\      }
        \\      break;
        \\  }
        \\}
        \\
    , .{ .inject_core = false });
    defer tp.deinit();

    const f = fnDef(tp.prog, "F").?;
    const sw = f.body.?[0].kind.switch_stmt;
    try testing.expect(sw.no_bounds);
    try testing.expect(!sw.sub);
    const stmts = sw.body.kind.block;
    try testing.expectEqual(@as(usize, 9), stmts.len);
    try testing.expect(stmts[0].kind == .switch_start);
    const range_case = stmts[2].kind.case;
    try testing.expectEqual(@as(i64, 1), range_case.lo.?.kind.int_lit);
    try testing.expectEqual(@as(i64, 3), range_case.hi.?.kind.int_lit);
    const auto_case = stmts[4].kind.case;
    try testing.expectEqual(@as(?*ast.Expr, null), auto_case.lo);
    try testing.expectEqual(@as(?*ast.Expr, null), auto_case.hi);
    try testing.expect(stmts[6].kind == .default);
    try testing.expect(stmts[7].kind == .switch_end);

    const g = fnDef(tp.prog, "G").?;
    const outer = g.body.?[0].kind.switch_stmt;
    try testing.expect(!outer.no_bounds);
    const inner = outer.body.kind.block[1].kind.switch_stmt;
    try testing.expect(inner.sub);
    try testing.expect(inner.no_bounds);
}

test "class with base, anonymous embedded union, field meta, inline instances" {
    var tp = try TestParse.init(
        \\class B { I64 x; };
        \\class D : B {
        \\  union { I64 i; U8 b[8]; };
        \\  I64 y format "%X" data 7;
        \\} d1, *d2;
        \\
    , .{ .inject_core = false });
    defer tp.deinit();
    const items = tp.prog.items;
    try testing.expectEqual(@as(usize, 4), items.len);

    const b_def = items[0].kind.class_def;
    try testing.expectEqualStrings("B", b_def.name);
    try testing.expectEqualStrings("", b_def.base);

    const d_def = items[1].kind.class_def;
    try testing.expectEqualStrings("D", d_def.name);
    try testing.expectEqualStrings("B", d_def.base);
    try testing.expectEqual(@as(usize, 2), d_def.fields.len);
    try testing.expectEqualStrings("$anon0", d_def.fields[0].name);
    try testing.expectEqualStrings("$anon0", d_def.fields[0].ty.named);
    try testing.expectEqualStrings("y", d_def.fields[1].name);
    const meta = d_def.fields[1].meta;
    try testing.expectEqual(@as(usize, 2), meta.len);
    try testing.expectEqualStrings("format", meta[0].key);
    try testing.expectEqualStrings("%X", meta[0].value.str);
    try testing.expectEqualStrings("data", meta[1].key);
    try testing.expectEqual(@as(i64, 7), meta[1].value.int);

    // The synthetic aggregate for the embedded union is queued right after D.
    const anon_def = items[2].kind.class_def;
    try testing.expect(anon_def.is_union);
    try testing.expectEqualStrings("$anon0", anon_def.name);
    try testing.expectEqual(@as(usize, 2), anon_def.fields.len);

    // The inline instances become a queued VarDecl of the class type.
    const decls = items[3].kind.var_decl;
    try testing.expectEqual(@as(usize, 2), decls.len);
    try testing.expectEqualStrings("d1", decls[0].name);
    try testing.expectEqualStrings("D", decls[0].ty.named);
    try testing.expectEqualStrings("d2", decls[1].name);
    try testing.expectEqualStrings("D", decls[1].ty.ptr.named);
}

test "designated initializer and init list" {
    var tp = try TestParse.init(
        \\class Point { I64 x, y; };
        \\Point pt = {.x = 1, .y = 2};
        \\I64 arr[3] = {1, 2, 3};
        \\
    , .{ .inject_core = false });
    defer tp.deinit();

    const pt = tp.prog.items[1].kind.var_decl[0];
    const fields = pt.init.?.kind.designated_init;
    try testing.expectEqual(@as(usize, 2), fields.len);
    try testing.expectEqualStrings("x", fields[0].name);
    try testing.expectEqual(@as(i64, 1), fields[0].value.kind.int_lit);
    try testing.expectEqualStrings("y", fields[1].name);

    const arr = tp.prog.items[2].kind.var_decl[0];
    try testing.expectEqual(@as(i64, 3), arr.ty.array.size.?.kind.int_lit);
    try testing.expectEqual(@as(usize, 3), arr.init.?.kind.init_list.len);
}

test "no_warn directive" {
    var tp = try TestParse.init(
        \\U0 F()
        \\{
        \\  I64 a, b;
        \\  no_warn a, b;
        \\}
        \\
    , .{ .inject_core = false });
    defer tp.deinit();
    const names = fnDef(tp.prog, "F").?.body.?[1].kind.no_warn;
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("a", names[0]);
    try testing.expectEqualStrings("b", names[1]);
}

test "reg-pinned and noreg locals" {
    var tp = try TestParse.init(
        \\I64 F()
        \\{
        \\  I64 reg R15 acc = 0, noreg i;
        \\  return acc;
        \\}
        \\
    , .{ .inject_core = false });
    defer tp.deinit();
    const decls = fnDef(tp.prog, "F").?.body.?[0].kind.var_decl;
    try testing.expectEqual(@as(usize, 2), decls.len);
    try testing.expectEqualStrings("acc", decls[0].name);
    try testing.expectEqual(ast.RegMode.reg, decls[0].reg_mode);
    try testing.expectEqualStrings("R15", decls[0].reg_name);
    try testing.expect(decls[0].init != null);
    try testing.expectEqualStrings("i", decls[1].name);
    try testing.expectEqual(ast.RegMode.noreg, decls[1].reg_mode);
    try testing.expectEqualStrings("", decls[1].reg_name);
}

test "prefix casts, including known class names" {
    var tp = try TestParse.init(
        \\class C { I64 v; };
        \\F64 f = 3.5;
        \\I64 x = (I64)f;
        \\C *c = (C*)0;
        \\
    , .{ .inject_core = false });
    defer tp.deinit();
    const x_cast = tp.prog.items[2].kind.var_decl[0].init.?.kind.cast;
    try testing.expect(x_cast.ty.isPrim(.I64));
    try testing.expectEqualStrings("f", x_cast.expr.kind.ident);
    const c_cast = tp.prog.items[3].kind.var_decl[0].init.?.kind.cast;
    try testing.expectEqualStrings("C", c_cast.ty.ptr.named);
}

test "postfix cast form is not parsed" {
    // parser.go only supports the prefix cast `(T)x`; `x(I64)` is a call with
    // a type keyword in argument position, which is a parse error.
    try testing.expectError(
        error.CompileFailed,
        TestParse.init("I64 x;\nx(I64);\n", .{ .inject_core = false }),
    );
}

test "backtick pow, logical xor, chained comparisons, precedence" {
    var tp = try TestParse.init(
        \\I64 a = 2 ` 3 ` 2;
        \\I64 b = 1 ^^ 0;
        \\I64 c = 1 < 2 < 3;
        \\I64 d = 1 + 2 << 3;
        \\
    , .{ .inject_core = false });
    defer tp.deinit();

    // ` is right-associative: 2`(3`2).
    const pow = tp.prog.items[0].kind.var_decl[0].init.?.kind.binary;
    try testing.expectEqual(ast.BinOp.pow, pow.op);
    try testing.expectEqual(@as(i64, 2), pow.lhs.kind.int_lit);
    try testing.expectEqual(ast.BinOp.pow, pow.rhs.kind.binary.op);

    const lxor = tp.prog.items[1].kind.var_decl[0].init.?.kind.binary;
    try testing.expectEqual(ast.BinOp.log_xor, lxor.op);

    // 1 < 2 < 3 chains into (1 < 2) && (2 < 3).
    const chain = tp.prog.items[2].kind.var_decl[0].init.?.kind.binary;
    try testing.expectEqual(ast.BinOp.log_and, chain.op);
    try testing.expectEqual(ast.BinOp.lt, chain.lhs.kind.binary.op);
    try testing.expectEqual(ast.BinOp.lt, chain.rhs.kind.binary.op);
    try testing.expectEqual(@as(i64, 2), chain.rhs.kind.binary.lhs.kind.int_lit);

    // Shifts bind tighter than +: 1 + (2 << 3).
    const sum = tp.prog.items[3].kind.var_decl[0].init.?.kind.binary;
    try testing.expectEqual(ast.BinOp.add, sum.op);
    try testing.expectEqual(ast.BinOp.shl, sum.rhs.kind.binary.op);
}

test "function-pointer declarator, implicit params, varargs" {
    var tp = try TestParse.init(
        \\I64 (*op)(I64, I64);
        \\Add(a, b)
        \\{
        \\  return a + b;
        \\}
        \\I64 SumFrom(I64 base, ...)
        \\{
        \\  return base;
        \\}
        \\
    , .{ .inject_core = false });
    defer tp.deinit();

    const op_decl = tp.prog.items[0].kind.var_decl[0];
    try testing.expectEqualStrings("op", op_decl.name);
    const fp = op_decl.ty.func_ptr;
    try testing.expect(fp.ret.isPrim(.I64));
    try testing.expectEqual(@as(usize, 2), fp.params.len);

    // Implicit-return definition with untyped (default-I64) parameters.
    const add = fnDef(tp.prog, "Add").?;
    try testing.expect(add.ret.isPrim(.I64));
    try testing.expectEqual(@as(usize, 2), add.params.len);
    try testing.expectEqualStrings("a", add.params[0].name);
    try testing.expect(add.params[0].ty.isPrim(.I64));
    try testing.expect(!add.varargs);

    const sum_from = fnDef(tp.prog, "SumFrom").?;
    try testing.expect(sum_from.varargs);
    try testing.expectEqual(@as(usize, 1), sum_from.params.len);
}

test "_extern asm label and extern import declarations" {
    var tp = try TestParse.init(
        \\asm {
        \\T::
        \\  RET
        \\}
        \\_extern T I64 Triple(I64 x);
        \\extern I64 write(I64 fd, U8 *buf, I64 n);
        \\
    , .{ .inject_core = false });
    defer tp.deinit();

    try testing.expect(tp.prog.items[0].kind.asm_stmt.definesLabel());

    const triple = fnDef(tp.prog, "Triple").?;
    try testing.expect(triple.isPrototype());
    try testing.expect(triple.is_public);
    try testing.expectEqualStrings("T", triple.asm_label);
    try testing.expect(!triple.import);

    const write_fn = fnDef(tp.prog, "write").?;
    try testing.expect(write_fn.isPrototype());
    try testing.expect(write_fn.import);
    try testing.expectEqual(@as(usize, 3), write_fn.params.len);
}

test "sizeof, offset, lastclass" {
    var tp = try TestParse.init(
        \\class P { I64 x, y; };
        \\I64 a = sizeof(P);
        \\I64 b = sizeof(a);
        \\I64 c = offset(P.y);
        \\U0 F(U8 *cn = lastclass)
        \\{
        \\}
        \\
    , .{ .inject_core = false });
    defer tp.deinit();

    const a_sizeof = tp.prog.items[1].kind.var_decl[0].init.?.kind.sizeof;
    try testing.expectEqualStrings("P", a_sizeof.ty.?.named);
    try testing.expectEqual(@as(?*ast.Expr, null), a_sizeof.expr);

    const b_sizeof = tp.prog.items[2].kind.var_decl[0].init.?.kind.sizeof;
    try testing.expectEqual(@as(?ast.Type, null), b_sizeof.ty);
    try testing.expectEqualStrings("a", b_sizeof.expr.?.kind.ident);

    const c_offset = tp.prog.items[3].kind.var_decl[0].init.?.kind.offset;
    try testing.expectEqualStrings("P", c_offset.class);
    try testing.expectEqual(@as(usize, 1), c_offset.path.len);
    try testing.expectEqualStrings("y", c_offset.path[0]);

    const f = fnDef(tp.prog, "F").?;
    try testing.expect(f.params[0].default_value.?.kind == .lastclass);
}

test "public declarations" {
    var tp = try TestParse.init(
        \\public I64 g = 1;
        \\public U0 F()
        \\{
        \\}
        \\public class K { I64 v; };
        \\public Main()
        \\{
        \\}
        \\
    , .{ .inject_core = false });
    defer tp.deinit();
    try testing.expect(tp.prog.items[0].kind.var_decl[0].is_public);
    try testing.expect(tp.prog.items[1].kind.func_def.is_public);
    try testing.expect(tp.prog.items[2].kind.class_def.is_public);
    const main_fn = fnDef(tp.prog, "Main").?;
    try testing.expect(main_fn.is_public);
    try testing.expect(main_fn.ret.isPrim(.I64));
}

test "lock block and bare throw" {
    var tp = try TestParse.init(
        \\U0 F()
        \\{
        \\  lock {
        \\    F;
        \\  }
        \\  try {
        \\  } catch {
        \\    throw;
        \\  }
        \\}
        \\
    , .{ .inject_core = false });
    defer tp.deinit();
    const body = fnDef(tp.prog, "F").?.body.?;
    try testing.expectEqual(@as(usize, 1), body[0].kind.lock.len);
    const try_stmt = body[1].kind.try_stmt;
    try testing.expectEqual(@as(usize, 0), try_stmt.body.len);
    try testing.expectEqual(@as(?*ast.Expr, null), try_stmt.handler[0].kind.throw);
}

test "anonymous aggregate type is hoisted to the top level" {
    var tp = try TestParse.init(
        \\class { I64 x; I64 y; } a, b;
        \\U0 F(class { I64 w; I64 h; } *r)
        \\{
        \\}
        \\
    , .{ .inject_core = false });
    defer tp.deinit();
    const items = tp.prog.items;
    // VarDecl a,b; FuncDef F; then the two hoisted synthetic ClassDefs.
    try testing.expectEqual(@as(usize, 4), items.len);
    const decls = items[0].kind.var_decl;
    try testing.expectEqual(@as(usize, 2), decls.len);
    try testing.expectEqualStrings("$anon0", decls[0].ty.named);
    const param_ty = fnDef(tp.prog, "F").?.params[0].ty;
    try testing.expectEqualStrings("$anon1", param_ty.ptr.named);
    try testing.expectEqualStrings("$anon0", items[2].kind.class_def.name);
    try testing.expectEqualStrings("$anon1", items[3].kind.class_def.name);
}
