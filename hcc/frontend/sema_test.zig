//! Sema/layout/reflection tests: the full-pipeline conformance-fixture gate,
//! negative tests for the major semantic rules, layout unit tests, and the
//! warning behaviors.

const std = @import("std");
const testing = std.testing;
const source = @import("source.zig");
const diag = @import("diag.zig");
const target_mod = @import("target.zig");
const ast = @import("ast.zig");
const layout = @import("layout.zig");
const frontend = @import("frontend.zig");

/// A full-pipeline run over an inline source, plus the state that owns its
/// memory. On a compile failure prog is null and the diagnostics carry the
/// errors.
const TestRun = struct {
    arena_state: *std.heap.ArenaAllocator,
    diags: *diag.Diagnostics,
    prog: ?ast.Program,
    failed: bool,

    const Opts = struct {
        inject_core: bool = false,
    };

    fn init(src: []const u8, opts: Opts) !TestRun {
        const arena_state = try testing.allocator.create(std.heap.ArenaAllocator);
        errdefer testing.allocator.destroy(arena_state);
        arena_state.* = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();
        const diags = try arena.create(diag.Diagnostics);
        diags.* = diag.Diagnostics.init(arena);

        var prog: ?ast.Program = null;
        var failed = false;
        if (frontend.run(arena, diags, testing.io, src, .{
            .target = target_mod.Target.host(),
            .inject_core = opts.inject_core,
        })) |res| {
            prog = res.program;
        } else |e| switch (e) {
            error.CompileFailed => failed = true,
            error.OutOfMemory => return error.OutOfMemory,
        }
        return .{ .arena_state = arena_state, .diags = diags, .prog = prog, .failed = failed };
    }

    fn deinit(t: *TestRun) void {
        t.arena_state.deinit();
        testing.allocator.destroy(t.arena_state);
    }

    fn hasDiag(t: *const TestRun, severity: diag.Severity, needle: []const u8) bool {
        for (t.diags.list.items) |d| {
            if (d.severity == severity and std.mem.indexOf(u8, d.message, needle) != null) return true;
        }
        return false;
    }

    /// Expects a failed run with an error diagnostic containing needle.
    fn expectError(t: *const TestRun, needle: []const u8) !void {
        if (!t.failed) {
            std.debug.print("expected a compile failure containing \"{s}\", but the run passed\n", .{needle});
            return error.TestUnexpectedResult;
        }
        if (!t.hasDiag(.@"error", needle)) {
            std.debug.print("no error diagnostic contains \"{s}\"; got:\n", .{needle});
            for (t.diags.list.items) |d| {
                std.debug.print("  [{s}/{s}] {s}\n", .{ @tagName(d.severity), @tagName(d.stage), d.message });
            }
            return error.TestUnexpectedResult;
        }
    }

    /// Expects a clean (no-error) run.
    fn expectClean(t: *const TestRun) !void {
        if (t.failed or t.diags.hasErrors()) {
            std.debug.print("expected a clean run; got:\n", .{});
            for (t.diags.list.items) |d| {
                std.debug.print("  [{s}/{s}] {d}:{d}: {s}\n", .{ @tagName(d.severity), @tagName(d.stage), d.pos.line, d.pos.col, d.message });
            }
            return error.TestUnexpectedResult;
        }
    }
};

fn expectFails(src: []const u8, needle: []const u8) !void {
    var t = try TestRun.init(src, .{});
    defer t.deinit();
    try t.expectError(needle);
}

// ---- negative tests: one per major rule ----

test "undeclared identifier" {
    try expectFails("I64 y = x;\n", "use of undeclared identifier `x`");
}

test "call to undeclared function" {
    try expectFails("Frobnicate(1);\n", "call to undeclared function `Frobnicate`");
}

test "return type mismatches" {
    try expectFails(
        \\U0 F()
        \\{
        \\  return 3;
        \\}
        \\
    , "returning a value from a void (U0/I0) function");
    try expectFails(
        \\I64 G()
        \\{
        \\  return;
        \\}
        \\
    , "missing return value in non-void function");
    try expectFails(
        \\class C { I64 x; };
        \\C H()
        \\{
        \\  return 1;
        \\}
        \\
    , "cannot assign a scalar to class type `C`");
}

