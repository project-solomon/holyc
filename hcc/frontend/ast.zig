//! The HolyC AST: types, expressions, statements, declarations, inline asm,
//! and the whole-program node. Nodes are arena-allocated and linked by pointer;
//! each node's shape is a `union(enum)`.

const std = @import("std");
const source = @import("source.zig");

/// span.file sentinel for compiler-synthesized declarations that bypass
/// file-privacy checks. No real source file has this id.
pub const generated_file: u32 = std.math.maxInt(u32);

/// Whether a field name is the placeholder for an anonymous embedded
/// union/struct, whose members are promoted into the enclosing class.
pub fn isAnonField(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "$anon");
}

// ---- types ----

/// A HolyC type. `prim` for scalar built-ins; composite variants hold
/// arena-allocated children. An expression whose `ty` is null is not yet typed.
pub const Type = union(enum) {
    prim: Prim,
    /// A class or union type referenced by name.
    named: []const u8,
    /// `T *`.
    ptr: *const Type,
    /// `T[n]`; size is null for an unsized array (`T[]`).
    array: Array,
    /// A function pointer `ret (*)(params...)`: an 8-byte scalar; the signature
    /// drives call type-checking.
    func_ptr: FuncPtr,

    pub const Array = struct {
        elem: *const Type,
        size: ?*Expr,
    };

    pub const FuncPtr = struct {
        ret: *const Type,
        params: []const Type,
    };

    /// A built-in scalar. HolyC's default integer is I64; there is no F32. Tag
    /// names are the source spellings.
    pub const Prim = enum {
        U0, // void
        I0, // void (signed sibling of U0; zero-size, behaves identically)
        I8,
        U8,
        I16,
        U16,
        I32,
        U32,
        I64,
        U64,
        F64,

        pub fn fromString(s: []const u8) ?Prim {
            return std.meta.stringToEnum(Prim, s);
        }

        pub fn spelling(p: Prim) []const u8 {
            return @tagName(p);
        }
    };

    pub fn isAggregate(ty: Type) bool {
        return switch (ty) {
            .named, .array => true,
            else => false,
        };
    }

    /// Test against a specific scalar, e.g. `t.isPrim(.F64)`.
    pub fn isPrim(ty: Type, p: Prim) bool {
        return ty == .prim and ty.prim == p;
    }

    /// Renders a type for diagnostics; a null type renders as "?".
    pub fn render(ty: ?Type, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const t = ty orelse return w.writeAll("?");
        switch (t) {
            .prim => |p| try w.writeAll(p.spelling()),
            .named => |n| try w.writeAll(n),
            .ptr => |elem| {
                try render(elem.*, w);
                try w.writeAll("*");
            },
            .array => |a| {
                try render(a.elem.*, w);
                try w.writeAll(if (a.size == null) "[]" else "[...]");
            },
            .func_ptr => |f| {
                try render(f.ret.*, w);
                try w.writeAll(" (*)(");
                for (f.params, 0..) |p, i| {
                    if (i > 0) try w.writeAll(", ");
                    try render(p, w);
                }
                try w.writeAll(")");
            },
        }
    }

    /// `render` into an arena-allocated string, for diagnostics.
    pub fn string(ty: ?Type, arena: std.mem.Allocator) error{OutOfMemory}![]const u8 {
        var alloc_writer = std.Io.Writer.Allocating.init(arena);
        render(ty, &alloc_writer.writer) catch return error.OutOfMemory;
        return alloc_writer.written();
    }
};

// ---- operators ----

/// A prefix unary operator.
pub const UnOp = enum {
    neg, // -x
    pos, // +x
    not, // !x
    bit_not, // ~x
    deref, // *x
    addr_of, // &x
    pre_inc, // ++x
    pre_dec, // --x

    pub fn spelling(op: UnOp) []const u8 {
        return switch (op) {
            .neg => "-",
            .pos => "+",
            .not => "!",
            .bit_not => "~",
            .deref => "*",
            .addr_of => "&",
            .pre_inc => "++",
            .pre_dec => "--",
        };
    }
};

/// A postfix unary operator.
pub const PostOp = enum {
    inc, // x++
    dec, // x--

    pub fn spelling(op: PostOp) []const u8 {
        return switch (op) {
            .inc => "++",
            .dec => "--",
        };
    }
};

