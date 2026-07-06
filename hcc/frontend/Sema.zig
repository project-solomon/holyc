//! Semantic analysis for HolyC: name resolution, type inference, and validity
//! checks over the parsed Program.
//!
//! HolyC is weakly typed and C-like. The default integer is I64, pointers and
//! integers convert freely, and comparison and logical results are I64. The
//! analyzer is permissive about scalar conversions and focuses on catching
//! genuine mistakes:
//!
//!   - use of undeclared variables, unknown types, and unknown fields,
//!   - redeclaration of variables, parameters, fields, functions, and types,
//!   - break/case/default used out of context,
//!   - goto to a label that does not exist in the function,
//!   - return that disagrees with the function's return type,
//!   - non-scalar conditions, indexing non-pointers, member access on
//!     non-aggregates, assigning to non-lvalues, and & of non-lvalues.
//!
//! Analysis does not stop at the first error: all errors are collected into
//! the shared diagnostics, each carrying a source position, and
//! error.CompileFailed is returned at the end iff any error was recorded. It
//! annotates each Expr.ty in place. Layout is a separate pass (layout.zig);
//! sema does not run it.

const std = @import("std");
const source = @import("source.zig");
const diag = @import("diag.zig");
const ast = @import("ast.zig");
const layout = @import("layout.zig");

const Oom = error{OutOfMemory};

/// Resolves names and type-checks prog, annotating each Expr.ty in place.
/// Every error found is recorded as a .sema diagnostic; warnings (sorted by
/// position, so output is deterministic) never fail the compilation. It is
/// the single public entry point for the sema pass.
pub fn check(arena: std.mem.Allocator, diags: *diag.Diagnostics, prog: *ast.Program) diag.Error!void {
    var a = Analyzer{ .arena = arena, .diags = diags };
    try a.run(prog);
    std.sort.insertion(WarnItem, a.warnings.items, {}, warnLess);
    for (a.warnings.items) |w| {
        try diags.warn(.sema, w.file, w.pos, "{s}", .{w.message});
    }
    if (a.err_count > 0) return error.CompileFailed;
}

// ---- static types the analyzer hands out ----

const prim_i64: ast.Type = .{ .prim = .I64 };
const prim_u64: ast.Type = .{ .prim = .U64 };
const prim_f64: ast.Type = .{ .prim = .F64 };
const prim_u8: ast.Type = .{ .prim = .U8 };
const u8_ptr: ast.Type = .{ .ptr = &prim_u8 };
const u8_ptr_ptr: ast.Type = .{ .ptr = &u8_ptr };
const i64_ptr: ast.Type = .{ .ptr = &prim_i64 };
const ktask_named: ast.Type = .{ .named = "CTask" };
const ktask_ptr: ast.Type = .{ .ptr = &ktask_named };

// ---- analyzer state ----

/// One class/union field, flattened for lookup, keeping its source position
/// so type-reference errors can point at it.
const FieldEntry = struct {
    name: []const u8,
    ty: ast.Type,
    pos: source.Pos,
};

/// A class or union definition, flattened for field lookup.
const TypeDef = struct {
    fields: []const FieldEntry,
    base: []const u8, // "" if none
    base_pos: source.Pos, // position of the definition, for base-class errors
    file: u32, // span.file the type was defined in, for file-scoped visibility
    is_public: bool,
};

/// A function signature.
const FuncSig = struct {
    ret: ast.Type,
    params: []const ast.Type, // declared parameter types, for &Func function-pointer types
    has_default: []const bool, // per-parameter: whether it has a default value (any position)
    required: usize, // parameters that must be supplied (those without a default)
    total: usize, // total declared parameter count
    varargs: bool,
    defined: bool, // whether a definition (not just a prototype) has been seen
    file: u32, // span.file the function was first declared in
    is_public: bool, // whether any declaration was marked public
};

/// One local variable tracked for the unused-variable warning.
const VarUse = struct {
    pos: source.Pos,
    file: u32,
    used: bool = false,
};

/// A warning collected during the pass, appended to the diagnostics sorted by
/// position once analysis finishes.
const WarnItem = struct {
    file: u32,
    pos: source.Pos,
    message: []const u8,
};

fn warnLess(_: void, x: WarnItem, y: WarnItem) bool {
    if (x.pos.line != y.pos.line) return x.pos.line < y.pos.line;
    return x.pos.col < y.pos.col;
}

const Scope = std.StringArrayHashMapUnmanaged(ast.Type);
const VarUseMap = std.StringArrayHashMapUnmanaged(VarUse);
const LabelSet = std.StringArrayHashMapUnmanaged(void);