test "non-lvalue ++ and & of non-lvalue" {
    try expectFails("++1;\n", "operand of `++`/`--` must be an lvalue");
    try expectFails("I64 p = &(1 + 2);\n", "cannot take the address of a non-lvalue");
}

test "assignment to non-lvalue" {
    try expectFails("1 = 2;\n", "left-hand side of assignment is not an lvalue");
}

test "bad print format spec warns" {
    var t = try TestRun.init(
        \\"%q\n";
        \\"count %d\n";
        \\
    , .{});
    defer t.deinit();
    try t.expectClean();
    try testing.expect(t.hasDiag(.warning, "unknown print conversion `%q`"));
    try testing.expect(t.hasDiag(.warning, "format has 1 conversion(s) but 0 argument(s) given"));
}

test "print argument type mismatch warns" {
    var t = try TestRun.init(
        \\I64 n = 3;
        \\"%f\n", n;
        \\
    , .{});
    defer t.deinit();
    try t.expectClean();
    try testing.expect(t.hasDiag(.warning, "%f expects a floating-point argument"));
}

test "public function returning private type" {
    try expectFails(
        \\class P { I64 x; };
        \\public P F()
        \\{
        \\  P p;
        \\  return p;
        \\}
        \\
    , "`public` function `F` returns non-`public` type `P`");
}

test "case/default/start/end outside of a switch" {
    try expectFails("U0 F() { case 1: ; }\n", "`case` outside of a switch");
    try expectFails("U0 F() { default: ; }\n", "`default` outside of a switch");
    try expectFails("U0 F(I64 n) { sub_switch (n) { case 0: break; } }\n", "`sub_switch` outside of a switch");
}

test "break outside of a loop or switch" {
    try expectFails("U0 F() { break; }\n", "`break` outside of a loop or switch");
}

test "goto to an unknown label" {
    try expectFails("U0 F() { goto missing; }\n", "goto to undefined or out-of-scope label `missing`");
}

test "variable-length arrays are rejected" {
    try expectFails(
        \\U0 F(I64 n)
        \\{
        \\  U8 buf[n];
        \\  buf[0] = 1;
        \\}
        \\
    , "array size must be a constant; variable-length arrays are not supported");
}

test "unknown asm architecture" {
    try expectFails(
        \\U0 F()
        \\{
        \\  asm mips { }
        \\}
        \\
    , "unknown asm architecture `mips`");
}

test "cyclic by-value class composition" {
    var t = try TestRun.init(
        \\class A { A a; };
        \\
    , .{});
    defer t.deinit();
    try t.expectError("type `A` has an infinite size (cycle through itself)");
}

test "mutually cyclic by-value classes" {
    var t = try TestRun.init(
        \\class A;
        \\class B { A a; };
        \\class A { B b; };
        \\
    , .{});
    defer t.deinit();
    try t.expectError("has an infinite size (cycle through itself)");
}

test "unknown class type" {
    // A forward declaration makes the name parse as a type, but it never
    // reaches the type table, so sema reports it (and layout treats it as
    // zero-size).
    try expectFails("class Unknown;\nUnknown u;\n", "unknown type `Unknown`");
}

test "unknown base class" {
    try expectFails("class D : NoSuchBase { I64 x; };\nD d;\nd.x = 1;\n", "unknown base type `NoSuchBase`");
}

test "designated initializer with an unknown field" {
    try expectFails(
        \\class P { I64 x; };
        \\P p = {.y = 1};
        \\
    , "`P` has no field `y`");
}

test "unknown member access" {
    try expectFails(
        \\class P { I64 x; };
        \\P p;
        \\p.nope = 1;
        \\
    , "no field `nope` on type `P`");
}