/// A binary operator.
pub const BinOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    eq,
    ne,
    lt,
    gt,
    le,
    ge,
    log_and, // &&
    log_or, // ||
    log_xor, // ^^ (logical XOR; non-short-circuiting, result 0/1)
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
    pow, // ` (HolyC backtick exponentiation; result F64)

    pub fn spelling(op: BinOp) []const u8 {
        return switch (op) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .mod => "%",
            .eq => "==",
            .ne => "!=",
            .lt => "<",
            .gt => ">",
            .le => "<=",
            .ge => ">=",
            .log_and => "&&",
            .log_or => "||",
            .log_xor => "^^",
            .bit_and => "&",
            .bit_or => "|",
            .bit_xor => "^",
            .shl => "<<",
            .shr => ">>",
            .pow => "`",
        };
    }
};

/// A simple or compound assignment operator.
pub const AssignOp = enum {
    assign, // =
    add, // +=
    sub, // -=
    mul, // *=
    div, // /=
    mod, // %=
    bit_and, // &=
    bit_or, // |=
    bit_xor, // ^=
    shl, // <<=
    shr, // >>=

    pub fn spelling(op: AssignOp) []const u8 {
        return switch (op) {
            .assign => "=",
            .add => "+=",
            .sub => "-=",
            .mul => "*=",
            .div => "/=",
            .mod => "%=",
            .bit_and => "&=",
            .bit_or => "|=",
            .bit_xor => "^=",
            .shl => "<<=",
            .shr => ">>=",
        };
    }
};

// ---- expressions ----