/// Runs semantic analysis; check is its single public entry point. An
/// analyzer is single-use.
const Analyzer = struct {
    arena: std.mem.Allocator,
    diags: *diag.Diagnostics,
    err_count: usize = 0,
    warnings: std.ArrayList(WarnItem) = .empty,
    types: std.StringArrayHashMapUnmanaged(TypeDef) = .empty,
    funcs: std.StringArrayHashMapUnmanaged(FuncSig) = .empty,
    /// Lexical scopes; scopes.items[0] is global.
    scopes: std.ArrayList(Scope) = .empty,
    /// Usage tracking, parallel to scopes (locals only).
    var_uses: std.ArrayList(VarUseMap) = .empty,
    /// Defining file of each global, for visibility.
    global_files: std.StringArrayHashMapUnmanaged(u32) = .empty,
    /// Whether each global was declared public.
    global_is_public: std.StringArrayHashMapUnmanaged(bool) = .empty,
    /// Return type of the function being checked.
    cur_ret: ?ast.Type = null,
    /// Whether a function is currently being checked.
    in_function: bool = false,
    loop_depth: usize = 0,
    switch_depth: usize = 0,
    /// The stack of label sets: labels declared directly in the current block
    /// and each enclosing block. A goto is valid iff its target is in one of
    /// these.
    label_scopes: std.ArrayList(LabelSet) = .empty,
    /// The program's source-file table, for privacy diagnostics.
    files: []const source.FileInfo = &.{},
    /// File of the top-level item being checked (type-ref site).
    cur_file: u32 = 0,
    /// Whether the current item is compiler-generated.
    in_generated: bool = false,

    fn run(a: *Analyzer, prog: *ast.Program) Oom!void {
        a.files = prog.files;
        try a.scopes.append(a.arena, .empty); // global scope
        try a.var_uses.append(a.arena, .empty); // (globals are never tracked)
        // `envp` is the implicit environment global: U8** (a NULL-terminated
        // array of "KEY=VALUE" strings). Unlike argc/argv it has a single
        // meaning, so it is a plain global in scope everywhere. `Fs` is the
        // current task/thread context, CTask* (it holds the exception state
        // read inside catch).
        try a.scopes.items[0].put(a.arena, "envp", u8_ptr_ptr);
        try a.scopes.items[0].put(a.arena, "Fs", ktask_ptr);
        try a.collectTypes(prog);
        try a.collectFuncs(prog);
        try a.validateTypeRefs();
        try a.checkPublicSignatures(prog);
        try a.label_scopes.append(a.arena, try a.directLabels(prog.items));
        for (prog.items) |item| {
            try a.checkTopItem(item);
        }
        _ = a.label_scopes.pop();
        _ = a.scopes.pop();
        _ = a.var_uses.pop();
    }

    /// Records a semantic error, without stopping the pass.
    fn err(a: *Analyzer, file: u32, pos: source.Pos, comptime fmt: []const u8, args: anytype) Oom!void {
        a.err_count += 1;
        try a.diags.add(.@"error", .sema, file, pos, fmt, args);
    }

    /// Records a non-fatal diagnostic, appended (sorted) after the pass.
    fn warn(a: *Analyzer, file: u32, pos: source.Pos, comptime fmt: []const u8, args: anytype) Oom!void {
        try a.warnings.append(a.arena, .{
            .file = file,
            .pos = pos,
            .message = try std.fmt.allocPrint(a.arena, fmt, args),
        });
    }

    /// Marks the named local (innermost match) as referenced, so it won't be
    /// reported unused. A no-op for names that aren't tracked locals (globals,
    /// params).
    fn markUsed(a: *Analyzer, name: []const u8) void {
        var i = a.var_uses.items.len;
        while (i > 0) {
            i -= 1;
            if (a.var_uses.items[i].getPtr(name)) |vu| {
                vu.used = true;
                return;
            }
        }
    }

    // ---- collection passes ----

    fn collectTypes(a: *Analyzer, prog: *const ast.Program) Oom!void {
        for (prog.items) |item| {
            const c = switch (item.kind) {
                .class_def => |c| c,
                else => continue,
            };
            if (a.types.contains(c.name)) {
                try a.err(item.span.file, item.span.pos, "redefinition of type `{s}`", .{c.name});
                continue;
            }
            const fields = try a.arena.alloc(FieldEntry, c.fields.len);
            for (c.fields, 0..) |d, i| {
                fields[i] = .{ .name = d.name, .ty = d.ty, .pos = d.span.pos };
            }
            try a.types.put(a.arena, c.name, .{
                .fields = fields,
                .base = c.base,
                .base_pos = item.span.pos,
                .file = item.span.file,
                .is_public = c.is_public,
            });
        }
    }

    fn collectFuncs(a: *Analyzer, prog: *const ast.Program) Oom!void {
        for (prog.items) |item| {
            const f = switch (item.kind) {
                .func_def => |f| f,
                else => continue,
            };
            const has_body = f.body != null;
            if (a.funcs.getPtr(f.name)) |existing| {
                if (existing.defined and has_body) {
                    try a.err(item.span.file, item.span.pos, "redefinition of function `{s}`", .{f.name});
                    continue;
                }
                // A prototype followed by a definition (or vice versa) is
                // fine. Mark it defined if either is, and public if any
                // declaration was public.
                existing.defined = existing.defined or has_body;
                existing.is_public = existing.is_public or f.is_public;
                continue;
            }
            var required: usize = 0;
            const params = try a.arena.alloc(ast.Type, f.params.len);
            const has_default = try a.arena.alloc(bool, f.params.len);
            for (f.params, 0..) |p, i| {
                params[i] = p.ty;
                has_default[i] = p.default_value != null;
                if (p.default_value == null) required += 1;
            }
            try a.funcs.put(a.arena, f.name, .{
                .ret = f.ret,
                .params = params,
                .has_default = has_default,
                .required = required,
                .total = f.params.len,
                .varargs = f.varargs,
                .defined = has_body,
                .file = item.span.file,
                .is_public = f.is_public,
            });
        }
    }

    /// Confirms field and base-class type references exist, after all types
    /// are registered. Each reference is checked for existence and privacy
    /// against the file of the class that declares it.
    fn validateTypeRefs(a: *Analyzer) Oom!void {
        const Ref = struct { ty: ast.Type, pos: source.Pos, file: u32 };
        const BaseRef = struct { name: []const u8, pos: source.Pos, file: u32 };
        var refs: std.ArrayList(Ref) = .empty;
        var base_refs: std.ArrayList(BaseRef) = .empty;
        for (a.types.values()) |def| {
            for (def.fields) |f| {
                try refs.append(a.arena, .{ .ty = f.ty, .pos = f.pos, .file = def.file });
            }
            if (def.base.len > 0) {
                try base_refs.append(a.arena, .{ .name = def.base, .pos = def.base_pos, .file = def.file });
            }
        }
        for (refs.items) |r| {
            a.cur_file = r.file; // drives nested checks, e.g. a global in an array dimension
            try a.resolveType(r.ty, r.pos, r.file);
        }
        for (base_refs.items) |b| {
            if (!a.types.contains(b.name)) {
                try a.err(b.file, b.pos, "unknown base type `{s}`", .{b.name});
            }
        }
    }

    /// Enforces that a public function does not expose a non-public type
    /// through its return type: a caller in another file could call it but
    /// couldn't name the result.
    fn checkPublicSignatures(a: *Analyzer, prog: *const ast.Program) Oom!void {
        for (prog.items) |item| {
            // Compiler-generated functions are trusted.
            if (item.span.file == ast.generated_file) continue;
            const f = switch (item.kind) {
                .func_def => |f| f,
                else => continue,
            };
            if (!f.is_public) continue;
            if (a.firstPrivateNamed(f.ret)) |n| {
                try a.err(item.span.file, item.span.pos, "`public` function `{s}` returns non-`public` type `{s}`; declare `{s}` `public` so callers can name the result", .{ f.name, n, n });
            }
        }
    }

    /// The name of the first non-public named class/union reachable in ty by
    /// peeling pointers and arrays, or null if every named component is
    /// public (or built-in).
    fn firstPrivateNamed(a: *Analyzer, ty: ast.Type) ?[]const u8 {
        switch (ty) {
            .named => |n| {
                if (a.types.getPtr(n)) |td| {
                    if (!td.is_public) return n;
                }
                return null;
            },
            .ptr => |elem| return a.firstPrivateNamed(elem.*),
            .array => |arr| return a.firstPrivateNamed(arr.elem.*),
            else => return null,
        }
    }

    // ---- scope helpers ----

    fn pushScope(a: *Analyzer) Oom!void {
        try a.scopes.append(a.arena, .empty);
        try a.var_uses.append(a.arena, .empty);
    }

    fn popScope(a: *Analyzer) Oom!void {
        const top = &a.var_uses.items[a.var_uses.items.len - 1];
        var it = top.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.used) {
                try a.warn(entry.value_ptr.file, entry.value_ptr.pos, "unused variable `{s}`", .{entry.key_ptr.*});
            }
        }
        _ = a.var_uses.pop();
        _ = a.scopes.pop();
    }

    /// Declares a variable in the current scope, reporting a redeclaration if
    /// the name already exists at this level. is_public is meaningful only on
    /// globals; a public local is an error.
    fn declare(a: *Analyzer, name: []const u8, ty: ast.Type, pos: source.Pos, file: u32, is_public: bool) Oom!void {
        const is_global = a.scopes.items.len == 1;
        if (is_public and !is_global) {
            try a.err(file, pos, "`public` is only allowed on top-level declarations", .{});
        }
        const scope = &a.scopes.items[a.scopes.items.len - 1];
        if (scope.contains(name)) {
            try a.err(file, pos, "redeclaration of `{s}`", .{name});
            return;
        }
        try scope.put(a.arena, name, ty);
        if (is_global) {
            try a.global_files.put(a.arena, name, a.cur_file);
            try a.global_is_public.put(a.arena, name, is_public);
        }
    }

    fn lookupVar(a: *Analyzer, name: []const u8) ?ast.Type {
        var i = a.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (a.scopes.items[i].get(name)) |t| return t;
        }
        return null;
    }

    // ---- type resolution ----

    /// Confirms a type's named parts exist, reporting and continuing
    /// otherwise. ref_file is the span.file of the site that uses the type,
    /// so privacy is checked against the exact reference location.
    fn resolveType(a: *Analyzer, ty: ast.Type, pos: source.Pos, ref_file: u32) Oom!void {
        switch (ty) {
            .named => |n| {
                if (a.types.getPtr(n)) |td| {
                    try a.checkVisibility(td.is_public, td.file, ref_file, n, pos);
                } else {
                    try a.err(ref_file, pos, "unknown type `{s}`", .{n});
                }
            },
            .ptr => |elem| try a.resolveType(elem.*, pos, ref_file),
            .array => |arr| {
                try a.resolveType(arr.elem.*, pos, ref_file);
                if (arr.size) |size_expr| {
                    const dt = try a.checkExpr(size_expr);
                    if (!isInteger(dt)) {
                        try a.err(size_expr.span.file, size_expr.span.pos, "array size must be an integer", .{});
                    }
                }
            },
            else => {},
        }
    }

    /// Reports an error for any array dimension of a variable's type that is
    /// not a compile-time constant. hcc requires constant array sizes: like
    /// HolyC, it does not support variable-length arrays (`U8 buf[n]` with a
    /// runtime n). Nested dimensions (`m[3][n]`) are all checked.
    fn checkConstArraySizes(a: *Analyzer, ty: ast.Type) Oom!void {
        var t = ty;
        while (true) {
            const arr = switch (t) {
                .array => |arr| arr,
                else => return,
            };
            if (arr.size) |size_expr| {
                if (!isConstSizeExpr(size_expr)) {
                    // Fall back to the folder: anything it can evaluate is
                    // constant too.
                    if (layout.constEval(size_expr) == .err) {
                        try a.err(size_expr.span.file, size_expr.span.pos, "array size must be a constant; variable-length arrays are not supported", .{});
                    }
                }
            }
            t = arr.elem.*;
        }
    }

    // ---- top-level & statements ----

    fn checkTopItem(a: *Analyzer, item: *ast.Stmt) Oom!void {
        // Type references inside this item are checked for file-scoped
        // visibility against this item's file. A generated item is trusted.
        a.cur_file = item.span.file;
        a.in_generated = item.span.file == ast.generated_file;
        switch (item.kind) {
            .func_def => |f| try a.checkFunction(f),
            .class_def => {},
            else => try a.checkStmt(item),
        }
    }

    fn checkFunction(a: *Analyzer, f: *const ast.FuncDef) Oom!void {
        const body = f.body orelse return; // prototype: nothing to check
        try a.resolveType(f.ret, .{}, a.cur_file);
        a.cur_ret = f.ret;
        a.in_function = true;

        try a.label_scopes.append(a.arena, try a.directLabels(body));
        try a.pushScope();
        for (f.params) |p| {
            try a.resolveType(p.ty, p.span.pos, p.span.file);
            if (isVoid(p.ty)) {
                try a.err(p.span.file, p.span.pos, "parameter cannot have a void type", .{});
            }
            if (p.default_value) |dv| {
                _ = try a.checkExpr(dv);
            }
            if (p.name.len > 0) {
                try a.declare(p.name, decay(p.ty), p.span.pos, p.span.file, false);
            }
        }
        // A `...` function gets the implicit HolyC varargs locals: I64 argc
        // (the count) and I64 *argv (the raw 8-byte slots).
        if (f.varargs) {
            var pos: source.Pos = .{};
            var file: u32 = a.cur_file;
            if (f.params.len > 0) {
                pos = f.params[0].span.pos;
                file = f.params[0].span.file;
            }
            try a.declare("argc", prim_i64, pos, file, false);
            try a.declare("argv", i64_ptr, pos, file, false);
        }
        for (body) |stmt| {
            try a.checkStmt(stmt);
        }
        try a.popScope();
        _ = a.label_scopes.pop();
        a.cur_ret = null;
        a.in_function = false;
    }

    fn checkStmt(a: *Analyzer, stmt: *ast.Stmt) Oom!void {
        switch (stmt.kind) {
            .empty, .label => {},
            .no_warn => |names| {
                // `no_warn a, b;` suppresses the unused-variable warning for
                // the named locals by marking them used. An unknown name is a
                // mistake, so it is reported.
                for (names) |name| {
                    if (a.lookupVar(name) == null) {
                        try a.err(stmt.span.file, stmt.span.pos, "unknown variable `{s}` in no_warn", .{name});
                        continue;
                    }
                    a.markUsed(name);
                }
            },
            .expr => |e| {
                _ = try a.checkExpr(e);
                try a.checkImplicitPrint(e);
            },
            .asm_stmt => |k| {
                // Validate the architecture and resolve any bare-name
                // variable operands (marking them used).
                // Register/immediate/symbol operands and mnemonics are
                // checked later, by the architecture's assembler.
                if (!ast.isAsmArch(k.arch)) {
                    try a.err(k.arch_span.file, k.arch_span.pos, "unknown asm architecture `{s}` (expected amd64 or arm64)", .{k.arch});
                }
                for (k.insts) |in| {
                    for (in.operands) |op| {
                        switch (op.kind) {
                            .variable => |name| {
                                if (a.lookupVar(name) == null) {
                                    try a.err(op.span.file, op.span.pos, "unknown variable `{s}` in asm", .{name});
                                    continue;
                                }
                                a.markUsed(name);
                            },
                            else => {},
                        }
                    }
                }
            },
            .block => |stmts| try a.checkScopedBlock(stmts),
            .lock => |stmts| try a.checkScopedBlock(stmts),
            .var_decl => |decls| {
                for (decls) |*d| {
                    try a.checkDeclarator(d);
                }
            },
            .if_stmt => |k| {
                try a.checkCond(k.cond);
                try a.checkStmt(k.then);
                if (k.els) |els| try a.checkStmt(els);
            },
            .while_stmt => |k| {
                try a.checkCond(k.cond);
                a.loop_depth += 1;
                try a.checkStmt(k.body);
                a.loop_depth -= 1;
            },
            .do_while => |k| {
                a.loop_depth += 1;
                try a.checkStmt(k.body);
                a.loop_depth -= 1;
                try a.checkCond(k.cond);
            },
            .for_stmt => |k| {
                try a.pushScope();
                if (k.init) |init_stmt| try a.checkStmt(init_stmt);
                if (k.cond) |cond| try a.checkCond(cond);
                if (k.step) |step| _ = try a.checkExpr(step);
                a.loop_depth += 1;
                try a.checkStmt(k.body);
                a.loop_depth -= 1;
                try a.popScope();
            },
            .switch_stmt => |k| {
                if (k.sub and a.switch_depth == 0) {
                    try a.err(stmt.span.file, stmt.span.pos, "`sub_switch` outside of a switch", .{});
                }
                const t = try a.checkExpr(k.cond);
                if (!isInteger(t)) {
                    try a.err(k.cond.span.file, k.cond.span.pos, "switch value must be an integer", .{});
                }
                try a.validateSwitchLabels(k.body);
                a.switch_depth += 1;
                try a.checkStmt(k.body);
                a.switch_depth -= 1;
            },
            .case => |k| {
                if (a.switch_depth == 0) {
                    try a.err(stmt.span.file, stmt.span.pos, "`case` outside of a switch", .{});
                }
                if (k.lo) |lo| _ = try a.checkExpr(lo);
                if (k.hi) |hi| _ = try a.checkExpr(hi);
            },
            .default => {
                if (a.switch_depth == 0) {
                    try a.err(stmt.span.file, stmt.span.pos, "`default` outside of a switch", .{});
                }
            },
            .switch_start => {
                if (a.switch_depth == 0) {
                    try a.err(stmt.span.file, stmt.span.pos, "`start` outside of a switch", .{});
                }
            },
            .switch_end => {
                if (a.switch_depth == 0) {
                    try a.err(stmt.span.file, stmt.span.pos, "`end` outside of a switch", .{});
                }
            },
            .break_stmt => {
                if (a.loop_depth == 0 and a.switch_depth == 0) {
                    try a.err(stmt.span.file, stmt.span.pos, "`break` outside of a loop or switch", .{});
                }
            },
            .return_stmt => |v| try a.checkReturn(v, stmt.span),
            .goto_stmt => |label_name| {
                var found = false;
                for (a.label_scopes.items) |sc| {
                    if (sc.contains(label_name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try a.err(stmt.span.file, stmt.span.pos, "goto to undefined or out-of-scope label `{s}`", .{label_name});
                }
            },
            .try_stmt => |k| {
                try a.checkScopedBlock(k.body);
                try a.checkScopedBlock(k.handler);
            },
            .throw => |v| {
                // The thrown value is stored in I64 Fs->except_ch, so it must
                // be an integer (a bare `throw;` re-raises the current value).
                if (v) |value| {
                    const t = try a.checkExpr(value);
                    if (!isInteger(t)) {
                        try a.err(value.span.file, value.span.pos, "`throw` value must be an integer", .{});
                    }
                }
            },
            // HolyC functions are top-level only; a nested definition is
            // rejected outright (a nested class is silently ignored, as it
            // never reaches the type table).
            .func_def => {
                try a.err(stmt.span.file, stmt.span.pos, "nested function definitions are not supported; define the function at the top level", .{});
            },
            .class_def => {},
        }
    }

    fn checkDeclarator(a: *Analyzer, d: *const ast.Declarator) Oom!void {
        try a.resolveType(d.ty, d.span.pos, d.span.file);
        try a.checkConstArraySizes(d.ty);
        if (isVoid(d.ty)) {
            try a.err(d.span.file, d.span.pos, "variable `{s}` cannot have a void type", .{d.name});
        }
        if (d.init) |init_expr| {
            try a.checkInit(init_expr, d.ty, init_expr.span);
        }
        try a.declare(d.name, d.ty, d.span.pos, d.span.file, d.is_public);

        // A `reg <REG> x` pin only makes sense for a value that fits a
        // general-purpose register: an integer or a pointer (not a float,
        // array, or aggregate).
        const pinned = d.reg_mode == .reg and d.reg_name.len > 0;
        if (pinned) {
            if (!isInteger(d.ty) and d.ty != .ptr) {
                try a.err(d.span.file, d.span.pos, "variable `{s}` cannot be pinned to register `{s}`: only integer or pointer variables fit a general-purpose register", .{ d.name, d.reg_name });
            }
        }

        // Track non-global locals in the user's base source (file 0) for the
        // unused-variable warning; prelude/included/generated declarations are
        // skipped. A pinned variable is exempt: it is reached by its register
        // name (e.g. from asm), which the unused-variable analysis cannot see.
        if (a.scopes.items.len > 1 and d.span.file == 0 and !pinned) {
            try a.var_uses.items[a.var_uses.items.len - 1].put(a.arena, d.name, .{ .pos = d.span.pos, .file = d.span.file });
        }
    }

    /// Checks an initialiser against its declared type. A brace init list is
    /// matched element-by-element against an array's element type or a
    /// class's fields in layout order; any other expression is checked for
    /// assignability.
    fn checkInit(a: *Analyzer, init_expr: *ast.Expr, expected: ast.Type, span: source.Span) Oom!void {
        switch (init_expr.kind) {
            .designated_init => |items| {
                try a.checkDesignatedInit(init_expr, items, expected, span);
                return;
            },
            .init_list => |elems| {
                init_expr.ty = expected;
                switch (expected) {
                    .array => |arr| {
                        if (arr.size) |size_expr| {
                            switch (size_expr.kind) {
                                .int_lit => |n| {
                                    if (@as(i64, @intCast(elems.len)) > n) {
                                        try a.err(span.file, span.pos, "too many initializers ({d}) for an array of {d}", .{ elems.len, n });
                                    }
                                },
                                else => {},
                            }
                        }
                        for (elems) |it| {
                            try a.checkInit(it, arr.elem.*, span);
                        }
                    },
                    .named => |n| {
                        const fields = try a.classFieldTypes(n);
                        if (elems.len > fields.len) {
                            try a.err(span.file, span.pos, "too many initializers ({d}) for `{s}` ({d} fields)", .{ elems.len, n, fields.len });
                        }
                        for (elems, 0..) |it, i| {
                            if (i >= fields.len) break;
                            try a.checkInit(it, fields[i], span);
                        }
                    },
                    else => {
                        try a.err(span.file, span.pos, "an initializer list can only initialize an array, class, or union", .{});
                        for (elems) |it| {
                            _ = try a.checkExpr(it);
                        }
                    },
                }
            },
            else => {
                const it = try a.checkExpr(init_expr);
                try a.checkAssignable(expected, it, span);
            },
        }
    }

    /// Checks a designated initialiser {.field = value, ...} against its
    /// declared type. The target must be a class; each designator must name
    /// an existing field.
    fn checkDesignatedInit(a: *Analyzer, init_expr: *ast.Expr, items: []const ast.Expr.FieldInit, expected: ast.Type, span: source.Span) Oom!void {
        init_expr.ty = expected;
        const class_name = switch (expected) {
            .named => |n| n,
            else => {
                try a.err(span.file, span.pos, "a designated initializer can only initialize a class or union", .{});
                for (items) |f| {
                    _ = try a.checkExpr(f.value);
                }
                return;
            },
        };
        for (items) |f| {
            if (a.lookupField(class_name, f.name)) |fty| {
                try a.checkInit(f.value, fty, f.value.span);
            } else {
                try a.err(f.value.span.file, f.value.span.pos, "`{s}` has no field `{s}`", .{ class_name, f.name });
                _ = try a.checkExpr(f.value);
            }
        }
    }

    /// The function-pointer type of a named user function, for &Func.
    fn funcPtrType(a: *Analyzer, name: []const u8) Oom!?ast.Type {
        const sig = a.funcs.getPtr(name) orelse return null;
        const ret = try a.arena.create(ast.Type);
        ret.* = sig.ret;
        return .{ .func_ptr = .{ .ret = ret, .params = try a.arena.dupe(ast.Type, sig.params) } };
    }

    /// A class or union's field types in layout order: inherited (base)
    /// fields first, then the class's own.
    fn classFieldTypes(a: *Analyzer, class: []const u8) Oom![]const ast.Type {
        var out: std.ArrayList(ast.Type) = .empty;
        try a.appendClassFieldTypes(class, &out);
        return out.items;
    }

    fn appendClassFieldTypes(a: *Analyzer, class: []const u8, out: *std.ArrayList(ast.Type)) Oom!void {
        const def = a.types.getPtr(class) orelse return;
        if (def.base.len > 0) {
            try a.appendClassFieldTypes(def.base, out);
        }
        for (def.fields) |f| {
            try out.append(a.arena, f.ty);
        }
    }

    fn checkCond(a: *Analyzer, cond: *ast.Expr) Oom!void {
        const t = try a.checkExpr(cond);
        if (!isScalar(t)) {
            try a.err(cond.span.file, cond.span.pos, "condition must be a scalar value", .{});
        }
    }

    /// Enforces the placement rules for the start:/end: switch sub-labels: at
    /// most one of each, start: before every case, end: after every case.
    fn validateSwitchLabels(a: *Analyzer, body: *const ast.Stmt) Oom!void {
        const stmts = switch (body.kind) {
            .block => |stmts| stmts,
            else => return,
        };
        var first_case: ?usize = null;
        var last_case: ?usize = null;
        for (stmts, 0..) |s, i| {
            switch (s.kind) {
                .case, .default => {
                    if (first_case == null) first_case = i;
                    last_case = i;
                },
                else => {},
            }
        }
        var start_pos: ?usize = null;
        var end_pos: ?usize = null;
        for (stmts, 0..) |s, i| {
            switch (s.kind) {
                .switch_start => {
                    if (start_pos != null) {
                        try a.err(s.span.file, s.span.pos, "duplicate `start:` in a switch", .{});
                    }
                    start_pos = i;
                },
                .switch_end => {
                    if (end_pos != null) {
                        try a.err(s.span.file, s.span.pos, "duplicate `end:` in a switch", .{});
                    }
                    end_pos = i;
                },
                else => {},
            }
        }
        if (start_pos) |sp| {
            if (first_case) |fc| {
                if (sp > fc) {
                    try a.err(stmts[sp].span.file, stmts[sp].span.pos, "`start:` must come before every `case`", .{});
                }
            }
        }
        if (end_pos) |ep| {
            if (last_case) |lc| {
                if (ep < lc) {
                    try a.err(stmts[ep].span.file, stmts[ep].span.pos, "`end:` must come after every `case`", .{});
                }
            }
        }
    }

    fn checkReturn(a: *Analyzer, val: ?*ast.Expr, span: source.Span) Oom!void {
        if (!a.in_function) {
            // A top-level return: just check the value if present.
            if (val) |v| _ = try a.checkExpr(v);
            return;
        }
        const cur_ret = a.cur_ret.?;
        if (isVoid(cur_ret)) {
            if (val) |v| {
                _ = try a.checkExpr(v);
                try a.err(span.file, span.pos, "returning a value from a void (U0/I0) function", .{});
            }
            return;
        }
        // Non-void return type.
        const v = val orelse {
            try a.err(span.file, span.pos, "missing return value in non-void function", .{});
            return;
        };
        // A brace return (`return {1, 2};`) is checked against the aggregate
        // return type, like an initialiser.
        if (isInitLike(v)) {
            try a.checkInit(v, cur_ret, v.span);
        } else {
            const vt = try a.checkExpr(v);
            try a.checkAssignable(cur_ret, vt, v.span);
        }
    }

    // ---- expressions: returns the inferred type ----

    /// Infers an expression's type and records it on the node.
    fn checkExpr(a: *Analyzer, expr: *ast.Expr) Oom!ast.Type {
        const t = try a.infer(expr);
        expr.ty = t;
        return t;
    }

    fn infer(a: *Analyzer, expr: *ast.Expr) Oom!ast.Type {
        switch (expr.kind) {
            .int_lit, .char_lit => return prim_i64,
            .float_lit => return prim_f64,
            .str_lit => return u8_ptr,
            // `lastclass` default arg: a class-name string, resolved per call
            // site.
            .lastclass => return u8_ptr,
            .ident => |name| return a.checkIdent(name, expr.span),
            .unary => |k| return a.checkUnary(k.op, k.expr),
            .postfix => |k| {
                const t = try a.checkExpr(k.expr);
                if (!a.isLvalue(k.expr)) {
                    try a.err(k.expr.span.file, k.expr.span.pos, "operand of `++`/`--` must be an lvalue", .{});
                }
                return t;
            },
            .binary => |k| return a.checkBinary(k.op, k.lhs, k.rhs),
            .assign => |k| return a.checkAssign(k.target, k.value),
            .call => |k| return a.checkCall(k.callee, k.args),
            .index => |k| return a.checkIndex(k.base, k.index),
            .member => |k| return a.checkMember(k.base, k.field, k.arrow, expr.span),
            .cast => |k| {
                try a.resolveType(k.ty, k.expr.span.pos, k.expr.span.file);
                _ = try a.checkExpr(k.expr);
                return k.ty;
            },
            .sizeof => |k| {
                if (k.ty) |t| {
                    try a.resolveType(t, expr.span.pos, expr.span.file);
                } else if (k.expr) |inner| {
                    // Type-check the operand so its static type is recorded;
                    // the size is read from that type later.
                    _ = try a.checkExpr(inner);
                }
                return prim_u64;
            },
            .offset => |k| {
                try a.checkOffset(k.class, k.path, expr.span);
                return prim_i64;
            },
            .init_list => |elems| {
                for (elems) |it| {
                    _ = try a.checkExpr(it);
                }
                try a.err(expr.span.file, expr.span.pos, "an initializer list is only valid as a variable initializer", .{});
                return prim_i64;
            },
            .designated_init => |fields| {
                for (fields) |f| {
                    _ = try a.checkExpr(f.value);
                }
                try a.err(expr.span.file, expr.span.pos, "a designated initializer is only valid as a variable initializer", .{});
                return prim_i64;
            },
            .comma => |exprs| {
                var last: ast.Type = prim_i64;
                for (exprs) |it| {
                    last = try a.checkExpr(it);
                }
                return last;
            },
        }
    }

    fn checkIdent(a: *Analyzer, name: []const u8, span: source.Span) Oom!ast.Type {
        a.markUsed(name); // referencing a local (read or write) clears its unused warning
        if (a.lookupVar(name)) |t| {
            // If the name resolves to a global not shadowed by a local,
            // enforce file-scoped visibility like a function or type
            // reference.
            var shadowed = false;
            var i: usize = 1;
            while (i < a.scopes.items.len) : (i += 1) {
                if (a.scopes.items[i].contains(name)) {
                    shadowed = true;
                    break;
                }
            }
            if (!shadowed) {
                if (a.global_files.get(name)) |df| {
                    try a.checkVisibility(a.global_is_public.get(name) orelse false, df, span.file, name, span.pos);
                }
            }
            return t;
        }
        // A bare function name acts like a call in HolyC, so give it the
        // return type.
        if (a.funcs.getPtr(name)) |sig| {
            return sig.ret;
        }
        // argc/argv at the top level (no enclosing function) are the command
        // line.
        if (!a.in_function) {
            if (std.mem.eql(u8, name, "argc")) return prim_i64;
            if (std.mem.eql(u8, name, "argv")) return u8_ptr_ptr;
        }
        try a.err(span.file, span.pos, "use of undeclared identifier `{s}`", .{name});
        return prim_i64;
    }

    fn checkUnary(a: *Analyzer, op: ast.UnOp, inner: *ast.Expr) Oom!ast.Type {
        const t = try a.checkExpr(inner);
        switch (op) {
            .neg, .pos => {
                if (!isArithmetic(t)) {
                    try a.err(inner.span.file, inner.span.pos, "operand must be a number", .{});
                    return prim_i64;
                }
                if (t.isPrim(.F64)) return prim_f64;
                return prim_i64;
            },
            .not => {
                if (!isScalar(t)) {
                    try a.err(inner.span.file, inner.span.pos, "operand of `!` must be scalar", .{});
                }
                return prim_i64;
            },
            .bit_not => {
                if (!isInteger(t)) {
                    try a.err(inner.span.file, inner.span.pos, "operand of `~` must be an integer", .{});
                }
                return prim_i64;
            },
            .deref => {
                const d = decay(t);
                switch (d) {
                    .ptr => |elem| return elem.*,
                    // Dereferencing a function pointer yields the same
                    // function pointer: the function "lvalue" decays straight
                    // back, so *fp, **fp, … all stay callable. This makes the
                    // explicit-deref call form (*fp)(x) work like fp(x).
                    .func_ptr => return d,
                    else => {},
                }
                try a.err(inner.span.file, inner.span.pos, "cannot dereference a non-pointer", .{});
                return prim_i64;
            },
            .addr_of => {
                // &Func is a function pointer: a function is addressable
                // though not an lvalue. A local variable shadows a function
                // of the same name.
                switch (inner.kind) {
                    .ident => |name| {
                        if (a.lookupVar(name) == null) {
                            if (try a.funcPtrType(name)) |fp| {
                                inner.ty = fp;
                                return fp;
                            }
                        }
                    },
                    else => {},
                }
                if (!a.isLvalue(inner)) {
                    try a.err(inner.span.file, inner.span.pos, "cannot take the address of a non-lvalue", .{});
                }
                const elem = try a.arena.create(ast.Type);
                elem.* = t;
                return .{ .ptr = elem };
            },
            .pre_inc, .pre_dec => {
                if (!a.isLvalue(inner)) {
                    try a.err(inner.span.file, inner.span.pos, "operand of `++`/`--` must be an lvalue", .{});
                }
                return t;
            },
        }
    }

    fn checkBinary(a: *Analyzer, op: ast.BinOp, lhs: *ast.Expr, rhs: *ast.Expr) Oom!ast.Type {
        const lt = decay(try a.checkExpr(lhs));
        const rt = decay(try a.checkExpr(rhs));
        switch (op) {
            .add, .sub, .mul, .div, .mod => {
                if (!isScalar(lt) or !isScalar(rt)) {
                    try a.err(lhs.span.file, lhs.span.pos, "arithmetic requires numeric or pointer operands", .{});
                    return prim_i64;
                }
                // Pointer minus pointer yields an integer element count.
                if (op == .sub and isPointer(lt) and isPointer(rt)) {
                    return prim_i64;
                }
                // Pointer +/- integer is C-style scaled pointer arithmetic
                // and keeps the pointer type, so *(p + i) and (p + i)[j]
                // work; the lowerer scales the integer operand by the element
                // size.
                if ((op == .add or op == .sub) and isPointer(lt) and isInteger(rt)) {
                    return lt;
                }
                if (op == .add and isInteger(lt) and isPointer(rt)) {
                    return rt;
                }
                return arithResult(lt, rt);
            },
            .eq, .ne, .lt, .gt, .le, .ge, .log_and, .log_or, .log_xor => {
                if (!isScalar(lt) or !isScalar(rt)) {
                    try a.err(lhs.span.file, lhs.span.pos, "comparison requires scalar operands", .{});
                }
                return prim_i64;
            },
            .pow => {
                // HolyC `` ` `` exponentiation: any scalar base/exponent, F64
                // result.
                if (!isScalar(lt) or !isScalar(rt)) {
                    try a.err(lhs.span.file, lhs.span.pos, "`` ` `` (exponentiation) requires numeric operands", .{});
                }
                return prim_f64;
            },
            .bit_and, .bit_or, .bit_xor, .shl, .shr => {
                if (!isInteger(lt) or !isInteger(rt)) {
                    try a.err(lhs.span.file, lhs.span.pos, "bitwise/shift operators require integer operands", .{});
                }
                return prim_i64;
            },
        }
    }

    fn checkAssign(a: *Analyzer, target: *ast.Expr, value: *ast.Expr) Oom!ast.Type {
        const tt = try a.checkExpr(target);
        const vt = try a.checkExpr(value);
        if (!a.isLvalue(target)) {
            try a.err(target.span.file, target.span.pos, "left-hand side of assignment is not an lvalue", .{});
        }
        try a.checkAssignable(tt, vt, value.span);
        return tt;
    }

    /// Enforces file-scoped visibility. A non-public symbol may be referenced
    /// only from its own file or directory; a public symbol is visible
    /// everywhere; generated-code references are allowed.
    fn checkVisibility(a: *Analyzer, is_public: bool, def_file: u32, ref_file: u32, name: []const u8, pos: source.Pos) Oom!void {
        if (is_public or def_file == ref_file or a.in_generated or ref_file == ast.generated_file) return;
        // Two files in the same directory share visibility of non-public
        // symbols (see source.FileInfo).
        if (a.fileAt(def_file)) |df| {
            if (a.fileAt(ref_file)) |rf| {
                if (df.eqlDir(rf)) return;
            }
            try a.err(ref_file, pos, "`{s}` is not `public`; it is private to the file `{f}`", .{ name, df });
            return;
        }
        try a.err(ref_file, pos, "`{s}` is not `public`; it is private to the file `another file`", .{name});
    }

    fn fileAt(a: *Analyzer, i: u32) ?source.FileInfo {
        if (i < a.files.len) return a.files[i];
        return null;
    }

    fn checkCall(a: *Analyzer, callee: *ast.Expr, args: []const ?*ast.Expr) Oom!ast.Type {
        const argc = args.len;
        // A null entry is a skipped argument (`F(,x)`): it has no expression
        // to check.
        const arg_types = try a.arena.alloc(?ast.Type, argc);
        for (args, 0..) |arg, i| {
            arg_types[i] = if (arg) |e| try a.checkExpr(e) else null;
        }
        // A direct call to a named function or builtin, unless a local
        // variable of the same name shadows it.
        direct: {
            const name = switch (callee.kind) {
                .ident => |name| name,
                else => break :direct,
            };
            if (a.lookupVar(name) != null) break :direct;
            const sig = a.funcs.getPtr(name) orelse {
                try a.err(callee.span.file, callee.span.pos, "call to undeclared function `{s}`", .{name});
                return prim_i64;
            };
            try a.checkVisibility(sig.is_public, sig.file, callee.span.file, name, callee.span.pos);
            if (!sig.varargs and argc > sig.total) {
                try a.err(callee.span.file, callee.span.pos, "function `{s}` expects at most {d} argument(s), got {d}", .{ name, sig.total, argc });
            }
            // Per-position: a supplied argument is type-checked against its
            // parameter; a skipped (`F(,x)`) or omitted-trailing position must
            // have a default. This makes defaults usable in any position
            // (HolyC), not just trailing ones.
            var i: usize = 0;
            while (i < sig.total) : (i += 1) {
                const supplied = i < argc and args[i] != null;
                if (supplied) {
                    try a.checkArg(sig.params[i], arg_types[i].?, i, args[i].?.span);
                    continue;
                }
                if (i >= sig.has_default.len or !sig.has_default[i]) {
                    try a.err(callee.span.file, callee.span.pos, "function `{s}` is missing a value for argument {d}, which has no default", .{ name, i + 1 });
                }
            }
            // Check a Print-family format string against its arguments.
            if (sig.varargs) {
                if (std.mem.eql(u8, name, "Print") and argc >= 1) {
                    try a.checkPrintFormat(args[0], args[1..]);
                } else if (std.mem.eql(u8, name, "FPrint") and argc >= 2) {
                    try a.checkPrintFormat(args[1], args[2..]);
                }
            }
            return sig.ret;
        }
        // Otherwise the callee is a value that must be a function pointer.
        // Function pointers have no default arguments, so a skipped slot is
        // an error.
        switch (decay(try a.checkExpr(callee))) {
            .func_ptr => |fp| {
                if (argc != fp.params.len) {
                    try a.err(callee.span.file, callee.span.pos, "function pointer expects {d} argument(s), got {d}", .{ fp.params.len, argc });
                }
                for (fp.params, 0..) |pty, i| {
                    if (i >= argc) break;
                    if (args[i] == null) {
                        try a.err(callee.span.file, callee.span.pos, "a skipped argument is only allowed when calling a named function with a default for that parameter", .{});
                        continue;
                    }
                    try a.checkArg(pty, arg_types[i].?, i, args[i].?.span);
                }
                return fp.ret.*;
            },
            else => {},
        }
        try a.err(callee.span.file, callee.span.pos, "called value is not a function", .{});
        return prim_i64;
    }

    /// Applies the format check to HolyC's implicit-print statements, which
    /// lower to a Print call: a bare string literal (`"...";`) and a comma
    /// expression whose elements are the print arguments (`"x=%d\n", x;`).
    fn checkImplicitPrint(a: *Analyzer, e: *ast.Expr) Oom!void {
        switch (e.kind) {
            .str_lit => try a.checkPrintFormat(e, &.{}),
            .comma => |exprs| {
                if (exprs.len > 0) {
                    const rest = try a.arena.alloc(?*ast.Expr, exprs.len - 1);
                    for (exprs[1..], 0..) |it, i| rest[i] = it;
                    try a.checkPrintFormat(exprs[0], rest);
                }
            },
            else => {},
        }
    }

    /// Verifies a Print-style format against its arguments. It runs only when
    /// the format is a string literal in the user's base source (a runtime
    /// format can't be analyzed, and prelude/included calls aren't the user's
    /// concern), and warns on argument-count mismatches, argument-type
    /// mismatches, and unknown conversions.
    fn checkPrintFormat(a: *Analyzer, fmt_expr: ?*ast.Expr, args: []const ?*ast.Expr) Oom!void {
        const fe = fmt_expr orelse return;
        if (fe.span.file != 0) return;
        const lit = switch (fe.kind) {
            .str_lit => |s| s,
            else => return,
        };
        const scanned = try scanPrintFormat(a.arena, lit);
        for (scanned.unknowns) |c| {
            if (c == 0) {
                try a.warn(fe.span.file, fe.span.pos, "incomplete conversion: `%` at end of format string", .{});
            } else if (c >= 0x20 and c < 0x7f) {
                try a.warn(fe.span.file, fe.span.pos, "unknown print conversion `%{c}` (use `%%` for a literal percent)", .{c});
            } else {
                try a.warn(fe.span.file, fe.span.pos, "unknown print conversion `%\\x{x:0>2}` (use `%%` for a literal percent)", .{c});
            }
        }
        if (scanned.specs.len != args.len) {
            try a.warn(fe.span.file, fe.span.pos, "format has {d} conversion(s) but {d} argument(s) given", .{ scanned.specs.len, args.len });
        }
        const n = @min(scanned.specs.len, args.len);
        for (0..n) |i| {
            const arg = args[i] orelse continue;
            try a.checkPrintArgType(scanned.specs[i], arg.ty, arg.span);
        }
    }

    /// Warns when an argument's type clearly disagrees with its conversion.
    /// It is lenient because HolyC converts freely, so it flags only definite
    /// mismatches: a float spec with a non-float, an integer spec with a
    /// float, and `%s` with a non-pointer.
    fn checkPrintArgType(a: *Analyzer, conv: u8, arg_ty: ?ast.Type, span: source.Span) Oom!void {
        const raw = arg_ty orelse return;
        const t = decay(raw);
        switch (conv) {
            'f', 'e', 'E', 'g', 'G' => {
                if (!t.isPrim(.F64)) {
                    try a.warn(span.file, span.pos, "%{c} expects a floating-point argument", .{conv});
                }
            },
            's' => {
                if (!isPointer(t)) {
                    try a.warn(span.file, span.pos, "%s expects a string (pointer) argument", .{});
                }
            },
            'c', 'd', 'u', 'x', 'X' => {
                if (t.isPrim(.F64)) {
                    try a.warn(span.file, span.pos, "%{c} expects an integer argument, got a floating-point value", .{conv});
                }
            },
            else => {},
        }
    }

    /// Checks that argument idx (0-based) is type-compatible with its
    /// parameter. Only genuine aggregate mismatches are flagged; scalar and
    /// pointer arguments stay permissive.
    fn checkArg(a: *Analyzer, param: ast.Type, arg: ast.Type, idx: usize, span: source.Span) Oom!void {
        const p = decay(param);
        const ar = decay(arg);
        if (typesCompatible(p, ar)) return;
        const n = idx + 1;
        const pn = namedName(p);
        const an = namedName(ar);
        if (pn != null and an != null) {
            try a.err(span.file, span.pos, "argument {d}: cannot pass `{s}` to a parameter of type `{s}`", .{ n, an.?, pn.? });
        } else if (pn) |p_name| {
            try a.err(span.file, span.pos, "argument {d}: cannot pass a scalar to the class parameter `{s}`", .{ n, p_name });
        } else if (an) |a_name| {
            try a.err(span.file, span.pos, "argument {d}: cannot pass class type `{s}` to a scalar parameter", .{ n, a_name });
        }
    }

    fn checkIndex(a: *Analyzer, base: *ast.Expr, index: *ast.Expr) Oom!ast.Type {
        const raw_base = try a.checkExpr(base);
        const bt = decay(raw_base);
        const it = try a.checkExpr(index);
        if (!isInteger(it)) {
            try a.err(index.span.file, index.span.pos, "array index must be an integer", .{});
        }
        try a.checkIndexBounds(raw_base, index);
        switch (bt) {
            .ptr => |elem| return elem.*,
            else => {},
        }
        try a.err(base.span.file, base.span.pos, "cannot index a non-pointer value", .{});
        return prim_i64;
    }

    /// Warns when a constant index is out of bounds for a fixed-size array.
    /// It applies only when base_ty is a genuine array (not a decayed
    /// pointer) with a constant dimension and the index folds to a constant.
    /// It never false-warns on dynamic indices, pointers, or sizes it cannot
    /// evaluate before layout.
    fn checkIndexBounds(a: *Analyzer, base_ty: ast.Type, index: *ast.Expr) Oom!void {
        if (index.span.file != 0) return;
        const arr = switch (base_ty) {
            .array => |arr| arr,
            else => return,
        };
        const size_expr = arr.size orelse return;
        const size = switch (layout.constEval(size_expr)) {
            .value => |v| v,
            .err => return, // non-constant or sizeof-based dimension
        };
        if (size < 0) return;
        const idx = switch (layout.constEval(index)) {
            .value => |v| v,
            .err => return, // dynamic index
        };
        if (idx < 0 or idx >= size) {
            try a.warn(index.span.file, index.span.pos, "array index {d} is out of bounds for array of size {d}", .{ idx, size });
        }
    }

    fn checkMember(a: *Analyzer, base: *ast.Expr, field: []const u8, arrow: bool, span: source.Span) Oom!ast.Type {
        const bt = try a.checkExpr(base);
        var class_name: ?[]const u8 = null;
        if (arrow) {
            var ok = false;
            switch (decay(bt)) {
                .ptr => |elem| switch (elem.*) {
                    .named => |n| {
                        class_name = n;
                        ok = true;
                    },
                    else => {},
                },
                else => {},
            }
            if (!ok) {
                try a.err(span.file, span.pos, "`->` requires a pointer to a class or union", .{});
            }
        } else {
            switch (bt) {
                .named => |n| class_name = n,
                .ptr => try a.err(span.file, span.pos, "use `->` to access a member through a pointer", .{}),
                else => try a.err(span.file, span.pos, "`.` requires a class or union value", .{}),
            }
        }
        const cn = class_name orelse return prim_i64;
        if (a.lookupField(cn, field)) |ty| {
            return ty;
        }
        try a.err(span.file, span.pos, "no field `{s}` on type `{s}`", .{ field, cn });
        return prim_i64;
    }

    /// Finds a field by name in a class or union, searching anonymous
    /// embedded unions and base classes.
    fn lookupField(a: *Analyzer, class: []const u8, field: []const u8) ?ast.Type {
        const def = a.types.getPtr(class) orelse return null;
        for (def.fields) |f| {
            if (std.mem.eql(u8, f.name, field)) return f.ty;
        }
        // A member promoted from an anonymous embedded union.
        for (def.fields) |f| {
            if (ast.isAnonField(f.name)) {
                switch (f.ty) {
                    .named => |inner| {
                        if (a.lookupField(inner, field)) |t| return t;
                    },
                    else => {},
                }
            }
        }
        // A field inherited from a base class.
        if (def.base.len > 0) {
            return a.lookupField(def.base, field);
        }
        return null;
    }

    /// Validates an offset(Class.field...) operand: the class must exist and
    /// each member along the path must resolve, descending into nested
    /// classes.
    fn checkOffset(a: *Analyzer, class: []const u8, path: []const []const u8, span: source.Span) Oom!void {
        if (!a.types.contains(class)) {
            try a.err(span.file, span.pos, "`{s}` is not a known class or union", .{class});
            return;
        }
        var current = class;
        for (path, 0..) |field, i| {
            const ty = a.lookupField(current, field) orelse {
                try a.err(span.file, span.pos, "no field `{s}` on type `{s}`", .{ field, current });
                return;
            };
            if (i + 1 < path.len) {
                switch (ty) {
                    .named => |n| current = n,
                    else => {
                        try a.err(span.file, span.pos, "`{s}.{s}` is not a class, so `offset` cannot descend into it", .{ current, field });
                        return;
                    },
                }
            }
        }
    }

    fn isLvalue(a: *Analyzer, expr: *const ast.Expr) bool {
        switch (expr.kind) {
            .ident => |name| return a.lookupVar(name) != null,
            // p->x is always an lvalue. a.x is one only if a is.
            .member => |k| return k.arrow or a.isLvalue(k.base),
            .index => return true,
            .unary => |k| return k.op == .deref,
            else => return false,
        }
    }

    /// Reports an error if a value of type `from` may not be assigned to a
    /// slot of type `to`. Permissive for scalars; strict only about aggregate
    /// mismatches.
    fn checkAssignable(a: *Analyzer, to: ast.Type, from: ast.Type, span: source.Span) Oom!void {
        const td = decay(to);
        const fd = decay(from);
        if (typesCompatible(td, fd)) return;
        const tn = namedName(td);
        const fn_ = namedName(fd);
        if (tn != null and fn_ != null) {
            try a.err(span.file, span.pos, "cannot assign `{s}` to `{s}`", .{ fn_.?, tn.? });
        } else if (tn) |t_name| {
            try a.err(span.file, span.pos, "cannot assign a scalar to class type `{s}`", .{t_name});
        } else if (fn_) |f_name| {
            try a.err(span.file, span.pos, "cannot assign class type `{s}` to a scalar", .{f_name});
        }
    }

    /// Type-checks a brace-delimited statement list in its own label and
    /// variable scope: labels declared directly in stmts become goto targets
    /// for its duration, and locals declared inside do not leak out.
    fn checkScopedBlock(a: *Analyzer, stmts: []const *ast.Stmt) Oom!void {
        try a.label_scopes.append(a.arena, try a.directLabels(stmts));
        try a.pushScope();
        for (stmts) |s| {
            try a.checkStmt(s);
        }
        try a.popScope();
        _ = a.label_scopes.pop();
    }

    /// The set of labels declared directly in a statement list (one level
    /// deep, not inside nested blocks). A goto can target these from anywhere
    /// within the block or a nested block.
    fn directLabels(a: *Analyzer, stmts: []const *ast.Stmt) Oom!LabelSet {
        var out: LabelSet = .empty;
        for (stmts) |s| {
            switch (s.kind) {
                .label => |name| try out.put(a.arena, name, {}),
                else => {},
            }
        }
        return out;
    }
};

// ---- free helpers (HolyC's weak-typing rules) ----

/// Whether t is a zero-size void type. U0 and I0 are the unsigned and signed
/// zero-width types; the sign is meaningless at zero bits, so they are
/// interchangeable.
pub fn isVoid(t: ast.Type) bool {
    return t.isPrim(.U0) or t.isPrim(.I0);
}

/// Applies array-to-pointer decay: an array type used as a value becomes a
/// pointer to its element. Every other type is returned unchanged.
pub fn decay(t: ast.Type) ast.Type {
    return switch (t) {
        .array => |arr| .{ .ptr = arr.elem },
        else => t,
    };
}

/// Whether t is a built-in integer type (I8…U64).
pub fn isInteger(t: ast.Type) bool {
    return switch (t) {
        .prim => |p| switch (p) {
            .I8, .U8, .I16, .U16, .I32, .U32, .I64, .U64 => true,
            else => false,
        },
        else => false,
    };
}

/// Whether t is a number: an integer type or F64.
pub fn isArithmetic(t: ast.Type) bool {
    return isInteger(t) or t.isPrim(.F64);
}

/// Whether t is a pointer-like type (a pointer, an array, or a function
/// pointer). Apply decay first when a value context is meant.
pub fn isPointer(t: ast.Type) bool {
    return switch (t) {
        .ptr, .array, .func_ptr => true,
        else => false,
    };
}

/// Whether t is a single-word value: a number or a pointer.
pub fn isScalar(t: ast.Type) bool {
    return isArithmetic(t) or isPointer(t);
}

/// The type of an arithmetic expression over a and b: F64 if either operand
/// is F64, otherwise I64 (HolyC widens every integer computation to I64).
pub fn arithResult(a: ast.Type, b: ast.Type) ast.Type {
    if (a.isPrim(.F64) or b.isPrim(.F64)) return prim_f64;
    return prim_i64;
}

/// Structural type equality. Named (class/union) types are nominal (equal
/// only to the same name); pointers and function pointers compare
/// component-wise; arrays compare element type and, when both sizes fold to a
/// constant, their length.
pub fn typeEqual(a: ?ast.Type, b: ?ast.Type) bool {
    const av = a orelse return b == null;
    const bv = b orelse return false;
    switch (av) {
        .prim => |ap| return bv == .prim and bv.prim == ap,
        .named => |an| return bv == .named and std.mem.eql(u8, bv.named, an),
        .ptr => |ae| return bv == .ptr and typeEqual(ae.*, bv.ptr.*),
        .array => |aa| {
            if (bv != .array) return false;
            const ba = bv.array;
            if (!typeEqual(aa.elem.*, ba.elem.*)) return false;
            // Unsized or non-constant dimensions stay permissive.
            const as_expr = aa.size orelse return true;
            const bs_expr = ba.size orelse return true;
            const ar = layout.constEval(as_expr);
            const br = layout.constEval(bs_expr);
            if (ar == .value and br == .value) return ar.value == br.value;
            return true;
        },
        .func_ptr => |af| {
            if (bv != .func_ptr) return false;
            const bf = bv.func_ptr;
            if (!typeEqual(af.ret.*, bf.ret.*)) return false;
            if (af.params.len != bf.params.len) return false;
            for (af.params, bf.params) |x, y| {
                if (!typeEqual(x, y)) return false;
            }
            return true;
        },
    }
}

/// Whether two types are assignable across each other. Aggregates are
/// nominal (a class/union matches only the same named type);
/// pointers/arrays/funcptrs compare component-wise (so `[3]` matches
/// `[1+2]`).
fn typesCompatible(a: ast.Type, b: ast.Type) bool {
    return typeEqual(decay(a), decay(b));
}

/// A named type's name, or null if t is not a named type.
fn namedName(t: ast.Type) ?[]const u8 {
    return switch (t) {
        .named => |n| n,
        else => null,
    };
}

/// Whether an expression is a brace initializer (an init list or a designated
/// initializer), which a return checks like an initialiser.
fn isInitLike(e: *const ast.Expr) bool {
    return switch (e.kind) {
        .init_list, .designated_init => true,
        else => false,
    };
}

/// Structurally reports whether e is a constant array-size expression.
/// sizeof/offset are constant even when their value can't be folded before
/// layout (so `buf[sizeof(SomeClass)]` is accepted), which a value-folder
/// alone would reject.
fn isConstSizeExpr(e: *const ast.Expr) bool {
    return switch (e.kind) {
        .int_lit, .char_lit, .sizeof, .offset => true,
        .unary => |k| isConstSizeExpr(k.expr),
        .binary => |k| isConstSizeExpr(k.lhs) and isConstSizeExpr(k.rhs),
        else => false,
    };
}

// ---- print-format scanning ----

const ScanResult = struct {
    specs: []const u8,
    unknowns: []const u8,
};

/// Parses a format string the way the runtime formatter (_VFmt) does
/// (`%[-0+ #]*[0-9]*(.[0-9]*)?conv`, no `*` width/precision). It returns the
/// argument-consuming conversions in order and any unknown conversions (0
/// marks a trailing bare `%`).
fn scanPrintFormat(arena: std.mem.Allocator, s: []const u8) Oom!ScanResult {
    var specs: std.ArrayList(u8) = .empty;
    var unknowns: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '%') {
            i += 1;
            continue;
        }
        i += 1; // past '%'
        while (i < s.len and (s[i] == '-' or s[i] == '0' or s[i] == '+' or s[i] == ' ' or s[i] == '#')) i += 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        if (i < s.len and s[i] == '.') {
            i += 1;
            while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        }
        if (i >= s.len) {
            try unknowns.append(arena, 0); // a bare '%' at the end
            break;
        }
        const conv = s[i];
        i += 1;
        switch (conv) {
            '%' => {}, // a literal percent consumes no argument
            'c', 'd', 'u', 'x', 'X', 'p', 's', 'f', 'e', 'E', 'g', 'G' => try specs.append(arena, conv),
            else => try unknowns.append(arena, conv),
        }
    }
    return .{ .specs = specs.items, .unknowns = unknowns.items };
}

test {
    _ = @import("sema_test.zig");
}