test "call arity and skipped arguments without defaults" {
    try expectFails(
        \\U0 F(I64 a) {}
        \\F(1, 2);
        \\
    , "function `F` expects at most 1 argument(s), got 2");
    try expectFails(
        \\U0 G(I64 a, I64 b = 7) {}
        \\G(, 1);
        \\
    , "function `G` is missing a value for argument 1, which has no default");
    var ok = try TestRun.init(
        \\U0 H(I64 a = 3, I64 b = 7) {}
        \\H(, 1);
        \\H();
        \\
    , .{});
    defer ok.deinit();
    try ok.expectClean();
}

test "aggregate argument mismatch" {
    try expectFails(
        \\class A { I64 x; };
        \\class B { I64 x; };
        \\U0 F(A a) {}
        \\B b;
        \\F(b);
        \\
    , "argument 1: cannot pass `B` to a parameter of type `A`");
}

test "switch value and labels" {
    try expectFails(
        \\F64 f = 1.5;
        \\switch (f) {
        \\  case 1:
        \\    break;
        \\}
        \\
    , "switch value must be an integer");
    try expectFails(
        \\I64 n = 1;
        \\switch (n) {
        \\  case 1:
        \\    break;
        \\  start:
        \\    n++;
        \\}
        \\
    , "`start:` must come before every `case`");
}

test "redeclaration and redefinition" {
    try expectFails("I64 x;\nI64 x;\n", "redeclaration of `x`");
    try expectFails("class C { I64 a; };\nclass C { I64 b; };\n", "redefinition of type `C`");
    try expectFails("U0 F() {}\nU0 F() {}\n", "redefinition of function `F`");
}

test "offset() path validation" {
    try expectFails("I64 n = offset(NoClass.x);\n", "`NoClass` is not a known class or union");
    try expectFails(
        \\class P { I64 x; };
        \\I64 n = offset(P.x.y);
        \\
    , "`P.x` is not a class, so `offset` cannot descend into it");
}

test "throw value must be an integer" {
    try expectFails(
        \\U0 F()
        \\{
        \\  F64 f = 1.0;
        \\  throw f;
        \\}
        \\
    , "`throw` value must be an integer");
}

test "nested function definitions are rejected" {
    // The parser already rejects the nested definition; sema keeps an
    // equivalent guard for ASTs built by other producers.
    try expectFails(
        \\U0 F()
        \\{
        \\  U0 G() {}
        \\}
        \\
    , "functions may only be defined at the top level");
}

// ---- warnings ----

test "unused variable warns; use and no_warn suppress it" {
    var unused = try TestRun.init(
        \\U0 F()
        \\{
        \\  I64 x;
        \\}
        \\F();
        \\
    , .{});
    defer unused.deinit();
    try unused.expectClean();
    try testing.expect(unused.hasDiag(.warning, "unused variable `x`"));

    var used = try TestRun.init(
        \\U0 F()
        \\{
        \\  I64 x = 0;
        \\  x++;
        \\}
        \\F();
        \\
    , .{});
    defer used.deinit();
    try used.expectClean();
    try testing.expect(!used.hasDiag(.warning, "unused variable"));

    var suppressed = try TestRun.init(
        \\U0 F()
        \\{
        \\  I64 x;
        \\  no_warn x;
        \\}
        \\F();
        \\
    , .{});
    defer suppressed.deinit();
    try suppressed.expectClean();
    try testing.expect(!suppressed.hasDiag(.warning, "unused variable"));
}

test "constant out-of-bounds index warns" {
    var t = try TestRun.init(
        \\I64 arr[3];
        \\arr[5] = 1;
        \\
    , .{});
    defer t.deinit();
    try t.expectClean();
    try testing.expect(t.hasDiag(.warning, "array index 5 is out of bounds for array of size 3"));
}

// ---- layout unit tests ----

/// Runs the pipeline over src and hands the layout table to body.
fn withLayouts(src: []const u8, body: fn (ls: *const layout.Layouts) anyerror!void) !void {
    var t = try TestRun.init(src, .{});
    defer t.deinit();
    try t.expectClean();
    try body(t.prog.?.layouts.?);
}