/// An expression node: its shape, source span, and inferred type (null until
/// sema runs).
pub const Expr = struct {
    kind: Kind,
    span: source.Span,
    ty: ?Type = null,

    pub const Kind = union(enum) {
        /// An integer literal.
        int_lit: i64,
        /// A floating-point literal (HolyC only has F64).
        float_lit: f64,
        /// A string literal, escapes resolved.
        str_lit: []const u8,
        /// A character constant: HolyC packs up to 8 chars little-endian into
        /// an I64, e.g. 'AB' == 0x4241.
        char_lit: i64,
        /// An identifier (not a keyword).
        ident: []const u8,
        /// A prefix unary operation, e.g. -x or *p.
        unary: struct { op: UnOp, expr: *Expr },
        /// A postfix unary operation, e.g. x++.
        postfix: struct { op: PostOp, expr: *Expr },
        /// A binary operation, e.g. a + b.
        binary: struct { op: BinOp, lhs: *Expr, rhs: *Expr },
        /// A simple or compound assignment, e.g. x = y or x += y.
        assign: struct { op: AssignOp, target: *Expr, value: *Expr },
        /// A function call, callee(args...). A null arg is a skipped default
        /// argument (`F(, 2)`).
        call: struct { callee: *Expr, args: []const ?*Expr },
        /// An array/pointer subscript, base[index].
        index: struct { base: *Expr, index: *Expr },
        /// A field access, base.field or base->field.
        member: struct { base: *Expr, field: []const u8, arrow: bool },
        /// A type cast, (Ty)expr, or HolyC's postfix cast `expr(Ty)`.
        cast: struct { ty: Type, expr: *Expr },
        /// sizeof(Type) or sizeof(expr); exactly one is set. Computed at
        /// compile time (for an expr, from its inferred type).
        sizeof: struct { ty: ?Type, expr: ?*Expr },
        /// offset(ClassName.field[.field...]): the compile-time byte offset of
        /// a (possibly nested) member, HolyC's offsetof.
        offset: struct { class: []const u8, path: []const []const u8 },
        /// A brace-enclosed aggregate initializer, e.g. {1, 2, 3}. Valid only
        /// as a variable or field initializer.
        init_list: []const *Expr,
        /// A brace-enclosed designated initializer, e.g. {.x = 1, .y = 2}.
        /// Fields may appear in any order; omitted ones default to zero.
        /// Valid only for class types.
        designated_init: []const FieldInit,
        /// A comma-separated sequence. At statement level this is also HolyC's
        /// implicit print: `"x = %d\n", x` is a comma of [str_lit, ident].
        comma: []const *Expr,
        /// HolyC's `lastclass`, a parameter default (`U8 *cn = lastclass`). At
        /// each call site it stands for the class-name string of the preceding
        /// argument; its static type is U8*. Outside a default it lowers to "".
        lastclass,
    };

    /// One `.name = value` entry of a designated initializer.
    pub const FieldInit = struct {
        name: []const u8,
        value: *Expr,
    };

    /// Whether this expression (or a child) calls a function named in names.
    pub fn calls(e: ?*const Expr, names: []const []const u8) bool {
        const expr = e orelse return false;
        switch (expr.kind) {
            .call => |c| {
                switch (c.callee.kind) {
                    .ident => |name| if (containsName(names, name)) return true,
                    else => {},
                }
                if (calls(c.callee, names)) return true;
                for (c.args) |arg| {
                    if (calls(arg, names)) return true;
                }
                return false;
            },
            .unary => |u| return calls(u.expr, names),
            .postfix => |p| return calls(p.expr, names),
            .cast => |c| return calls(c.expr, names),
            .binary => |b| return calls(b.lhs, names) or calls(b.rhs, names),
            .assign => |a| return calls(a.target, names) or calls(a.value, names),
            .index => |i| return calls(i.base, names) or calls(i.index, names),
            .member => |m| return calls(m.base, names),
            .init_list, .comma => |items| {
                for (items) |item| {
                    if (calls(item, names)) return true;
                }
                return false;
            },
            .designated_init => |fields| {
                for (fields) |f| {
                    if (calls(f.value, names)) return true;
                }
                return false;
            },
            // Literals, ident, sizeof, offset: nothing to recurse into (a
            // sizeof's expr operand is not walked).
            else => return false,
        }
    }

    /// Whether this expression (or a child) references one of names as a bare
    /// identifier.
    pub fn usesIdent(e: ?*const Expr, names: []const []const u8) bool {
        const expr = e orelse return false;
        switch (expr.kind) {
            .ident => |name| return containsName(names, name),
            .call => |c| {
                if (usesIdent(c.callee, names)) return true;
                for (c.args) |arg| {
                    if (usesIdent(arg, names)) return true;
                }
                return false;
            },
            .unary => |u| return usesIdent(u.expr, names),
            .postfix => |p| return usesIdent(p.expr, names),
            .cast => |c| return usesIdent(c.expr, names),
            .binary => |b| return usesIdent(b.lhs, names) or usesIdent(b.rhs, names),
            .assign => |a| return usesIdent(a.target, names) or usesIdent(a.value, names),
            .index => |i| return usesIdent(i.base, names) or usesIdent(i.index, names),
            .member => |m| return usesIdent(m.base, names),
            .init_list, .comma => |items| {
                for (items) |item| {
                    if (usesIdent(item, names)) return true;
                }
                return false;
            },
            .designated_init => |fields| {
                for (fields) |f| {
                    if (usesIdent(f.value, names)) return true;
                }
                return false;
            },
            else => return false,
        }
    }
};

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

// ---- declarations ----

/// A local variable's register storage class.
pub const RegMode = enum {
    /// Default: the backend chooses storage.
    none,
    /// `reg`: keep the variable register-resident. When reg_name is set, pin it
    /// to that physical register for its whole lifetime.
    reg,
    /// `noreg`: force the variable onto the stack.
    noreg,
};

/// One `key value` member-metadata entry on a class field. key is an
/// identifier (e.g. `format`); value is a string or integer literal.
pub const FieldMeta = struct {
    key: []const u8,
    value: union(enum) {
        str: []const u8,
        int: i64,
    },
};

/// A single declared name with its resolved type and optional initialiser.
/// Used for variables and class fields.
pub const Declarator = struct {
    name: []const u8,
    ty: Type,
    init: ?*Expr = null,
    span: source.Span,
    /// `public`: a top-level global is visible from any file, otherwise private
    /// to its defining file. Meaningless for locals and class fields.
    is_public: bool = false,
    /// HolyC member metadata on a class field (e.g. `format "%X"`). Empty for
    /// variables and metadata-free fields; surfaced through class reflection
    /// (CMemberLst.meta).
    meta: []const FieldMeta = &.{},
    /// `reg`/`noreg` storage class on a function local (HolyC writes it after
    /// the type, before the name: `I64 reg R15 i, noreg j;`). reg_name is the
    /// pinned register for `reg <REG> name`, "" otherwise. Meaningless for
    /// globals, params, and class fields.
    reg_mode: RegMode = .none,
    reg_name: []const u8 = "",
};

/// A function parameter. name is "" for an unnamed parameter (prototypes may
/// omit names); default_value is the default argument, or null.
pub const Param = struct {
    ty: Type,
    name: []const u8 = "",
    default_value: ?*Expr = null,
    span: source.Span,
};

/// A function definition or prototype. As a top-level item it is a statement
/// (a Stmt.Kind variant).
pub const FuncDef = struct {
    ret: Type,
    name: []const u8,
    params: []const Param,
    /// Trailing `...` in the parameter list.
    varargs: bool = false,
    /// Null for a prototype (`...;`) and non-null for a definition (an empty
    /// definition body is an empty, non-null slice).
    body: ?[]const *Stmt = null,
    /// `public`: callable from any file, otherwise private to its defining file.
    is_public: bool = false,
    /// Binds this declaration to an asm-defined label of a different name
    /// (`_extern <LABEL> <sig>;`). When non-empty the function has no body: a
    /// typed forward reference whose call sites call asm_label, not name.
    asm_label: []const u8 = "",
    /// Marks a dynamic-library import (`extern <ret> <name>(<params>);`): no
    /// body, bound at load time rather than to a HolyC definition.
    import: bool = false,

    pub fn isPrototype(f: *const FuncDef) bool {
        return f.body == null;
    }

    /// Whether f declares name as a parameter or local (a var_decl anywhere in
    /// its body), so a use of name in f resolves to that local, not a global.
    pub fn declaresName(f: *const FuncDef, name: []const u8) bool {
        for (f.params) |p| {
            if (std.mem.eql(u8, p.name, name)) return true;
        }
        return stmtsDeclare(f.body orelse &.{}, name);
    }
};

/// A `class` or `union` definition. As a top-level item it is a statement (a
/// Stmt.Kind variant).
pub const ClassDef = struct {
    is_union: bool = false,
    name: []const u8,
    /// `class Foo : Bar` inheritance; "" if none.
    base: []const u8 = "",
    fields: []const Declarator,
    /// `public`. Compiler-synthesized aggregates are always public.
    is_public: bool = false,
};

// ---- statements ----