test "struct padding and alignment" {
    try withLayouts(
        \\class S { I8 a; I64 b; };
        \\S s;
        \\s.a = 1;
        \\
    , struct {
        fn f(ls: *const layout.Layouts) anyerror!void {
            const s = ls.get("S").?;
            try testing.expectEqual(@as(u64, 16), s.size);
            try testing.expectEqual(@as(u64, 8), s.alignment);
            try testing.expectEqual(@as(u64, 0), ls.offsetOf("S", "a").?);
            try testing.expectEqual(@as(u64, 8), ls.offsetOf("S", "b").?);
        }
    }.f);
}

test "sub-int scalar sizes and offsets" {
    try withLayouts(
        \\class T { U16 a; U16 b; I32 c; I8 d; };
        \\T t;
        \\t.a = 1;
        \\
    , struct {
        fn f(ls: *const layout.Layouts) anyerror!void {
            const t = ls.get("T").?;
            try testing.expectEqual(@as(u64, 12), t.size);
            try testing.expectEqual(@as(u64, 4), t.alignment);
            try testing.expectEqual(@as(u64, 2), ls.offsetOf("T", "b").?);
            try testing.expectEqual(@as(u64, 4), ls.offsetOf("T", "c").?);
            try testing.expectEqual(@as(u64, 8), ls.offsetOf("T", "d").?);
            try testing.expectEqual(@as(u64, 2), ls.sizeOf(.{ .prim = .U16 }));
            try testing.expectEqual(@as(u64, 1), ls.sizeOf(.{ .prim = .I8 }));
            try testing.expectEqual(@as(u64, 4), ls.alignOf(.{ .prim = .I32 }));
        }
    }.f);
}

test "union is the max of its members" {
    try withLayouts(
        \\union U { I8 a; I32 b; U8 c[3]; };
        \\U u;
        \\u.b = 1;
        \\
    , struct {
        fn f(ls: *const layout.Layouts) anyerror!void {
            const u = ls.get("U").?;
            try testing.expect(u.is_union);
            try testing.expectEqual(@as(u64, 4), u.size);
            try testing.expectEqual(@as(u64, 4), u.alignment);
            try testing.expectEqual(@as(u64, 0), ls.offsetOf("U", "a").?);
            try testing.expectEqual(@as(u64, 0), ls.offsetOf("U", "b").?);
        }
    }.f);
}

test "inheritance lays the base out first" {
    try withLayouts(
        \\class B { I64 x; I8 y; };
        \\class D : B { I8 z; };
        \\D d;
        \\d.z = 1;
        \\
    , struct {
        fn f(ls: *const layout.Layouts) anyerror!void {
            try testing.expectEqual(@as(u64, 16), ls.get("B").?.size);
            // The derived field starts after the padded base subobject.
            try testing.expectEqual(@as(u64, 16), ls.offsetOf("D", "z").?);
            try testing.expectEqual(@as(u64, 0), ls.offsetOf("D", "x").?);
            try testing.expectEqual(@as(u64, 24), ls.get("D").?.size);
        }
    }.f);
}

test "nested offset paths and array stride" {
    try withLayouts(
        \\class In { I64 a, b; };
        \\class Out { I32 h; In i; In arr[4]; };
        \\Out o;
        \\o.h = 1;
        \\
    , struct {
        fn f(ls: *const layout.Layouts) anyerror!void {
            try testing.expectEqual(@as(u64, 8), ls.offsetOf("Out", "i").?);
            try testing.expectEqual(@as(u64, 16), ls.nestedOffsetOf("Out", &.{ "i", "b" }).?);
            try testing.expectEqual(@as(u64, 16), ls.strideOf(.{ .named = "In" }));
            const arr_field = ls.get("Out").?.field("arr").?;
            try testing.expectEqual(@as(u64, 24), arr_field.offset);
            try testing.expectEqual(@as(u64, 64), arr_field.size);
            try testing.expectEqual(@as(u64, 88), ls.get("Out").?.size);
        }
    }.f);
}

test "sizeof(Class) as an array dimension" {
    try withLayouts(
        \\class K { I64 a, b; };
        \\class Buf { U8 raw[sizeof(K)]; };
        \\Buf b;
        \\b.raw[0] = 1;
        \\
    , struct {
        fn f(ls: *const layout.Layouts) anyerror!void {
            try testing.expectEqual(@as(u64, 16), ls.get("Buf").?.size);
        }
    }.f);
}