/// A statement node: its shape plus its source span.
pub const Stmt = struct {
    kind: Kind,
    span: source.Span,

    pub const Kind = union(enum) {
        /// A lone `;`.
        empty,
        /// An expression evaluated for its side effects.
        expr: *Expr,
        /// A brace-enclosed sequence of statements.
        block: []const *Stmt,
        /// HolyC's `lock { … }`: a block whose read-modify-write operations are
        /// atomic across cores. Scopes like a block.
        lock: []const *Stmt,
        /// HolyC's `no_warn a, b;`: suppresses the unused-variable warning for
        /// the named in-scope locals.
        no_warn: []const []const u8,
        /// Declares one or more variables.
        var_decl: []const Declarator,
        if_stmt: struct { cond: *Expr, then: *Stmt, els: ?*Stmt },
        while_stmt: struct { cond: *Expr, body: *Stmt },
        do_while: struct { body: *Stmt, cond: *Expr },
        /// A C-style for loop; init, cond, and step are each null if absent.
        for_stmt: struct { init: ?*Stmt, cond: ?*Expr, step: ?*Expr, body: *Stmt },
        /// A switch. no_bounds is HolyC's `switch [expr]` form, which omits the
        /// range check before jump-table dispatch. sub marks `sub_switch (expr)`:
        /// a nested switch that relies on the enclosing switch's range check.
        switch_stmt: struct { cond: *Expr, body: *Stmt, no_bounds: bool = false, sub: bool = false },
        /// A `case` label. hi is set for range labels `case lo ... hi:`. lo is
        /// null for a numberless `case:`, whose value is the previous case's
        /// plus one (0 for the first).
        case: struct { lo: ?*Expr, hi: ?*Expr },
        /// A switch `default:` label.
        default,
        /// HolyC's `start:` switch sub-label: a switch prologue (runs on entry,
        /// before dispatch).
        switch_start,
        /// HolyC's `end:` switch sub-label: a switch epilogue (reached by
        /// fall-through; a `break` skips it).
        switch_end,
        break_stmt,
        /// `return;` or `return expr;`.
        return_stmt: ?*Expr,
        goto_stmt: []const u8,
        /// A `Name:` goto target.
        label: []const u8,
        /// try { body } catch { handler }. The catch block takes no parameter
        /// (HolyC form); the thrown value is Fs->except_ch.
        try_stmt: struct { body: []const *Stmt, handler: []const *Stmt },
        /// `throw expr;` raising expr's value (coerced to I64); a bare `throw;`
        /// (null) re-raises the current Fs->except_ch.
        throw: ?*Expr,
        func_def: *FuncDef,
        class_def: *ClassDef,
        asm_stmt: *AsmStmt,
    };

    /// Whether this statement (or a descendant) calls a function in names.
    pub fn callsFn(s: ?*const Stmt, names: []const []const u8) bool {
        const stmt = s orelse return false;
        switch (stmt.kind) {
            .expr => |e| return Expr.calls(e, names),
            .block, .lock => |stmts| return stmtsCall(stmts, names),
            .var_decl => |decls| {
                for (decls) |d| {
                    if (Expr.calls(d.init, names)) return true;
                }
                return false;
            },
            .if_stmt => |k| return Expr.calls(k.cond, names) or callsFn(k.then, names) or callsFn(k.els, names),
            .while_stmt => |k| return Expr.calls(k.cond, names) or callsFn(k.body, names),
            .switch_stmt => |k| return Expr.calls(k.cond, names) or callsFn(k.body, names),
            .do_while => |k| return callsFn(k.body, names) or Expr.calls(k.cond, names),
            .for_stmt => |k| return callsFn(k.init, names) or Expr.calls(k.cond, names) or
                Expr.calls(k.step, names) or callsFn(k.body, names),
            .case => |k| return Expr.calls(k.lo, names) or Expr.calls(k.hi, names),
            .return_stmt => |v| return Expr.calls(v, names),
            .func_def => |f| return stmtsCall(f.body orelse &.{}, names),
            .try_stmt => |k| return stmtsCall(k.body, names) or stmtsCall(k.handler, names),
            .throw => |v| return Expr.calls(v, names),
            else => return false,
        }
    }

    /// Whether this statement (or a descendant) references one of names as a
    /// bare identifier.
    pub fn usesIdent(s: ?*const Stmt, names: []const []const u8) bool {
        const stmt = s orelse return false;
        switch (stmt.kind) {
            .expr => |e| return Expr.usesIdent(e, names),
            .block, .lock => |stmts| return stmtsUseIdent(stmts, names),
            .var_decl => |decls| {
                for (decls) |d| {
                    if (Expr.usesIdent(d.init, names)) return true;
                }
                return false;
            },
            .if_stmt => |k| return Expr.usesIdent(k.cond, names) or usesIdent(k.then, names) or usesIdent(k.els, names),
            .while_stmt => |k| return Expr.usesIdent(k.cond, names) or usesIdent(k.body, names),
            .switch_stmt => |k| return Expr.usesIdent(k.cond, names) or usesIdent(k.body, names),
            .do_while => |k| return usesIdent(k.body, names) or Expr.usesIdent(k.cond, names),
            .for_stmt => |k| return usesIdent(k.init, names) or Expr.usesIdent(k.cond, names) or
                Expr.usesIdent(k.step, names) or usesIdent(k.body, names),
            .case => |k| return Expr.usesIdent(k.lo, names) or Expr.usesIdent(k.hi, names),
            .return_stmt => |v| return Expr.usesIdent(v, names),
            .func_def => |f| return stmtsUseIdent(f.body orelse &.{}, names),
            .try_stmt => |k| return stmtsUseIdent(k.body, names) or stmtsUseIdent(k.handler, names),
            .throw => |v| return Expr.usesIdent(v, names),
            .asm_stmt => |a| return a.referencesVar(names),
            else => return false,
        }
    }

    /// Whether this statement declares name (a var_decl, recursing into nested
    /// blocks/loops).
    pub fn declares(s: ?*const Stmt, name: []const u8) bool {
        const stmt = s orelse return false;
        switch (stmt.kind) {
            .var_decl => |decls| {
                for (decls) |d| {
                    if (std.mem.eql(u8, d.name, name)) return true;
                }
                return false;
            },
            .block, .lock => |stmts| return stmtsDeclare(stmts, name),
            .if_stmt => |k| return declares(k.then, name) or declares(k.els, name),
            .while_stmt => |k| return declares(k.body, name),
            .do_while => |k| return declares(k.body, name),
            .switch_stmt => |k| return declares(k.body, name),
            .for_stmt => |k| return declares(k.init, name) or declares(k.body, name),
            .try_stmt => |k| return stmtsDeclare(k.body, name) or stmtsDeclare(k.handler, name),
            else => return false,
        }
    }

    /// Whether this statement (or a descendant) contains a try/throw.
    pub fn hasExceptions(s: ?*const Stmt) bool {
        const stmt = s orelse return false;
        switch (stmt.kind) {
            .try_stmt, .throw => return true,
            .block, .lock => |stmts| return stmtsHaveExceptions(stmts),
            .if_stmt => |k| return hasExceptions(k.then) or hasExceptions(k.els),
            .while_stmt => |k| return hasExceptions(k.body),
            .do_while => |k| return hasExceptions(k.body),
            .for_stmt => |k| return hasExceptions(k.body),
            .switch_stmt => |k| return hasExceptions(k.body),
            .func_def => |f| return stmtsHaveExceptions(f.body orelse &.{}),
            else => return false,
        }
    }
};

pub fn stmtsCall(stmts: []const *Stmt, names: []const []const u8) bool {
    for (stmts) |s| {
        if (Stmt.callsFn(s, names)) return true;
    }
    return false;
}

pub fn stmtsUseIdent(stmts: []const *Stmt, names: []const []const u8) bool {
    for (stmts) |s| {
        if (Stmt.usesIdent(s, names)) return true;
    }
    return false;
}

pub fn stmtsDeclare(stmts: []const *Stmt, name: []const u8) bool {
    for (stmts) |s| {
        if (Stmt.declares(s, name)) return true;
    }
    return false;
}

pub fn stmtsHaveExceptions(stmts: []const *Stmt) bool {
    for (stmts) |s| {
        if (Stmt.hasExceptions(s)) return true;
    }
    return false;
}

// ---- inline assembly ----

/// An `asm [arch] { … }` inline-assembly block. A bare `asm { … }` defaults to
/// amd64; `asm amd64 { … }` states it explicitly and `asm arm64 { … }` targets
/// AArch64. A flat list of instructions and label declarations.
pub const AsmStmt = struct {
    /// The target architecture: "amd64" (the default for a bare block) or
    /// "arm64". Sema validates it.
    arch: []const u8,
    /// Span of the architecture qualifier, or the `asm` keyword when the block
    /// is bare, so sema can point at an unknown arch.
    arch_span: source.Span,
    insts: []const AsmInst,

    /// Whether the block declares any label. A labelled top-level block is
    /// standalone callable code (bound to a HolyC name by `_extern`); a
    /// labelless block is inline asm spliced into the enclosing function.
    pub fn definesLabel(a: *const AsmStmt) bool {
        for (a.insts) |inst| {
            if (inst.isLabel()) return true;
        }
        return false;
    }

    /// Whether any operand is a bare-name variable reference to one of names
    /// (so variable-use analysis counts an asm reference as a use).
    pub fn referencesVar(a: *const AsmStmt, names: []const []const u8) bool {
        for (a.insts) |inst| {
            for (inst.operands) |op| {
                switch (op.kind) {
                    .variable => |name| if (containsName(names, name)) return true,
                    else => {},
                }
            }
        }
        return false;
    }
};

/// One item in an asm block: an instruction or a label declaration. A label
/// item has label != "" with mnemonic == "" and no operands; control-flow
/// instructions reference it through a .sym operand.
pub const AsmInst = struct {
    /// Instruction mnemonic (lowercased on use); "" for a label item.
    mnemonic: []const u8 = "",
    operands: []const AsmOperand = &.{},
    /// Label-item name (`LABEL::` / `LABEL:` / `@@N`); "" for instructions.
    label: []const u8 = "",
    span: source.Span,

    pub fn isLabel(i: *const AsmInst) bool {
        return i.label.len > 0;
    }
};