test "constEval matches Go int64 semantics" {
    const min = std.math.minInt(i64);
    var min_lit = ast.Expr{ .kind = .{ .int_lit = min }, .span = .{} };
    var neg_one = ast.Expr{ .kind = .{ .int_lit = -1 }, .span = .{} };
    var one = ast.Expr{ .kind = .{ .int_lit = 1 }, .span = .{} };
    var big_shift = ast.Expr{ .kind = .{ .int_lit = 100 }, .span = .{} };
    var zero = ast.Expr{ .kind = .{ .int_lit = 0 }, .span = .{} };

    // INT_MIN / -1 wraps to INT_MIN (no trap), and INT_MIN % -1 is 0.
    var div = ast.Expr{ .kind = .{ .binary = .{ .op = .div, .lhs = &min_lit, .rhs = &neg_one } }, .span = .{} };
    try testing.expectEqual(@as(i64, min), layout.constEval(&div).value);
    var mod = ast.Expr{ .kind = .{ .binary = .{ .op = .mod, .lhs = &min_lit, .rhs = &neg_one } }, .span = .{} };
    try testing.expectEqual(@as(i64, 0), layout.constEval(&mod).value);

    // Division by zero is a fold error, not a crash.
    var div0 = ast.Expr{ .kind = .{ .binary = .{ .op = .div, .lhs = &one, .rhs = &zero } }, .span = .{} };
    try testing.expect(layout.constEval(&div0) == .err);

    // Oversized shifts: << loses everything, >> sign-fills.
    var shl = ast.Expr{ .kind = .{ .binary = .{ .op = .shl, .lhs = &one, .rhs = &big_shift } }, .span = .{} };
    try testing.expectEqual(@as(i64, 0), layout.constEval(&shl).value);
    var shr = ast.Expr{ .kind = .{ .binary = .{ .op = .shr, .lhs = &neg_one, .rhs = &big_shift } }, .span = .{} };
    try testing.expectEqual(@as(i64, -1), layout.constEval(&shr).value);

    // -INT_MIN wraps back to INT_MIN.
    var neg = ast.Expr{ .kind = .{ .unary = .{ .op = .neg, .expr = &min_lit } }, .span = .{} };
    try testing.expectEqual(@as(i64, min), layout.constEval(&neg).value);

    // A variable is not a constant.
    var ident = ast.Expr{ .kind = .{ .ident = "n" }, .span = .{} };
    try testing.expect(layout.constEval(&ident) == .err);
}

// ---- reflection ----

test "reflection synthesis type-checks under the full pipeline" {
    var t = try TestRun.init(
        \\class Pt { I64 x, y; U8 tag format "%X"; };
        \\ClassRep("Pt");
        \\
    , .{ .inject_core = true });
    defer t.deinit();
    try t.expectClean();
    const prog = t.prog.?;

    // The synthesized Class() definition is a top-level item.
    var found_class_fn = false;
    var found_refl_global = false;
    for (prog.items) |it| {
        switch (it.kind) {
            .func_def => |f| {
                if (std.mem.eql(u8, f.name, "Class") and f.body != null) found_class_fn = true;
            },
            .var_decl => |decls| {
                for (decls) |d| {
                    if (std.mem.eql(u8, d.name, "$refl_Pt")) found_refl_global = true;
                }
            },
            else => {},
        }
    }
    try testing.expect(found_class_fn);
    try testing.expect(found_refl_global);
    // The user class was laid out like any other.
    try testing.expectEqual(@as(u64, 24), t.prog.?.layouts.?.get("Pt").?.size);
}

test "no reflection tables without Class/ClassRep use" {
    var t = try TestRun.init(
        \\class Pt { I64 x, y; };
        \\Pt p;
        \\p.x = 1;
        \\
    , .{ .inject_core = true });
    defer t.deinit();
    try t.expectClean();
    for (t.prog.?.items) |it| {
        switch (it.kind) {
            .func_def => |f| try testing.expect(!(std.mem.eql(u8, f.name, "Class") and f.body != null)),
            else => {},
        }
    }
}