/// One operand of an AsmInst.
pub const AsmOperand = struct {
    kind: Kind,
    span: source.Span,

    pub const Kind = union(enum) {
        /// A register name (e.g. "rax"/"x0").
        reg: []const u8,
        /// An integer immediate.
        imm: i64,
        /// A HolyC variable referenced by bare name (resolved during lowering).
        variable: []const u8,
        /// `&name`: the address of a label, function, or global.
        sym: []const u8,
        /// A memory operand.
        mem: *AsmMem,
    };
};

/// A memory operand `[<base> + <index>*<scale> + <disp>]`, optionally with a
/// leading type giving the access width, as in TempleOS HolyC's
/// `U64 SF_ARG1[RBP]`. Any component may be absent. disp_sym is a symbolic
/// displacement (a constant identifier such as SF_ARG1) resolved during
/// lowering; disp is the constant part.
pub const AsmMem = struct {
    /// Width/type spelling ("U64","I32",…); "" if none.
    ty: []const u8 = "",
    /// Base register name; "" if none.
    base: []const u8 = "",
    /// Index register name; "" if none.
    index: []const u8 = "",
    /// Index scale 1/2/4/8; 0 when there is no index.
    scale: i64 = 0,
    /// Constant displacement.
    disp: i64 = 0,
    /// Symbolic displacement resolved during lowering; "" if none.
    disp_sym: []const u8 = "",
};

// Register vocabularies live in asm_regs.zig, shared with the LLVM backend's
// constraint building; these re-exports keep parser and sema call sites stable.
const asm_regs = @import("asm_regs.zig");

/// The architecture labels an asm block may carry.
pub const asm_arches = asm_regs.arches;

pub const isAsmArch = asm_regs.isArch;

/// Whether name (case-insensitive) is a register of arch, so an identifier
/// operand is a register rather than a variable/symbol reference.
pub const isAsmRegister = asm_regs.isRegister;

// ---- program ----

/// A whole translation unit. HolyC is script-like: the top level is a sequence
/// of statements, which may include function and class definitions.
pub const Program = struct {
    items: []const *Stmt,
    /// Source files seen during parsing, indexed by span.file. Each carries the
    /// file's directory, used by sema for directory privacy checks. Provenance:
    /// not part of structural equality.
    files: []const source.FileInfo,
    /// The computed in-memory layout of every class/union, filled in by the
    /// layout pass; null until that pass runs.
    layouts: ?*@import("layout.zig").Layouts = null,

    /// Whether the program contains a call to any function named in names.
    pub fn callsAny(p: *const Program, names: []const []const u8) bool {
        return stmtsCall(p.items, names);
    }

    /// Whether the program references any of names as a bare identifier
    /// (anywhere, including inside function bodies).
    pub fn usesIdent(p: *const Program, names: []const []const u8) bool {
        return stmtsUseIdent(p.items, names);
    }

    /// Whether the program contains any try/throw.
    pub fn hasExceptions(p: *const Program) bool {
        return stmtsHaveExceptions(p.items);
    }
};

// ---- tests ----

test "type rendering" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const i64_ty: Type = .{ .prim = .I64 };
    try std.testing.expectEqualStrings("I64", try Type.string(i64_ty, arena));
    const ptr: Type = .{ .ptr = &i64_ty };
    try std.testing.expectEqualStrings("I64*", try Type.string(ptr, arena));
    try std.testing.expectEqualStrings("?", try Type.string(null, arena));

    const fp: Type = .{ .func_ptr = .{ .ret = &i64_ty, .params = &.{ i64_ty, ptr } } };
    try std.testing.expectEqualStrings("I64 (*)(I64, I64*)", try Type.string(fp, arena));
}

test "prim spellings" {
    try std.testing.expectEqual(Type.Prim.I64, Type.Prim.fromString("I64").?);
    try std.testing.expectEqual(@as(?Type.Prim, null), Type.Prim.fromString("F32"));
}
