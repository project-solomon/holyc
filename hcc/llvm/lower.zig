//! Lowers the checked, laid-out HolyC AST to LLVM IR.
//!
//! This is the Zig/LLVM port of the retired Go compiler's lower.go: the
//! semantic decisions (narrow-int promote-then-truncate, signedness of >>, /,
//! % and relationals, pointer-arithmetic scaling, store/arg/return coercion,
//! HolyC varargs, call-site default arguments, lastclass, switch machinery,
//! setjmp/longjmp exceptions over the CTask context, implicit print, and the
//! synthesized program entry) are preserved exactly; the mechanics differ in
//! that we emit LLVM IR instead of a custom SSA IR.
//!
//! Representation choices:
//!   - Scalars: I8/U8=i8 … I64/U64=i64, F64=double, every pointer is the
//!     opaque `ptr`. Signedness is a property of operations, decided from the
//!     AST types.
//!   - Aggregates are byte arrays (`[size x i8]`); every field access is a
//!     byte-offset GEP driven by prog.layouts, so HolyC layout (inheritance,
//!     anonymous members, unions, offset()) can never drift from LLVM's own
//!     struct layout rules.
//!   - Every local (and parameter) lives in an alloca in the function's entry
//!     block; LLVM's mem2reg (run as part of default<O2>) rebuilds SSA.
//!   - Defined HolyC functions get internal linkage so whole-program DCE can
//!     drop the unused parts of the always-resident prelude, mirroring the Go
//!     compiler's PruneUnreachable.

const std = @import("std");
const c = @import("c.zig");
const diag = @import("hcc").diag;
const ast = @import("hcc").ast;
const layout_mod = @import("hcc").layout;
const source = @import("hcc").source;
const target_mod = @import("hcc").target;
const asm_regs = @import("hcc").asm_regs;

pub const Error = diag.Error;

pub const Input = struct {
    ctx: *c.Context,
    module: *c.Module,
    builder: *c.Builder,
    prog: *const ast.Program,
    target: target_mod.Target,
    mode: Mode = .exe,
};

/// How the module is packaged. In .library mode (objects for separate
/// compilation, shared libraries) `public` functions and globals defined in
/// the user's own source keep external linkage — they are the unit's exports
/// and survive whole-program DCE — and a unit with no top-level code gets no
/// `main` (the Go compiler's objectMode rule). Prelude definitions stay
/// internal in both modes: the prelude spells everything `public`, but it is
/// each unit's private runtime, not an export surface.
pub const Mode = enum { exe, library };

/// Populates the module from the program. The module must verify afterwards.
pub fn run(arena: std.mem.Allocator, diags: *diag.Diagnostics, in: Input) Error!void {
    const layouts = in.prog.layouts orelse blk: {
        const empty = try arena.create(layout_mod.Layouts);
        empty.* = .{};
        break :blk empty;
    };
    // A second builder dedicated to allocas, positioned into each function's
    // entry block, so every alloca lands there (standard LLVM practice; also
    // makes jumping over declarations with goto safe).
    const ab = c.LLVMCreateBuilderInContext(in.ctx);
    defer c.LLVMDisposeBuilder(ab);

    var lw = Lowerer{
        .arena = arena,
        .diags = diags,
        .ctx = in.ctx,
        .module = in.module,
        .b = in.builder,
        .ab = ab,
        .tgt = in.target,
        .mode = in.mode,
        .prog = in.prog,
        .layouts = layouts,
        .ty_void = c.LLVMVoidTypeInContext(in.ctx),
        .ty_i1 = c.LLVMInt1TypeInContext(in.ctx),
        .ty_i8 = c.LLVMInt8TypeInContext(in.ctx),
        .ty_i16 = c.LLVMInt16TypeInContext(in.ctx),
        .ty_i32 = c.LLVMInt32TypeInContext(in.ctx),
        .ty_i64 = c.LLVMInt64TypeInContext(in.ctx),
        .ty_f64 = c.LLVMDoubleTypeInContext(in.ctx),
        .ty_ptr = c.LLVMPointerTypeInContext(in.ctx, 0),
    };
    try lw.lowerProgram();
}

// ---- machine value types ----

/// The machine type of a scalar value in flight (the Go ir.Ty). Aggregates
/// have no VTy: they live in memory and are reached through a pointer.
const VTy = enum {
    i8_,
    u8_,
    i16_,
    u16_,
    i32_,
    u32_,
    i64_,
    u64_,
    f64_,
    ptr_,

    fn isFloat(t: VTy) bool {
        return t == .f64_;
    }

    fn isSigned(t: VTy) bool {
        return switch (t) {
            .i8_, .i16_, .i32_, .i64_ => true,
            else => false,
        };
    }

    fn bits(t: VTy) u8 {
        return switch (t) {
            .i8_, .u8_ => 8,
            .i16_, .u16_ => 16,
            .i32_, .u32_ => 32,
            else => 64,
        };
    }
};

/// A typed LLVM value: the value plus its machine type.
const TV = struct {
    v: *c.Value,
    ty: VTy,
};

/// A resolved lvalue: the address of the storage plus the AST type stored
/// there. All lvalues are memory (every local is an alloca).
const Lvalue = struct {
    addr: *c.Value,
    ty: ast.Type,
};

// ---- shared AST type helpers (ports of the Go module-level helpers) ----

const prim_i64: ast.Type = .{ .prim = .I64 };
const prim_u8: ast.Type = .{ .prim = .U8 };
const ty_i64_ptr: ast.Type = .{ .ptr = &prim_i64 };
const ty_u8_ptr: ast.Type = .{ .ptr = &prim_u8 };
const ty_u8_ptr_ptr: ast.Type = .{ .ptr = &ty_u8_ptr };
const ktask_named: ast.Type = .{ .named = "CTask" };
const ty_ktask_ptr: ast.Type = .{ .ptr = &ktask_named };

fn scalarVTy(ty: ast.Type) ?VTy {
    return switch (ty) {
        .prim => |p| switch (p) {
            .U0, .I0 => null,
            .I8 => .i8_,
            .U8 => .u8_,
            .I16 => .i16_,
            .U16 => .u16_,
            .I32 => .i32_,
            .U32 => .u32_,
            .I64 => .i64_,
            .U64 => .u64_,
            .F64 => .f64_,
        },
        .ptr, .func_ptr => .ptr_,
        else => null,
    };
}

fn isVoidTy(ty: ast.Type) bool {
    return ty == .prim and (ty.prim == .U0 or ty.prim == .I0);
}

fn derefTy(ty: ast.Type) ?ast.Type {
    return switch (ty) {
        .ptr => |e| e.*,
        .array => |a| a.elem.*,
        else => null,
    };
}

fn isPtrLike(e: *const ast.Expr) bool {
    const t = e.ty orelse return false;
    return switch (t) {
        .ptr, .array => true,
        else => false,
    };
}

fn exprIsF64(e: *const ast.Expr) bool {
    const t = e.ty orelse return false;
    return t.isPrim(.F64);
}

/// The promoted operation width of a binary op: F64 if either side is F64,
/// else I64 (narrow ints always widen; the result is truncated on store).
fn promoted(lhs: *const ast.Expr, rhs: *const ast.Expr) VTy {
    if (exprIsF64(lhs) or exprIsF64(rhs)) return .f64_;
    return .i64_;
}

fn typeSigned(ty: ast.Type) bool {
    return switch (ty) {
        .prim => |p| switch (p) {
            .I8, .I16, .I32, .I64 => true,
            else => false,
        },
        else => false,
    };
}

fn exprSigned(e: *const ast.Expr) bool {
    const t = e.ty orelse return true;
    return typeSigned(t);
}

fn signedLeft(lhs: *const ast.Expr) bool {
    return exprSigned(lhs);
}

fn signedRel(lhs: *const ast.Expr, rhs: *const ast.Expr) bool {
    return exprSigned(lhs) and exprSigned(rhs);
}

fn isCmpOp(op: ast.BinOp) bool {
    return switch (op) {
        .eq, .ne, .lt, .le, .gt, .ge => true,
        else => false,
    };
}

fn className(ty: ast.Type) ?[]const u8 {
    return switch (ty) {
        .named => |n| n,
        else => null,
    };
}

// ---- primitive intrinsics (port of goref ir/prim.go) ----

const PrimKind = enum {
    std_write,
    malloc,
    free,
    heap_extend,
    msize,
    exit,
    exit_raw,
    system,
    getpid,
    getppid,
    getuid,
    getgid,
    unix_ns,
    nano_ns,
    cpu_ns,
    sleep,
    open,
    lseek,
    read,
    write,
    close,
    socket,
    connect,
    bind,
    listen,
    accept,
    setsockopt,
    shutdown,
    remove,
    rename,
    mkdir,
    chdir,
    getcwd,
    gettid,
    thread,
    join,
    thread_yield,
    thread_exit,
    thread_detach,
    atomic_load,
    atomic_store,
    atomic_add,
    atomic_swap,
    atomic_cas,
    futex_wait,
    futex_wake,
    futex_wait_ns,
};

const prim_names = std.StaticStringMap(PrimKind).initComptime(.{
    .{ "StdWrite", .std_write },
    .{ "MAlloc", .malloc },
    .{ "Free", .free },
    .{ "HeapExtend", .heap_extend },
    .{ "MSize", .msize },
    .{ "Exit", .exit },
    .{ "ExitRaw", .exit_raw },
    .{ "System", .system },
    .{ "Getpid", .getpid },
    .{ "Getppid", .getppid },
    .{ "Getuid", .getuid },
    .{ "Getgid", .getgid },
    .{ "UnixNS", .unix_ns },
    .{ "NanoNS", .nano_ns },
    .{ "CpuNS", .cpu_ns },
    .{ "Sleep", .sleep },
    .{ "Open", .open },
    .{ "LSeek", .lseek },
    .{ "Read", .read },
    .{ "Write", .write },
    .{ "Close", .close },
    .{ "Socket", .socket },
    .{ "Connect", .connect },
    .{ "Bind", .bind },
    .{ "Listen", .listen },
    .{ "Accept", .accept },
    .{ "SetSockOpt", .setsockopt },
    .{ "Shutdown", .shutdown },
    .{ "Remove", .remove },
    .{ "Rename", .rename },
    .{ "Mkdir", .mkdir },
    .{ "Chdir", .chdir },
    .{ "Getcwd", .getcwd },
    .{ "Gettid", .gettid },
    .{ "Thread", .thread },
    .{ "Join", .join },
    .{ "ThreadYield", .thread_yield },
    .{ "ThreadExit", .thread_exit },
    .{ "ThreadDetach", .thread_detach },
    .{ "AtomicLoad", .atomic_load },
    .{ "AtomicStore", .atomic_store },
    .{ "AtomicAdd", .atomic_add },
    .{ "AtomicSwap", .atomic_swap },
    .{ "AtomicCas", .atomic_cas },
    .{ "FutexWait", .futex_wait },
    .{ "FutexWake", .futex_wake },
    .{ "FutexWaitNs", .futex_wait_ns },
});

// ---- the lowerer ----

/// A function's call-relevant signature (the Go fnSig): the declaration that
/// carries parameters/defaults, whether any declaration has a body, and the
/// LLVM function once created.
const FnSig = struct {
    def: *const ast.FuncDef,
    has_body: bool = false,
    /// The file the winning (defining) item came from, for the library-mode
    /// export decision: only file-0 (user source) definitions export.
    def_file: u32 = 0,
    value: ?*c.Value = null,
    fn_ty: ?*c.Type = null,
};

const GlobalInfo = struct {
    value: *c.Value,
    ty: ast.Type,
};

const DeclFn = struct {
    value: *c.Value,
    fn_ty: *c.Type,
};

const FsOffsets = struct {
    self: u64,
    except_ch: u64,
    catch_except: u64,
    exc_top: u64,
};

/// A conservatively large on-stack jmp_buf (darwin arm64 needs 192 bytes,
/// glibc x86-64 200); the frame stores the previous chain head after it.
const jmp_buf_len = 256;

const Lowerer = struct {
    arena: std.mem.Allocator,
    diags: *diag.Diagnostics,
    ctx: *c.Context,
    module: *c.Module,
    b: *c.Builder,
    /// Alloca-only builder, positioned before each function's entry br.
    ab: *c.Builder,
    tgt: target_mod.Target,
    mode: Mode = .exe,
    prog: *const ast.Program,
    layouts: *const layout_mod.Layouts,

    ty_void: *c.Type,
    ty_i1: *c.Type,
    ty_i8: *c.Type,
    ty_i16: *c.Type,
    ty_i32: *c.Type,
    ty_i64: *c.Type,
    ty_f64: *c.Type,
    ty_ptr: *c.Type,

    sigs: std.StringArrayHashMapUnmanaged(FnSig) = .empty,
    globals: std.StringArrayHashMapUnmanaged(GlobalInfo) = .empty,
    strings: std.StringArrayHashMapUnmanaged(*c.Value) = .empty,
    libc: std.StringArrayHashMapUnmanaged(DeclFn) = .empty,
    /// The zeroed CTask storage backing the Fs global, when CTask exists.
    fs_storage: ?*c.Value = null,
    fs_offsets: ?FsOffsets = null,
    setjmp_fn: ?DeclFn = null,
    thread_shim: ?DeclFn = null,
    longjmp_fn: ?DeclFn = null,

    fn failAt(l: *Lowerer, span: source.Span, comptime fmt: []const u8, args: anytype) Error {
        return l.diags.fail(.codegen, span.file, span.pos, fmt, args);
    }

    fn llvmTy(l: *Lowerer, vt: VTy) *c.Type {
        return switch (vt) {
            .i8_, .u8_ => l.ty_i8,
            .i16_, .u16_ => l.ty_i16,
            .i32_, .u32_ => l.ty_i32,
            .i64_, .u64_ => l.ty_i64,
            .f64_ => l.ty_f64,
            .ptr_ => l.ty_ptr,
        };
    }

    fn constInt(l: *Lowerer, vt: VTy, x: i64) TV {
        return .{ .v = c.LLVMConstInt(l.llvmTy(vt), @bitCast(x), 0), .ty = vt };
    }

    fn constI64(l: *Lowerer, x: i64) *c.Value {
        return c.LLVMConstInt(l.ty_i64, @bitCast(x), 0);
    }

    fn constI32(l: *Lowerer, x: i32) *c.Value {
        return c.LLVMConstInt(l.ty_i32, @bitCast(@as(i64, x)), 0);
    }

    fn zeroOf(l: *Lowerer, vt: VTy) TV {
        return switch (vt) {
            .f64_ => .{ .v = c.LLVMConstReal(l.ty_f64, 0), .ty = .f64_ },
            .ptr_ => .{ .v = c.LLVMConstPointerNull(l.ty_ptr), .ty = .ptr_ },
            else => l.constInt(vt, 0),
        };
    }

    fn archMatches(l: *Lowerer, arch: []const u8) bool {
        return std.mem.eql(u8, arch, asm_regs.archName(l.tgt.arch));
    }

    // ---- program lowering ----

    fn lowerProgram(l: *Lowerer) Error!void {
        try l.collectSigs();
        try l.registerGlobals();
        try l.declareDefinedFuncs();

        for (l.prog.items) |item| {
            switch (item.kind) {
                .func_def => |f| if (f.body != null) {
                    try l.lowerFunction(f);
                },
                else => {},
            }
        }
        try l.lowerEntry();
    }

    /// Records every top-level function's signature. A definition (body)
    /// wins over a prototype for parameter/default information.
    fn collectSigs(l: *Lowerer) Error!void {
        for (l.prog.items) |item| {
            const f = switch (item.kind) {
                .func_def => |f| f,
                else => continue,
            };
            const gop = try l.sigs.getOrPut(l.arena, f.name);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{ .def = f, .has_body = f.body != null, .def_file = item.span.file };
                continue;
            }
            if (f.body != null or !gop.value_ptr.has_body) {
                gop.value_ptr.def = f;
                gop.value_ptr.def_file = item.span.file;
            }
            if (f.body != null) gop.value_ptr.has_body = true;
        }
    }

    /// Whether argc/argv are referenced at top level (outside any function),
    /// the Go Program.UsesCommandLine gate.
    fn usesCommandLine(l: *Lowerer) bool {
        for (l.prog.items) |s| {
            if (s.kind == .func_def) continue;
            if (ast.Stmt.usesIdent(s, &.{ "argc", "argv" })) return true;
        }
        return false;
    }

    fn createGlobal(l: *Lowerer, name: []const u8, ty: ast.Type, exported: bool) Error!void {
        if (l.globals.contains(name)) return;
        const name_z = try l.arena.dupeZ(u8, name);
        var gty: *c.Type = undefined;
        if (scalarVTy(ty)) |vt| {
            gty = l.llvmTy(vt);
        } else {
            const size = @max(l.layouts.sizeOf(ty), 1);
            gty = c.LLVMArrayType2(l.ty_i8, size);
        }
        const g = c.LLVMAddGlobal(l.module, gty, name_z);
        c.LLVMSetInitializer(g, c.LLVMConstNull(gty));
        c.LLVMSetLinkage(g, if (exported) .external else .internal);
        c.LLVMSetAlignment(g, @intCast(@max(l.layouts.alignOf(ty), 1)));
        try l.globals.put(l.arena, name, .{ .value = g, .ty = ty });
    }

    /// Builds the global table: declared globals, the Fs exception context
    /// (when the prelude's CTask exists), and the implicit command-line /
    /// environment globals (each only when the program actually uses it).
    fn registerGlobals(l: *Lowerer) Error!void {
        for (l.prog.items) |item| {
            switch (item.kind) {
                .var_decl => |decls| for (decls) |d| {
                    try l.createGlobal(d.name, d.ty, l.exportsName(d.is_public, item.span.file));
                },
                else => {},
            }
        }

        if (l.layouts.get("CTask")) |kt| {
            if (!l.globals.contains("Fs")) {
                const storage_ty = c.LLVMArrayType2(l.ty_i8, @max(kt.size, 1));
                const storage = c.LLVMAddGlobal(l.module, storage_ty, "Fs.ktask");
                c.LLVMSetInitializer(storage, c.LLVMConstNull(storage_ty));
                c.LLVMSetLinkage(storage, .internal);
                c.LLVMSetAlignment(storage, @intCast(@max(kt.alignment, 8)));
                l.fs_storage = storage;

                const fs = c.LLVMAddGlobal(l.module, l.ty_ptr, "Fs");
                // Statically point Fs at its storage (a global's address is a
                // constant), so the exception chain works even in a library
                // with no entry; the entry still stores it (and self) for the
                // executable path.
                c.LLVMSetInitializer(fs, storage);
                c.LLVMSetLinkage(fs, .internal);
                c.LLVMSetAlignment(fs, 8);
                try l.globals.put(l.arena, "Fs", .{ .value = fs, .ty = ty_ktask_ptr });

                l.fs_offsets = .{
                    .self = l.layouts.offsetOf("CTask", "self") orelse 0,
                    .except_ch = l.layouts.offsetOf("CTask", "except_ch") orelse 8,
                    .catch_except = l.layouts.offsetOf("CTask", "catch_except") orelse 16,
                    .exc_top = l.layouts.offsetOf("CTask", "exc_top") orelse 24,
                };
            }
        }

        if (l.usesCommandLine()) {
            try l.createGlobal("argc", prim_i64, false);
            try l.createGlobal("argv", ty_u8_ptr_ptr, false);
        }
        if (l.prog.usesIdent(&.{"envp"})) {
            try l.createGlobal("envp", ty_u8_ptr_ptr, false);
        }
    }

    /// The LLVM function type for a HolyC declaration: hidden leading sret
    /// pointer for an aggregate return, array/aggregate params as pointers,
    /// hidden trailing (i64 argc, ptr argv) for HolyC varargs. An `extern`
    /// import instead uses the platform C ABI with native varargs.
    fn fnTypeFor(l: *Lowerer, f: *const ast.FuncDef) Error!*c.Type {
        var params: std.ArrayList(*c.Type) = .empty;
        var ret_ty: *c.Type = undefined;
        if (isVoidTy(f.ret)) {
            ret_ty = l.ty_void;
        } else if (f.ret.isAggregate()) {
            ret_ty = l.ty_void;
            try params.append(l.arena, l.ty_ptr);
        } else {
            ret_ty = l.llvmTy(scalarVTy(f.ret) orelse .i64_);
        }
        for (f.params) |p| {
            const pt: *c.Type = switch (p.ty) {
                .array, .named => l.ty_ptr,
                else => l.llvmTy(scalarVTy(p.ty) orelse .i64_),
            };
            try params.append(l.arena, pt);
        }
        if (f.import) {
            return c.LLVMFunctionType(ret_ty, if (params.items.len == 0) null else params.items.ptr, @intCast(params.items.len), @intFromBool(f.varargs));
        }
        if (f.varargs) {
            try params.append(l.arena, l.ty_i64);
            try params.append(l.arena, l.ty_ptr);
        }
        return c.LLVMFunctionType(ret_ty, if (params.items.len == 0) null else params.items.ptr, @intCast(params.items.len), 0);
    }

    fn declareDefinedFuncs(l: *Lowerer) Error!void {
        for (l.sigs.keys(), l.sigs.values()) |name, *sig| {
            if (!sig.has_body) continue;
            const fn_ty = try l.fnTypeFor(sig.def);
            const v = c.LLVMAddFunction(l.module, try l.arena.dupeZ(u8, name), fn_ty);
            c.LLVMSetLinkage(v, if (l.exportsName(sig.def.is_public, sig.def_file)) .external else .internal);
            sig.value = v;
            sig.fn_ty = fn_ty;
        }
    }

    /// Whether a defined function/global is part of the unit's export surface:
    /// library mode, `public`, and defined in the user's own source (file 0 —
    /// the prelude spells everything public but is each unit's private
    /// runtime).
    fn exportsName(l: *const Lowerer, is_public: bool, def_file: u32) bool {
        return l.mode == .library and is_public and def_file == 0;
    }

    /// The LLVM function for a signature, declaring an external one on first
    /// use for bodyless prototypes and `extern` imports.
    fn fnValue(l: *Lowerer, name: []const u8, sig: *FnSig) Error!DeclFn {
        if (sig.value) |v| return .{ .value = v, .fn_ty = sig.fn_ty.? };
        const fn_ty = try l.fnTypeFor(sig.def);
        const v = c.LLVMAddFunction(l.module, try l.arena.dupeZ(u8, name), fn_ty);
        sig.value = v;
        sig.fn_ty = fn_ty;
        return .{ .value = v, .fn_ty = fn_ty };
    }

    fn internString(l: *Lowerer, s: []const u8) Error!*c.Value {
        if (l.strings.get(s)) |v| return v;
        const cs = c.LLVMConstStringInContext2(l.ctx, s.ptr, s.len, 0);
        const g = c.LLVMAddGlobal(l.module, c.LLVMTypeOf(cs), ".str");
        c.LLVMSetInitializer(g, cs);
        c.LLVMSetGlobalConstant(g, 1);
        c.LLVMSetLinkage(g, .private);
        c.LLVMSetUnnamedAddress(g, .global);
        c.LLVMSetAlignment(g, 1);
        try l.strings.put(l.arena, s, g);
        return g;
    }

    fn libcFn(l: *Lowerer, name: []const u8, ret: *c.Type, params: []const *c.Type, is_vararg: bool) Error!DeclFn {
        if (l.libc.get(name)) |f| return f;
        const fn_ty = c.LLVMFunctionType(ret, if (params.len == 0) null else params.ptr, @intCast(params.len), @intFromBool(is_vararg));
        const v = c.LLVMAddFunction(l.module, try l.arena.dupeZ(u8, name), fn_ty);
        const f = DeclFn{ .value = v, .fn_ty = fn_ty };
        try l.libc.put(l.arena, name, f);
        return f;
    }

    fn callLib(l: *Lowerer, f: DeclFn, args: []const *c.Value) *c.Value {
        return c.LLVMBuildCall2(l.b, f.fn_ty, f.value, if (args.len == 0) null else args.ptr, @intCast(args.len), "");
    }

    fn enumAttr(l: *Lowerer, name: []const u8) *c.Attribute {
        const kind = c.LLVMGetEnumAttributeKindForName(name.ptr, name.len);
        return c.LLVMCreateEnumAttribute(l.ctx, kind, 0);
    }

    fn setjmpFn(l: *Lowerer) Error!DeclFn {
        if (l.setjmp_fn) |f| return f;
        // _setjmp/_longjmp: no signal-mask save, present on darwin and glibc
        // Linux alike; matches HolyC's cheap non-signal exception semantics.
        var params = [_]*c.Type{l.ty_ptr};
        const f = try l.libcFn("_setjmp", l.ty_i32, &params, false);
        c.LLVMAddAttributeAtIndex(f.value, c.attribute_function_index, l.enumAttr("returns_twice"));
        l.setjmp_fn = f;
        return f;
    }

    fn longjmpFn(l: *Lowerer) Error!DeclFn {
        if (l.longjmp_fn) |f| return f;
        var params = [_]*c.Type{ l.ty_ptr, l.ty_i32 };
        const f = try l.libcFn("_longjmp", l.ty_void, &params, false);
        c.LLVMAddAttributeAtIndex(f.value, c.attribute_function_index, l.enumAttr("noreturn"));
        l.longjmp_fn = f;
        return f;
    }

    /// The pthread trampoline for Thread(): receives a malloc'd {fn, arg}
    /// pair, frees it, runs fn(arg), and returns the I64 result as the
    /// thread's exit value.
    fn threadShim(l: *Lowerer) Error!DeclFn {
        if (l.thread_shim) |f| return f;
        var shim_params = [_]*c.Type{l.ty_ptr};
        const fn_ty = c.LLVMFunctionType(l.ty_ptr, &shim_params, 1, 0);
        const v = c.LLVMAddFunction(l.module, "hcc_thread_shim", fn_ty);
        c.LLVMSetLinkage(v, .internal);
        const saved = c.LLVMGetInsertBlock(l.b);
        const bb = c.LLVMAppendBasicBlockInContext(l.ctx, v, "entry");
        c.LLVMPositionBuilderAtEnd(l.b, bb);
        const pair = c.LLVMGetParam(v, 0);
        const fnp = c.LLVMBuildLoad2(l.b, l.ty_ptr, pair, "");
        const arg_ptr = l.gepByte(pair, 8);
        const arg = c.LLVMBuildLoad2(l.b, l.ty_i64, arg_ptr, "");
        var free_params = [_]*c.Type{l.ty_ptr};
        const free_fn = try l.libcFn("free", l.ty_void, &free_params, false);
        var free_args = [_]*c.Value{pair};
        _ = l.callLib(free_fn, &free_args);
        var body_params = [_]*c.Type{l.ty_i64};
        const body_ty = c.LLVMFunctionType(l.ty_i64, &body_params, 1, 0);
        var body_args = [_]*c.Value{arg};
        const r = c.LLVMBuildCall2(l.b, body_ty, fnp, &body_args, 1, "");
        const rp = c.LLVMBuildIntToPtr(l.b, r, l.ty_ptr, "");
        _ = c.LLVMBuildRet(l.b, rp);
        if (saved) |sb| c.LLVMPositionBuilderAtEnd(l.b, sb);
        const f = DeclFn{ .value = v, .fn_ty = fn_ty };
        l.thread_shim = f;
        return f;
    }

    fn gepByte(l: *Lowerer, base: *c.Value, off: u64) *c.Value {
        if (off == 0) return base;
        var idx = [_]*c.Value{c.LLVMConstInt(l.ty_i64, off, 0)};
        return c.LLVMBuildGEP2(l.b, l.ty_i8, base, &idx, 1, "");
    }

    fn gepByteV(l: *Lowerer, base: *c.Value, off: *c.Value) *c.Value {
        var idx = [_]*c.Value{off};
        return c.LLVMBuildGEP2(l.b, l.ty_i8, base, &idx, 1, "");
    }

    /// base + index*stride, the Go PtrAdd.
    fn gepScaled(l: *Lowerer, base: *c.Value, index: *c.Value, stride: u64) *c.Value {
        var off = index;
        if (stride != 1) {
            off = c.LLVMBuildMul(l.b, index, c.LLVMConstInt(l.ty_i64, stride, 0), "");
        }
        return l.gepByteV(base, off);
    }

    fn memZero(l: *Lowerer, dst: *c.Value, len: u64) void {
        if (len == 0) return;
        _ = c.LLVMBuildMemSet(l.b, dst, c.LLVMConstInt(l.ty_i8, 0, 0), c.LLVMConstInt(l.ty_i64, len, 0), 1);
    }

    fn memCpy(l: *Lowerer, dst: *c.Value, src: *c.Value, len: u64) void {
        if (len == 0) return;
        _ = c.LLVMBuildMemCpy(l.b, dst, 1, src, 1, c.LLVMConstInt(l.ty_i64, len, 0));
    }

    // ---- function lowering ----

    fn lowerFunction(l: *Lowerer, f: *const ast.FuncDef) Error!void {
        const sig = l.sigs.getPtr(f.name).?;
        var fc = try FnCtx.begin(l, sig.value.?, f.ret, false);

        var pidx: c_uint = 0;
        if (!isVoidTy(f.ret) and f.ret.isAggregate()) {
            fc.sret = c.LLVMGetParam(fc.func, 0);
            pidx = 1;
        }
        for (f.params) |p| {
            const pv = c.LLVMGetParam(fc.func, pidx);
            pidx += 1;
            if (p.name.len == 0) continue;
            switch (p.ty) {
                .array => {
                    // An array parameter decays to a pointer to its data.
                    const slot = fc.allocaTy(l.ty_ptr, p.name);
                    _ = c.LLVMBuildStore(l.b, pv, slot);
                    try fc.bind(p.name, .{ .ty = p.ty, .addr = slot, .indirect = true });
                },
                .named => {
                    // A class/union parameter is passed by value, carried by
                    // address: the callee copies it into its own slot.
                    const size = l.layouts.sizeOf(p.ty);
                    const slot = fc.allocaBytes(size, l.layouts.alignOf(p.ty), p.name);
                    l.memCpy(slot, pv, size);
                    try fc.bind(p.name, .{ .ty = p.ty, .addr = slot });
                },
                else => {
                    const vt = scalarVTy(p.ty) orelse return l.failAt(p.span, "non-scalar parameter not lowered", .{});
                    const slot = fc.allocaTy(l.llvmTy(vt), p.name);
                    _ = c.LLVMBuildStore(l.b, pv, slot);
                    try fc.bind(p.name, .{ .ty = p.ty, .addr = slot });
                },
            }
        }
        if (f.varargs) {
            // The hidden HolyC varargs params: argc (the count) and argv (a
            // pointer to the packed 8-byte slots).
            const vc = c.LLVMGetParam(fc.func, pidx);
            const vv = c.LLVMGetParam(fc.func, pidx + 1);
            const cslot = fc.allocaTy(l.ty_i64, "argc");
            _ = c.LLVMBuildStore(l.b, vc, cslot);
            try fc.bind("argc", .{ .ty = prim_i64, .addr = cslot });
            const vslot = fc.allocaTy(l.ty_ptr, "argv");
            _ = c.LLVMBuildStore(l.b, vv, vslot);
            try fc.bind("argv", .{ .ty = ty_i64_ptr, .addr = vslot });
        }

        for (f.body.?) |s| try fc.lowerStmt(s);
        try fc.finish();
    }

    /// Synthesizes `i32 main(i32 argc, ptr argv, ptr envp)` from the
    /// top-level statements. main seeds the implicit globals and the Fs task
    /// context, runs the top-level code, then (like the Go entry trampoline)
    /// returns 0 regardless of the top-level value.
    fn lowerEntry(l: *Lowerer) Error!void {
        // Split the top level: standalone labelled asm blocks are module-level
        // code regardless of entry; everything else that is not a pure
        // declaration becomes the entry body.
        var top: std.ArrayList(*ast.Stmt) = .empty;
        for (l.prog.items) |s| {
            switch (s.kind) {
                .func_def, .class_def, .empty => continue,
                .asm_stmt => |a| if (a.definesLabel()) {
                    // A labelled top-level block is standalone callable code
                    // (a labelless one is inline asm in the entry). A block
                    // for another architecture is dropped (per-target
                    // pairing).
                    if (l.archMatches(a.arch)) try l.lowerStandaloneAsm(a);
                    continue;
                },
                else => {},
            }
            try top.append(l.arena, s);
        }

        // The Go objectMode rule: a separate-compilation unit with no
        // top-level code gets no entry (a shared library of functions must
        // not define main).
        if (l.mode == .library and top.items.len == 0) return;

        var main_params = [_]*c.Type{ l.ty_i32, l.ty_ptr, l.ty_ptr };
        const main_ty = c.LLVMFunctionType(l.ty_i32, &main_params, main_params.len, 0);
        const main_fn = c.LLVMAddFunction(l.module, "main", main_ty);
        var fc = try FnCtx.begin(l, main_fn, prim_i64, true);

        if (l.globals.get("argc")) |g| {
            const a64 = c.LLVMBuildSExt(l.b, c.LLVMGetParam(main_fn, 0), l.ty_i64, "");
            _ = c.LLVMBuildStore(l.b, a64, g.value);
        }
        if (l.globals.get("argv")) |g| {
            _ = c.LLVMBuildStore(l.b, c.LLVMGetParam(main_fn, 1), g.value);
        }
        if (l.globals.get("envp")) |g| {
            _ = c.LLVMBuildStore(l.b, c.LLVMGetParam(main_fn, 2), g.value);
        }
        if (l.fs_storage) |storage| {
            const fs = l.globals.get("Fs").?;
            _ = c.LLVMBuildStore(l.b, storage, fs.value);
            if (l.fs_offsets) |offs| {
                _ = c.LLVMBuildStore(l.b, storage, l.gepByte(storage, offs.self));
            }
        }

        for (top.items) |s| {
            try fc.lowerStmt(s);
        }
        try fc.finish();
    }

    /// The assembler-level spelling of a global symbol (Mach-O prepends an
    /// underscore), for module-level asm that must define what LLVM-emitted
    /// call sites reference.
    fn symbolName(l: *Lowerer, name: []const u8) Error![]const u8 {
        if (l.tgt.os == .darwin) return std.fmt.allocPrint(l.arena, "_{s}", .{name});
        return name;
    }

    /// Lowers a standalone labelled top-level asm block to module-level
    /// assembly: its labels become global .text symbols that `_extern`-bound
    /// call sites (and other blocks' branches) reference by name. amd64 text
    /// is Intel syntax, so the module asm brackets it with syntax directives.
    fn lowerStandaloneAsm(l: *Lowerer, a: *const ast.AsmStmt) Error!void {
        var g = AsmGen{ .l = l, .a = a, .info = asmArchInfo(l.tgt.arch), .fc = null };
        try g.collectLabels();
        try g.put("{s}", .{g.info.module_prologue});
        try g.render();
        try g.put("{s}", .{g.info.module_epilogue});
        c.LLVMAppendModuleInlineAsm(l.module, g.text.items.ptr, g.text.items.len);
    }
};

// ---- per-function lowering context ----

const Local = struct {
    ty: ast.Type,
    addr: *c.Value,
    /// The alloca holds a pointer to the data rather than the data itself
    /// (array parameters, which decay to by-reference pointers).
    indirect: bool = false,
    /// The canonical register a `reg <REG>` declaration pinned this variable
    /// to ("" when unpinned). Inline asm blocks naming the register sync the
    /// variable through it; outside asm the pin is a placement hint with no
    /// LLVM equivalent (regalloc decides).
    pin_reg: []const u8 = "",
};

const Scope = std.StringArrayHashMapUnmanaged(Local);

const BreakTarget = struct {
    block: *c.BasicBlock,
    depth: usize,
};

const TryFrame = struct {
    prev_ptr: *c.Value,
};

const FnCtx = struct {
    l: *Lowerer,
    func: *c.Value,
    /// The entry block's `br body` terminator; allocas are inserted before it.
    entry_br: *c.Value,
    ret_ty: ast.Type,
    is_entry: bool,
    sret: ?*c.Value = null,

    scopes: std.ArrayList(Scope) = .empty,
    labels: std.StringArrayHashMapUnmanaged(*c.BasicBlock) = .empty,
    label_depth: std.StringArrayHashMapUnmanaged(usize) = .empty,
    breaks: std.ArrayList(BreakTarget) = .empty,
    tries: std.ArrayList(TryFrame) = .empty,
    terminated: bool = false,
    /// > 0 while lowering statements inside a `lock { … }` block: the
    /// LOCK-prefixable read-modify-write operations (++/-- and += -= &= |= ^=
    /// on integer scalars) then compile to atomic instructions, which is what
    /// TempleOS's LOCK prefix did.
    lock_depth: usize = 0,

    asm_seen: bool = false,
    asm_matched: bool = false,
    asm_span: source.Span = .{},

    fn begin(l: *Lowerer, func: *c.Value, ret_ty: ast.Type, is_entry: bool) Error!FnCtx {
        const entry = c.LLVMAppendBasicBlockInContext(l.ctx, func, "entry");
        const body = c.LLVMAppendBasicBlockInContext(l.ctx, func, "body");
        c.LLVMPositionBuilderAtEnd(l.b, entry);
        const entry_br = c.LLVMBuildBr(l.b, body);
        c.LLVMPositionBuilderAtEnd(l.b, body);
        var fc = FnCtx{ .l = l, .func = func, .entry_br = entry_br, .ret_ty = ret_ty, .is_entry = is_entry };
        try fc.pushScope();
        return fc;
    }

    /// Closes the function: the Go pairing diagnostic for inline asm, then
    /// the default return on fall-off.
    fn finish(fc: *FnCtx) Error!void {
        const l = fc.l;
        if (fc.asm_seen and !fc.asm_matched) {
            return l.failAt(fc.asm_span, "inline asm in this function targets only another architecture; none matches the build target ({s})", .{asm_regs.archName(l.tgt.arch)});
        }
        if (!fc.terminated) {
            if (fc.is_entry) {
                try fc.emitAtexitRun();
                _ = c.LLVMBuildRet(l.b, l.constI32(0));
            } else {
                fc.defaultRet();
            }
            fc.terminated = true;
        }
    }

    fn defaultRet(fc: *FnCtx) void {
        const l = fc.l;
        if (isVoidTy(fc.ret_ty) or fc.ret_ty.isAggregate()) {
            _ = c.LLVMBuildRetVoid(l.b);
            return;
        }
        const vt = scalarVTy(fc.ret_ty) orelse .i64_;
        _ = c.LLVMBuildRet(l.b, l.zeroOf(vt).v);
    }

    // ---- scopes, blocks, allocas ----

    fn pushScope(fc: *FnCtx) Error!void {
        try fc.scopes.append(fc.l.arena, .empty);
    }

    fn popScope(fc: *FnCtx) void {
        _ = fc.scopes.pop();
    }

    fn bind(fc: *FnCtx, name: []const u8, local: Local) Error!void {
        try fc.scopes.items[fc.scopes.items.len - 1].put(fc.l.arena, name, local);
    }

    fn lookup(fc: *FnCtx, name: []const u8) ?Local {
        var i = fc.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (fc.scopes.items[i].get(name)) |info| return info;
        }
        return null;
    }

    fn newBlock(fc: *FnCtx, name: [*:0]const u8) *c.BasicBlock {
        return c.LLVMAppendBasicBlockInContext(fc.l.ctx, fc.func, name);
    }

    fn position(fc: *FnCtx, blk: *c.BasicBlock) void {
        c.LLVMPositionBuilderAtEnd(fc.l.b, blk);
        fc.terminated = false;
    }

    fn curBlock(fc: *FnCtx) *c.BasicBlock {
        return c.LLVMGetInsertBlock(fc.l.b).?;
    }

    fn br(fc: *FnCtx, blk: *c.BasicBlock) void {
        _ = c.LLVMBuildBr(fc.l.b, blk);
        fc.terminated = true;
    }

    fn condBr(fc: *FnCtx, cond: *c.Value, t: *c.BasicBlock, f: *c.BasicBlock) void {
        _ = c.LLVMBuildCondBr(fc.l.b, cond, t, f);
        fc.terminated = true;
    }

    fn ensureLive(fc: *FnCtx) void {
        if (fc.terminated) {
            fc.position(fc.newBlock("dead"));
        }
    }

    fn allocaTy(fc: *FnCtx, t: *c.Type, name: []const u8) *c.Value {
        const l = fc.l;
        c.LLVMPositionBuilderBefore(l.ab, fc.entry_br);
        const a = c.LLVMBuildAlloca(l.ab, t, "");
        if (name.len > 0) c.LLVMSetValueName2(a, name.ptr, name.len);
        return a;
    }

    fn allocaBytes(fc: *FnCtx, size: u64, alignment: u64, name: []const u8) *c.Value {
        const l = fc.l;
        const t = c.LLVMArrayType2(l.ty_i8, @max(size, 1));
        const a = fc.allocaTy(t, name);
        c.LLVMSetAlignment(a, @intCast(@max(alignment, 1)));
        return a;
    }

    // ---- coercion (the Go coerce/Cast semantics) ----

    fn coerce(fc: *FnCtx, tv: TV, to: VTy) TV {
        const l = fc.l;
        const from = tv.ty;
        if (from == to) return tv;
        const b = l.b;
        if (to == .f64_) {
            const v = switch (from) {
                .ptr_ => blk: {
                    const i = c.LLVMBuildPtrToInt(b, tv.v, l.ty_i64, "");
                    break :blk c.LLVMBuildUIToFP(b, i, l.ty_f64, "");
                },
                else => if (from.isSigned())
                    c.LLVMBuildSIToFP(b, tv.v, l.ty_f64, "")
                else
                    c.LLVMBuildUIToFP(b, tv.v, l.ty_f64, ""),
            };
            return .{ .v = v, .ty = .f64_ };
        }
        if (to == .ptr_) {
            const v = switch (from) {
                .f64_ => blk: {
                    const i = c.LLVMBuildFPToSI(b, tv.v, l.ty_i64, "");
                    break :blk c.LLVMBuildIntToPtr(b, i, l.ty_ptr, "");
                },
                else => blk: {
                    var i = tv.v;
                    if (from.bits() < 64) {
                        i = if (from.isSigned())
                            c.LLVMBuildSExt(b, i, l.ty_i64, "")
                        else
                            c.LLVMBuildZExt(b, i, l.ty_i64, "");
                    }
                    break :blk c.LLVMBuildIntToPtr(b, i, l.ty_ptr, "");
                },
            };
            return .{ .v = v, .ty = .ptr_ };
        }
        // Integer destination.
        var iv: *c.Value = undefined;
        switch (from) {
            .f64_ => {
                // Truncating float→int conversion; an unsigned 64-bit
                // destination converts unsigned, narrower ones convert via
                // signed I64 then truncate (the Go/x86 cvttsd2si shape).
                iv = if (to == .u64_)
                    c.LLVMBuildFPToUI(b, tv.v, l.ty_i64, "")
                else
                    c.LLVMBuildFPToSI(b, tv.v, l.ty_i64, "");
                if (to.bits() < 64) iv = c.LLVMBuildTrunc(b, iv, l.llvmTy(to), "");
                return .{ .v = iv, .ty = to };
            },
            .ptr_ => {
                iv = c.LLVMBuildPtrToInt(b, tv.v, l.ty_i64, "");
                if (to.bits() < 64) iv = c.LLVMBuildTrunc(b, iv, l.llvmTy(to), "");
                return .{ .v = iv, .ty = to };
            },
            else => {
                const fb = from.bits();
                const tb = to.bits();
                if (fb == tb) return .{ .v = tv.v, .ty = to };
                if (fb < tb) {
                    iv = if (from.isSigned())
                        c.LLVMBuildSExt(b, tv.v, l.llvmTy(to), "")
                    else
                        c.LLVMBuildZExt(b, tv.v, l.llvmTy(to), "");
                } else {
                    iv = c.LLVMBuildTrunc(b, tv.v, l.llvmTy(to), "");
                }
                return .{ .v = iv, .ty = to };
            },
        }
    }

    fn coerceToAst(fc: *FnCtx, tv: TV, to: ast.Type, span: source.Span) Error!TV {
        const vt = scalarVTy(to) orelse return fc.l.failAt(span, "coercion to a non-scalar type", .{});
        return fc.coerce(tv, vt);
    }

    // ---- loads / stores ----

    fn loadScalar(fc: *FnCtx, addr: *c.Value, vt: VTy) TV {
        return .{ .v = c.LLVMBuildLoad2(fc.l.b, fc.l.llvmTy(vt), addr, ""), .ty = vt };
    }

    fn loadLvalue(fc: *FnCtx, lv: Lvalue, span: source.Span) Error!TV {
        const vt = scalarVTy(lv.ty) orelse return fc.l.failAt(span, "load of an aggregate lvalue", .{});
        return fc.loadScalar(lv.addr, vt);
    }

    fn storeLvalue(fc: *FnCtx, lv: Lvalue, tv: TV) void {
        const vt = scalarVTy(lv.ty) orelse .i64_;
        const v = fc.coerce(tv, vt);
        _ = c.LLVMBuildStore(fc.l.b, v.v, lv.addr);
    }

    // ---- Fs / exception helpers ----

    fn fsFieldPtr(fc: *FnCtx, off: u64, span: source.Span) Error!*c.Value {
        const l = fc.l;
        const g = l.globals.get("Fs") orelse return l.failAt(span, "Fs is not available (the prelude's CTask is missing)", .{});
        const fs = c.LLVMBuildLoad2(l.b, l.ty_ptr, g.value, "");
        return l.gepByte(fs, off);
    }

    fn fsOffs(fc: *FnCtx, span: source.Span) Error!FsOffsets {
        return fc.l.fs_offsets orelse fc.l.failAt(span, "Fs is not available (the prelude's CTask is missing)", .{});
    }

    /// Restores Fs->exc_top to the state before the try region at
    /// target_depth: the runtime part of the Go exitTryRegions, emitted for
    /// each non-local exit (break/goto/return) that escapes try regions.
    fn exitTryRegions(fc: *FnCtx, target_depth: usize, span: source.Span) Error!void {
        if (fc.tries.items.len <= target_depth) return;
        const l = fc.l;
        const offs = try fc.fsOffs(span);
        const prev = c.LLVMBuildLoad2(l.b, l.ty_ptr, fc.tries.items[target_depth].prev_ptr, "");
        const top_ptr = try fc.fsFieldPtr(offs.exc_top, span);
        _ = c.LLVMBuildStore(l.b, prev, top_ptr);
    }

    fn emitAtexitRun(fc: *FnCtx) Error!void {
        const l = fc.l;
        const sig = l.sigs.getPtr("__AtExitRun") orelse return;
        if (!sig.has_body) return;
        const f = try l.fnValue("__AtExitRun", sig);
        _ = c.LLVMBuildCall2(l.b, f.fn_ty, f.value, null, 0, "");
    }

    // ---- statements ----

    fn lowerStmt(fc: *FnCtx, s: *const ast.Stmt) Error!void {
        const l = fc.l;
        fc.ensureLive();
        switch (s.kind) {
            .empty, .no_warn => {},
            .expr => |e| try fc.lowerStmtExpr(e),
            .block => |stmts| {
                try fc.pushScope();
                for (stmts) |st| try fc.lowerStmt(st);
                fc.popScope();
            },
            .lock => |stmts| {
                // A scoped block whose read-modify-write operations compile
                // to atomic instructions (TempleOS's LOCK prefix), pairing
                // with Thread()-spawned POSIX threads.
                fc.lock_depth += 1;
                try fc.pushScope();
                for (stmts) |st| try fc.lowerStmt(st);
                fc.popScope();
                fc.lock_depth -= 1;
            },
            .var_decl => |decls| for (decls) |*d| try fc.lowerDecl(d),
            .if_stmt => |k| try fc.lowerIf(k.cond, k.then, k.els),
            .while_stmt => |k| try fc.lowerWhile(k.cond, k.body),
            .do_while => |k| try fc.lowerDoWhile(k.body, k.cond),
            .for_stmt => |k| try fc.lowerFor(k.init, k.cond, k.step, k.body),
            .switch_stmt => |k| try fc.lowerSwitch(k.cond, k.body, s.span),
            .return_stmt => |v| try fc.lowerReturn(v, s.span),
            .break_stmt => {
                if (fc.breaks.items.len == 0) {
                    return l.failAt(s.span, "break outside a loop", .{});
                }
                const t = fc.breaks.items[fc.breaks.items.len - 1];
                try fc.exitTryRegions(t.depth, s.span);
                fc.br(t.block);
            },
            .label => |name| {
                const blk = try fc.labelBlock(name);
                try fc.label_depth.put(l.arena, name, fc.tries.items.len);
                fc.br(blk);
                fc.position(blk);
            },
            .goto_stmt => |name| {
                const blk = try fc.labelBlock(name);
                if (fc.label_depth.get(name)) |depth| {
                    try fc.exitTryRegions(depth, s.span);
                }
                fc.br(blk);
            },
            .try_stmt => |k| try fc.lowerTry(k.body, k.handler, s.span),
            .throw => |v| try fc.lowerThrow(v, s.span),
            .asm_stmt => |a| {
                if (!fc.asm_seen) {
                    fc.asm_seen = true;
                    fc.asm_span = a.arch_span;
                }
                if (!l.archMatches(a.arch)) return; // other-arch block: pairing drop
                fc.asm_matched = true;
                return fc.lowerInlineAsm(a);
            },
            .func_def => return l.failAt(s.span, "nested function definitions are not lowered", .{}),
            .class_def => {},
            .case, .default, .switch_start, .switch_end => {
                return l.failAt(s.span, "case/default label outside a switch", .{});
            },
        }
    }

    fn labelBlock(fc: *FnCtx, name: []const u8) Error!*c.BasicBlock {
        if (fc.labels.get(name)) |blk| return blk;
        const blk = fc.newBlock("label");
        try fc.labels.put(fc.l.arena, name, blk);
        return blk;
    }

    /// The innermost in-scope local pinned (`reg <REG>`) to the canonical
    /// register reg, or null.
    fn pinnedLocal(fc: *FnCtx, reg: []const u8) ?Local {
        var i = fc.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const locals = fc.scopes.items[i].values();
            var j = locals.len;
            while (j > 0) {
                j -= 1;
                if (std.mem.eql(u8, locals[j].pin_reg, reg)) return locals[j];
            }
        }
        return null;
    }

    /// Lowers a labelless `asm { … }` block whose arch matches the target to
    /// one side-effecting inline-asm call: pinned variables sync through
    /// their registers ({reg} in, ={reg} out), variables named as operands
    /// pass their address as `r` inputs, and every other named GP register is
    /// clobbered (plus memory and the flags — correctness over performance).
    fn lowerInlineAsm(fc: *FnCtx, a: *const ast.AsmStmt) Error!void {
        const l = fc.l;
        var g = AsmGen{ .l = l, .a = a, .info = asmArchInfo(l.tgt.arch), .fc = fc };
        try g.collectLabels();
        try g.collectOperands();
        try g.render();

        var cons: std.ArrayList(u8) = .empty;
        var arg_tys: std.ArrayList(*c.Type) = .empty;
        var args: std.ArrayList(*c.Value) = .empty;
        for (g.pins.items) |p| try cons.print(l.arena, "={{{s}}},", .{p.reg});
        for (g.pins.items) |p| {
            const ty = l.llvmTy(scalarVTy(p.local.ty) orelse .i64_);
            try cons.print(l.arena, "{{{s}}},", .{p.reg});
            try arg_tys.append(l.arena, ty);
            try args.append(l.arena, c.LLVMBuildLoad2(l.b, ty, p.local.addr, ""));
        }
        for (g.vars.items) |v| {
            try cons.print(l.arena, "{s},", .{g.info.var_constraint});
            try arg_tys.append(l.arena, l.ty_ptr);
            try args.append(l.arena, v.local.addr);
        }
        for (g.clobbers.items) |r| try cons.print(l.arena, "~{{{s}}},", .{r});
        try cons.appendSlice(l.arena, g.info.baseline_clobbers);

        const ret_ty: *c.Type = switch (g.pins.items.len) {
            0 => l.ty_void,
            1 => l.llvmTy(scalarVTy(g.pins.items[0].local.ty) orelse .i64_),
            else => blk: {
                var tys: std.ArrayList(*c.Type) = .empty;
                for (g.pins.items) |p| {
                    try tys.append(l.arena, l.llvmTy(scalarVTy(p.local.ty) orelse .i64_));
                }
                break :blk c.LLVMStructTypeInContext(l.ctx, tys.items.ptr, @intCast(tys.items.len), 0);
            },
        };
        const fn_ty = c.LLVMFunctionType(ret_ty, if (arg_tys.items.len == 0) null else arg_tys.items.ptr, @intCast(arg_tys.items.len), 0);
        const asm_v = c.LLVMGetInlineAsm(
            fn_ty,
            g.text.items.ptr,
            g.text.items.len,
            cons.items.ptr,
            cons.items.len,
            1, // side effects
            0, // align stack
            g.info.dialect,
            0, // can throw
        );
        const call = c.LLVMBuildCall2(l.b, fn_ty, asm_v, if (args.items.len == 0) null else args.items.ptr, @intCast(args.items.len), "");
        switch (g.pins.items.len) {
            0 => {},
            1 => _ = c.LLVMBuildStore(l.b, call, g.pins.items[0].local.addr),
            else => for (g.pins.items, 0..) |p, i| {
                const v = c.LLVMBuildExtractValue(l.b, call, @intCast(i), "");
                _ = c.LLVMBuildStore(l.b, v, p.local.addr);
            },
        }
    }

    fn lowerStmtExpr(fc: *FnCtx, e: *ast.Expr) Error!void {
        const l = fc.l;
        switch (e.kind) {
            .str_lit => |s| {
                // A bare string statement is sugar for Print("..."): a
                // %-free literal fast-paths to StdWrite, anything with %
                // goes through the HolyC Print formatter.
                if (std.mem.indexOfScalar(u8, s, '%') != null) {
                    var args = [_]?*ast.Expr{e};
                    _ = try fc.lowerNamedCall("Print", &args, e.span);
                    return;
                }
                const str = try l.internString(s);
                var params = [_]*c.Type{ l.ty_i32, l.ty_ptr, l.ty_i64 };
                const write_fn = try l.libcFn("write", l.ty_i64, &params, false);
                var call_args = [_]*c.Value{ l.constI32(1), str, l.constI64(@intCast(s.len)) };
                _ = l.callLib(write_fn, &call_args);
            },
            .comma => |exprs| {
                const args = try l.arena.alloc(?*ast.Expr, exprs.len);
                for (exprs, 0..) |sub, i| args[i] = sub;
                _ = try fc.lowerNamedCall("Print", args, e.span);
            },
            else => _ = try fc.lowerExpr(e),
        }
    }

    fn lowerDecl(fc: *FnCtx, d: *const ast.Declarator) Error!void {
        const l = fc.l;
        // A variable-length array (non-constant dimension) is not lowered.
        if (d.ty == .array) {
            if (d.ty.array.size) |sz| {
                switch (layout_mod.constEvalIn(sz, l.layouts)) {
                    .err => return l.failAt(d.span, "variable-length array not yet lowered", .{}),
                    .value => {},
                }
            }
        }

        // A top-level declaration in the entry's outermost scope defines a
        // global; its (runtime) initializer runs here, in statement order.
        if (fc.is_entry and fc.scopes.items.len == 1) {
            if (l.globals.get(d.name)) |g| {
                if (d.init != null) {
                    try fc.initMemory(g.value, g.ty, d.init);
                }
                return;
            }
        }

        // The initializer is lowered before the new name is bound, so
        // `I64 v = v+1;` resolves to an outer v. reg/noreg are placement
        // hints with no LLVM equivalent (regalloc decides), except that a
        // `reg <REG>` pin is recorded so inline asm naming the register can
        // sync the variable through it.
        if (d.ty.isAggregate()) {
            const size = l.layouts.sizeOf(d.ty);
            const slot = fc.allocaBytes(size, l.layouts.alignOf(d.ty), d.name);
            try fc.initMemory(slot, d.ty, d.init);
            try fc.bind(d.name, .{ .ty = d.ty, .addr = slot });
        } else {
            var pin_reg: []const u8 = "";
            if (d.reg_mode == .reg and d.reg_name.len > 0) {
                pin_reg = asm_regs.canonGp(l.tgt.arch, d.reg_name) orelse
                    return l.failAt(d.span, "variable `{s}` cannot be pinned to `{s}`: not a pinnable {s} general-purpose register", .{ d.name, d.reg_name, asm_regs.archName(l.tgt.arch) });
            }
            const vt = scalarVTy(d.ty) orelse .i64_;
            const slot = fc.allocaTy(l.llvmTy(vt), d.name);
            var val = l.zeroOf(vt);
            if (d.init) |init_expr| {
                const v = try fc.lowerExpr(init_expr);
                val = try fc.coerceToAst(v, d.ty, d.span);
            }
            _ = c.LLVMBuildStore(l.b, val.v, slot);
            try fc.bind(d.name, .{ .ty = d.ty, .addr = slot, .pin_reg = pin_reg });
        }
    }

    /// Zero storage, then apply the initializer (the Go initMemory).
    fn initMemory(fc: *FnCtx, base: *c.Value, ty: ast.Type, init: ?*ast.Expr) Error!void {
        const l = fc.l;
        const size = l.layouts.sizeOf(ty);
        l.memZero(base, size);
        const init_expr = init orelse return;
        if (ty.isAggregate()) {
            switch (init_expr.kind) {
                .init_list, .designated_init => try fc.lowerInitInto(base, ty, init_expr),
                else => {
                    const src = try fc.lowerAggregateAddr(init_expr);
                    l.memCpy(base, src, size);
                },
            }
        } else {
            const v = try fc.lowerExpr(init_expr);
            const cv = try fc.coerceToAst(v, ty, init_expr.span);
            _ = c.LLVMBuildStore(l.b, cv.v, base);
        }
    }

    fn lowerInitInto(fc: *FnCtx, addr: *c.Value, ty: ast.Type, init: *ast.Expr) Error!void {
        const l = fc.l;
        switch (init.kind) {
            .init_list => |elems| switch (ty) {
                .array => |arr| {
                    const stride = l.layouts.strideOf(arr.elem.*);
                    for (elems, 0..) |item, i| {
                        const at = l.gepByte(addr, @as(u64, i) * stride);
                        try fc.lowerInitInto(at, arr.elem.*, item);
                    }
                },
                .named => |cn| {
                    const lay = l.layouts.get(cn) orelse return l.failAt(init.span, "unknown class `{s}`", .{cn});
                    for (elems, 0..) |item, i| {
                        if (i >= lay.fields.len) break;
                        const f = lay.fields[i];
                        const at = l.gepByte(addr, f.offset);
                        try fc.lowerInitInto(at, f.ty, item);
                    }
                },
                else => return l.failAt(init.span, "brace initializer on a scalar", .{}),
            },
            .designated_init => |fields| {
                const cn = className(ty) orelse return l.failAt(init.span, "designated initializer on a non-class", .{});
                const lay = l.layouts.get(cn) orelse return l.failAt(init.span, "unknown class `{s}`", .{cn});
                for (fields) |fi| {
                    const f = lay.field(fi.name) orelse return l.failAt(init.span, "unknown field `{s}`", .{fi.name});
                    const at = l.gepByte(addr, f.offset);
                    try fc.lowerInitInto(at, f.ty, fi.value);
                }
            },
            else => {
                if (ty.isAggregate()) {
                    const src = try fc.lowerAggregateAddr(init);
                    l.memCpy(addr, src, l.layouts.sizeOf(ty));
                } else {
                    const v = try fc.lowerExpr(init);
                    const cv = try fc.coerceToAst(v, ty, init.span);
                    _ = c.LLVMBuildStore(l.b, cv.v, addr);
                }
            },
        }
    }

    fn lowerReturn(fc: *FnCtx, e: ?*ast.Expr, span: source.Span) Error!void {
        const l = fc.l;
        // Returning out of open try regions must unwind the Fs->exc_top
        // chain, whose frames live on this function's dying stack.
        try fc.exitTryRegions(0, span);
        if (fc.is_entry) {
            // The entry's return value is discarded (the Go trampoline
            // returned 0 regardless); the expression still runs.
            if (e) |expr| _ = try fc.lowerExpr(expr);
            try fc.emitAtexitRun();
            _ = c.LLVMBuildRet(l.b, l.constI32(0));
            fc.terminated = true;
            return;
        }
        if (e) |expr| {
            if (isVoidTy(fc.ret_ty)) {
                _ = try fc.lowerExpr(expr);
                _ = c.LLVMBuildRetVoid(l.b);
            } else if (fc.ret_ty.isAggregate()) {
                const src = try fc.lowerAggregateAddr(expr);
                const sret = fc.sret orelse return l.failAt(span, "aggregate-returning function has no sret", .{});
                l.memCpy(sret, src, l.layouts.sizeOf(fc.ret_ty));
                _ = c.LLVMBuildRetVoid(l.b);
            } else {
                const vt = scalarVTy(fc.ret_ty) orelse .i64_;
                const v = fc.coerce(try fc.lowerExpr(expr), vt);
                _ = c.LLVMBuildRet(l.b, v.v);
            }
        } else {
            fc.defaultRet();
        }
        fc.terminated = true;
    }

    fn lowerIf(fc: *FnCtx, cond: *ast.Expr, then: *ast.Stmt, els: ?*ast.Stmt) Error!void {
        const cv = try fc.lowerCond(cond);
        const then_b = fc.newBlock("if.then");
        const join = fc.newBlock("if.join");
        const false_target = if (els != null) fc.newBlock("if.else") else join;
        fc.condBr(cv, then_b, false_target);

        fc.position(then_b);
        try fc.lowerStmt(then);
        if (!fc.terminated) fc.br(join);

        if (els) |els_stmt| {
            fc.position(false_target);
            try fc.lowerStmt(els_stmt);
            if (!fc.terminated) fc.br(join);
        }
        fc.position(join);
    }

    fn lowerWhile(fc: *FnCtx, cond: *ast.Expr, body: *ast.Stmt) Error!void {
        const l = fc.l;
        const header = fc.newBlock("while.header");
        fc.br(header);
        fc.position(header);

        const cv = try fc.lowerCond(cond);
        const body_b = fc.newBlock("while.body");
        const after = fc.newBlock("while.after");
        fc.condBr(cv, body_b, after);

        try fc.breaks.append(l.arena, .{ .block = after, .depth = fc.tries.items.len });
        fc.position(body_b);
        try fc.lowerStmt(body);
        if (!fc.terminated) fc.br(header);
        _ = fc.breaks.pop();

        fc.position(after);
    }

    fn lowerDoWhile(fc: *FnCtx, body: *ast.Stmt, cond: *ast.Expr) Error!void {
        const l = fc.l;
        const body_b = fc.newBlock("do.body");
        fc.br(body_b);
        const cont = fc.newBlock("do.cond");
        const after = fc.newBlock("do.after");

        fc.position(body_b);
        try fc.breaks.append(l.arena, .{ .block = after, .depth = fc.tries.items.len });
        try fc.lowerStmt(body);
        if (!fc.terminated) fc.br(cont);
        _ = fc.breaks.pop();

        fc.position(cont);
        const cv = try fc.lowerCond(cond);
        fc.condBr(cv, body_b, after);

        fc.position(after);
    }

    fn lowerFor(fc: *FnCtx, init: ?*ast.Stmt, cond: ?*ast.Expr, step: ?*ast.Expr, body: *ast.Stmt) Error!void {
        const l = fc.l;
        try fc.pushScope();
        if (init) |init_stmt| try fc.lowerStmt(init_stmt);
        const header = fc.newBlock("for.header");
        fc.br(header);
        fc.position(header);

        const body_b = fc.newBlock("for.body");
        const step_b = fc.newBlock("for.step");
        const after = fc.newBlock("for.after");
        if (cond) |ce| {
            const cv = try fc.lowerCond(ce);
            fc.condBr(cv, body_b, after);
        } else {
            fc.br(body_b);
        }

        try fc.breaks.append(l.arena, .{ .block = after, .depth = fc.tries.items.len });
        fc.position(body_b);
        try fc.lowerStmt(body);
        if (!fc.terminated) fc.br(step_b);
        _ = fc.breaks.pop();

        fc.position(step_b);
        if (step) |se| _ = try fc.lowerExpr(se);
        if (!fc.terminated) fc.br(header);

        fc.position(after);
        fc.popScope();
    }

    fn isCaseLabel(s: *const ast.Stmt) bool {
        return switch (s.kind) {
            .case, .default => true,
            else => false,
        };
    }

    fn lowerSwitch(fc: *FnCtx, cond: *ast.Expr, body: *ast.Stmt, span: source.Span) Error!void {
        const l = fc.l;
        const stmts = switch (body.kind) {
            .block => |ss| ss,
            else => return l.failAt(span, "switch body must be a block", .{}),
        };

        const sval = fc.coerce(try fc.lowerExpr(cond), .i64_);

        var start_idx: ?usize = null;
        var first_case: ?usize = null;
        var end_idx: ?usize = null;
        for (stmts, 0..) |s, i| {
            switch (s.kind) {
                .switch_start => if (start_idx == null) {
                    start_idx = i;
                },
                .switch_end => if (end_idx == null) {
                    end_idx = i;
                },
                else => {},
            }
            if (first_case == null and isCaseLabel(s)) first_case = i;
        }
        // The start: prologue [start+1, first case) runs on entry, before
        // dispatch; a break skips the end: epilogue.
        const prologue_active = start_idx != null;
        const prologue_end = first_case orelse stmts.len;

        try fc.pushScope();
        const exit = fc.newBlock("sw.exit");

        if (prologue_active) {
            var i = start_idx.? + 1;
            while (i < prologue_end) : (i += 1) {
                try fc.lowerStmt(stmts[i]);
            }
        }

        const block_at = try l.arena.alloc(?*c.BasicBlock, stmts.len);
        @memset(block_at, null);
        var default_block: ?*c.BasicBlock = null;
        for (stmts, 0..) |s, i| {
            switch (s.kind) {
                .case => block_at[i] = fc.newBlock("sw.case"),
                .default => {
                    const blk = fc.newBlock("sw.default");
                    block_at[i] = blk;
                    default_block = blk;
                },
                else => {},
            }
        }
        var end_block: ?*c.BasicBlock = null;
        if (end_idx != null) end_block = fc.newBlock("sw.end");
        const gap = default_block orelse (end_block orelse exit);

        // Resolve case-label values, including the numberless `case:` whose
        // value is the next integer after the previous case (first is 0).
        const CaseVal = struct { lo: i64, hi: i64 };
        const case_vals = try l.arena.alloc(?CaseVal, stmts.len);
        @memset(case_vals, null);
        var all_const = true;
        var has_auto = false;
        var auto_next: i64 = 0;
        for (stmts, 0..) |s, i| {
            const ca = switch (s.kind) {
                .case => |ca| ca,
                else => continue,
            };
            const lo_expr = ca.lo orelse {
                has_auto = true;
                case_vals[i] = .{ .lo = auto_next, .hi = auto_next };
                auto_next += 1;
                continue;
            };
            const lo = switch (layout_mod.constEvalIn(lo_expr, l.layouts)) {
                .value => |v| v,
                .err => {
                    all_const = false;
                    continue;
                },
            };
            var hi = lo;
            if (ca.hi) |hi_expr| {
                hi = switch (layout_mod.constEvalIn(hi_expr, l.layouts)) {
                    .value => |v| v,
                    .err => {
                        all_const = false;
                        continue;
                    },
                };
            }
            case_vals[i] = .{ .lo = lo, .hi = hi };
            auto_next = hi + 1;
        }
        if (has_auto and !all_const) {
            return l.failAt(span, "a numberless `case:` requires every case label in the switch to be a constant", .{});
        }

        // Dispatch: a signed compare chain in source order (first match
        // wins), with constant labels folded to immediates. `switch [x]`
        // (nobounds) and sub_switch dispatch identically here.
        for (stmts, 0..) |s, i| {
            const ca = switch (s.kind) {
                .case => |ca| ca,
                else => continue,
            };
            const tgt = block_at[i].?;
            if (case_vals[i]) |cv| {
                if (cv.lo == cv.hi) {
                    const eq = c.LLVMBuildICmp(l.b, .eq, sval.v, l.constI64(cv.lo), "");
                    const next = fc.newBlock("sw.next");
                    fc.condBr(eq, tgt, next);
                    fc.position(next);
                } else {
                    const ge = c.LLVMBuildICmp(l.b, .sge, sval.v, l.constI64(cv.lo), "");
                    const lo_ok = fc.newBlock("sw.lo");
                    const next = fc.newBlock("sw.next");
                    fc.condBr(ge, lo_ok, next);
                    fc.position(lo_ok);
                    const le = c.LLVMBuildICmp(l.b, .sle, sval.v, l.constI64(cv.hi), "");
                    fc.condBr(le, tgt, next);
                    fc.position(next);
                }
            } else {
                const lo_v = fc.coerce(try fc.lowerExpr(ca.lo.?), .i64_);
                if (ca.hi == null) {
                    const eq = c.LLVMBuildICmp(l.b, .eq, sval.v, lo_v.v, "");
                    const next = fc.newBlock("sw.next");
                    fc.condBr(eq, tgt, next);
                    fc.position(next);
                } else {
                    const ge = c.LLVMBuildICmp(l.b, .sge, sval.v, lo_v.v, "");
                    const lo_ok = fc.newBlock("sw.lo");
                    const next = fc.newBlock("sw.next");
                    fc.condBr(ge, lo_ok, next);
                    fc.position(lo_ok);
                    const hi_v = fc.coerce(try fc.lowerExpr(ca.hi.?), .i64_);
                    const le = c.LLVMBuildICmp(l.b, .sle, sval.v, hi_v.v, "");
                    fc.condBr(le, tgt, next);
                    fc.position(next);
                }
            }
        }
        fc.br(gap);

        // Emit the body: one block per case/default, explicit fall-through,
        // break jumping to exit (skipping the end: epilogue).
        try fc.breaks.append(l.arena, .{ .block = exit, .depth = fc.tries.items.len });
        for (stmts, 0..) |s, i| {
            if (prologue_active and i > start_idx.? and i < prologue_end) continue;
            switch (s.kind) {
                .switch_start => {},
                .case, .default => {
                    const blk = block_at[i].?;
                    if (!fc.terminated) fc.br(blk);
                    fc.position(blk);
                },
                .switch_end => {
                    const blk = end_block.?;
                    if (!fc.terminated) fc.br(blk);
                    fc.position(blk);
                },
                else => try fc.lowerStmt(s),
            }
        }
        if (!fc.terminated) fc.br(exit);
        _ = fc.breaks.pop();

        fc.position(exit);
        fc.popScope();
    }

    // ---- try / throw ----

    fn lowerTry(fc: *FnCtx, body: []const *ast.Stmt, handler: []const *ast.Stmt, span: source.Span) Error!void {
        const l = fc.l;
        const offs = try fc.fsOffs(span);

        // Frame layout: [jmp_buf][prev]. Push onto the Fs->exc_top chain.
        const frame = fc.allocaBytes(jmp_buf_len + 8, 16, "exc.frame");
        const prev_ptr = l.gepByte(frame, jmp_buf_len);
        const top_ptr = try fc.fsFieldPtr(offs.exc_top, span);
        const old_top = c.LLVMBuildLoad2(l.b, l.ty_ptr, top_ptr, "");
        _ = c.LLVMBuildStore(l.b, old_top, prev_ptr);
        _ = c.LLVMBuildStore(l.b, frame, top_ptr);

        const sj = try l.setjmpFn();
        var sj_args = [_]*c.Value{frame};
        const rc = l.callLib(sj, &sj_args);
        c.LLVMAddCallSiteAttribute(rc, c.attribute_function_index, l.enumAttr("returns_twice"));

        const pad = fc.newBlock("try.pad");
        const body_b = fc.newBlock("try.body");
        const after = fc.newBlock("try.after");
        const nonzero = c.LLVMBuildICmp(l.b, .ne, rc, l.constI32(0), "");
        fc.condBr(nonzero, pad, body_b);

        fc.position(body_b);
        try fc.tries.append(l.arena, .{ .prev_ptr = prev_ptr });
        try fc.pushScope();
        for (body) |s| try fc.lowerStmt(s);
        fc.popScope();
        _ = fc.tries.pop();
        if (!fc.terminated) {
            try fc.popExcTop(prev_ptr, offs, span);
            fc.br(after);
        }

        // The landing pad: a throw longjmp'd here with the frame still on
        // the chain; pop it before running the handler (the Go dispatcher's
        // count-- before jumping to the pad).
        fc.position(pad);
        try fc.popExcTop(prev_ptr, offs, span);
        try fc.pushScope();
        for (handler) |s| try fc.lowerStmt(s);
        fc.popScope();
        if (!fc.terminated) {
            const cc_ptr = try fc.fsFieldPtr(offs.catch_except, span);
            _ = c.LLVMBuildStore(l.b, l.constI64(0), cc_ptr);
            fc.br(after);
        }

        fc.position(after);
    }

    fn popExcTop(fc: *FnCtx, prev_ptr: *c.Value, offs: FsOffsets, span: source.Span) Error!void {
        const l = fc.l;
        const prev = c.LLVMBuildLoad2(l.b, l.ty_ptr, prev_ptr, "");
        const top_ptr = try fc.fsFieldPtr(offs.exc_top, span);
        _ = c.LLVMBuildStore(l.b, prev, top_ptr);
    }

    fn lowerThrow(fc: *FnCtx, val: ?*ast.Expr, span: source.Span) Error!void {
        const l = fc.l;
        const offs = try fc.fsOffs(span);
        if (val) |e| {
            const v = fc.coerce(try fc.lowerExpr(e), .i64_);
            const ch_ptr = try fc.fsFieldPtr(offs.except_ch, span);
            _ = c.LLVMBuildStore(l.b, v.v, ch_ptr);
        }
        const cc_ptr = try fc.fsFieldPtr(offs.catch_except, span);
        _ = c.LLVMBuildStore(l.b, l.constI64(1), cc_ptr);

        const top_ptr = try fc.fsFieldPtr(offs.exc_top, span);
        const top = c.LLVMBuildLoad2(l.b, l.ty_ptr, top_ptr, "");
        const is_null = c.LLVMBuildICmp(l.b, .eq, top, c.LLVMConstPointerNull(l.ty_ptr), "");
        const die = fc.newBlock("throw.uncaught");
        const jmp = fc.newBlock("throw.unwind");
        fc.condBr(is_null, die, jmp);

        // Uncaught: the Go runtime propagated the throw out of @entry and
        // the trampoline returned 0, so an uncaught throw exits successfully
        // and silently. Replicate that.
        fc.position(die);
        var exit_params = [_]*c.Type{l.ty_i32};
        const exit_fn = try l.libcFn("exit", l.ty_void, &exit_params, false);
        var exit_args = [_]*c.Value{l.constI32(0)};
        _ = l.callLib(exit_fn, &exit_args);
        _ = c.LLVMBuildUnreachable(l.b);

        fc.position(jmp);
        const lj = try l.longjmpFn();
        var lj_args = [_]*c.Value{ top, l.constI32(1) };
        _ = l.callLib(lj, &lj_args);
        _ = c.LLVMBuildUnreachable(l.b);
        fc.terminated = true;
    }

    // ---- expressions ----

    /// e's machine type from its checked AST type (the Go exprTy).
    fn vtyOf(e: *const ast.Expr) VTy {
        const t = e.ty orelse return .i64_;
        return scalarVTy(t) orelse .i64_;
    }

    /// Lowers e to an i1 condition (the Go lowerCond): a top-level
    /// comparison compares at the promoted width with the operands'
    /// signedness; anything else is `!= 0`.
    fn lowerCond(fc: *FnCtx, e: *ast.Expr) Error!*c.Value {
        switch (e.kind) {
            .binary => |k| {
                if (isCmpOp(k.op) and !isPtrLike(k.lhs) and !isPtrLike(k.rhs)) {
                    const vt = promoted(k.lhs, k.rhs);
                    const signed = signedRel(k.lhs, k.rhs);
                    const a = fc.coerce(try fc.lowerExpr(k.lhs), vt);
                    const b = fc.coerce(try fc.lowerExpr(k.rhs), vt);
                    return fc.buildCmp(k.op, vt, signed, a.v, b.v);
                }
            },
            else => {},
        }
        const v = try fc.lowerExpr(e);
        return fc.nonZero(v);
    }

    fn nonZero(fc: *FnCtx, tv: TV) *c.Value {
        const l = fc.l;
        return switch (tv.ty) {
            .f64_ => c.LLVMBuildFCmp(l.b, .une, tv.v, c.LLVMConstReal(l.ty_f64, 0), ""),
            .ptr_ => c.LLVMBuildICmp(l.b, .ne, tv.v, c.LLVMConstPointerNull(l.ty_ptr), ""),
            else => c.LLVMBuildICmp(l.b, .ne, tv.v, c.LLVMConstInt(l.llvmTy(tv.ty), 0, 0), ""),
        };
    }

    fn buildCmp(fc: *FnCtx, op: ast.BinOp, vt: VTy, signed: bool, a: *c.Value, b: *c.Value) *c.Value {
        const l = fc.l;
        if (vt == .f64_) {
            const pred: c.RealPredicate = switch (op) {
                .eq => .oeq,
                .ne => .une,
                .lt => .olt,
                .le => .ole,
                .gt => .ogt,
                .ge => .oge,
                else => unreachable,
            };
            return c.LLVMBuildFCmp(l.b, pred, a, b, "");
        }
        const pred: c.IntPredicate = switch (op) {
            .eq => .eq,
            .ne => .ne,
            .lt => if (signed) .slt else .ult,
            .le => if (signed) .sle else .ule,
            .gt => if (signed) .sgt else .ugt,
            .ge => if (signed) .sge else .uge,
            else => unreachable,
        };
        return c.LLVMBuildICmp(l.b, pred, a, b, "");
    }

    fn boolToI64(fc: *FnCtx, v: *c.Value) TV {
        return .{ .v = c.LLVMBuildZExt(fc.l.b, v, fc.l.ty_i64, ""), .ty = .i64_ };
    }

    fn lowerExpr(fc: *FnCtx, e: *ast.Expr) Error!TV {
        const l = fc.l;
        switch (e.kind) {
            .int_lit => |v| return l.constInt(vtyOf(e), v),
            .char_lit => |v| return l.constInt(vtyOf(e), v),
            .float_lit => |v| return .{ .v = c.LLVMConstReal(l.ty_f64, v), .ty = .f64_ },
            .str_lit => |s| return .{ .v = try l.internString(s), .ty = .ptr_ },
            .lastclass => {
                // Outside a default-argument position there is no preceding
                // argument: the empty string. The default-fill path supplies
                // the real class name per call site.
                return .{ .v = try l.internString(""), .ty = .ptr_ };
            },
            .ident, .index, .member => return fc.lowerLvalueRvalue(e),
            .unary => |k| {
                if (k.op == .deref) {
                    // Dereferencing a function pointer is a no-op: *fp names
                    // the same callable pointer.
                    if (e.ty) |t| {
                        if (t == .func_ptr) return fc.lowerExpr(k.expr);
                    }
                    return fc.lowerLvalueRvalue(e);
                }
                return fc.lowerUnary(k.op, k.expr, e);
            },
            .postfix => |k| return fc.lowerPostfix(k.op, k.expr),
            .binary => |k| return fc.lowerBinary(k.op, k.lhs, k.rhs, e),
            .assign => |k| return fc.lowerAssign(k.op, k.target, k.value),
            .call => |k| return fc.lowerCall(k.callee, k.args, e),
            .cast => |k| {
                const v = try fc.lowerExpr(k.expr);
                return fc.coerceToAst(v, k.ty, e.span);
            },
            .sizeof => |k| {
                var sz: u64 = 0;
                if (k.ty) |t| {
                    sz = l.layouts.sizeOf(t);
                } else if (k.expr) |sub| {
                    const t = sub.ty orelse return l.failAt(e.span, "sizeof of an untyped expression", .{});
                    sz = l.layouts.sizeOf(t);
                }
                return l.constInt(.i64_, @intCast(sz));
            },
            .offset => |k| {
                const off = l.layouts.nestedOffsetOf(k.class, k.path) orelse
                    return l.failAt(e.span, "offset of unknown member", .{});
                return l.constInt(.i64_, @intCast(off));
            },
            .comma => |exprs| {
                var last = l.constInt(.i64_, 0);
                for (exprs) |sub| last = try fc.lowerExpr(sub);
                return last;
            },
            .init_list, .designated_init => return l.failAt(e.span, "aggregate literal in a scalar context", .{}),
        }
    }

    fn lowerLvalueRvalue(fc: *FnCtx, e: *ast.Expr) Error!TV {
        const l = fc.l;
        switch (e.kind) {
            .ident => |name| {
                if (fc.lookup(name) == null) {
                    if (l.sigs.contains(name)) {
                        // A bare function name is a zero-argument call.
                        return fc.lowerNamedCall(name, &.{}, e.span);
                    }
                }
            },
            else => {},
        }
        const lv = try fc.lowerLvalue(e);
        switch (lv.ty) {
            .array => return .{ .v = lv.addr, .ty = .ptr_ }, // array decays to its data pointer
            .named => return l.failAt(e.span, "aggregate value in a scalar context", .{}),
            else => return fc.loadLvalue(lv, e.span),
        }
    }

    fn lowerUnary(fc: *FnCtx, op: ast.UnOp, expr: *ast.Expr, whole: *ast.Expr) Error!TV {
        const l = fc.l;
        switch (op) {
            .pos => return fc.lowerExpr(expr),
            .neg => {
                const v = try fc.lowerExpr(expr);
                if (v.ty.isFloat()) {
                    return .{ .v = c.LLVMBuildFNeg(l.b, v.v, ""), .ty = .f64_ };
                }
                const w = fc.coerce(v, .i64_);
                return .{ .v = c.LLVMBuildNeg(l.b, w.v, ""), .ty = .i64_ };
            },
            .bit_not => {
                const v = fc.coerce(try fc.lowerExpr(expr), .i64_);
                return .{ .v = c.LLVMBuildNot(l.b, v.v, ""), .ty = .i64_ };
            },
            .not => {
                const v = try fc.lowerExpr(expr);
                const zero_cmp = switch (v.ty) {
                    .f64_ => c.LLVMBuildFCmp(l.b, .oeq, v.v, c.LLVMConstReal(l.ty_f64, 0), ""),
                    .ptr_ => c.LLVMBuildICmp(l.b, .eq, v.v, c.LLVMConstPointerNull(l.ty_ptr), ""),
                    else => c.LLVMBuildICmp(l.b, .eq, v.v, c.LLVMConstInt(l.llvmTy(v.ty), 0, 0), ""),
                };
                return fc.boolToI64(zero_cmp);
            },
            .addr_of => {
                switch (expr.kind) {
                    .ident => |name| {
                        if (fc.lookup(name) == null) {
                            if (l.sigs.getPtr(name)) |sig| {
                                const f = try l.fnValue(name, sig);
                                return .{ .v = f.value, .ty = .ptr_ };
                            }
                        }
                    },
                    else => {},
                }
                const lv = try fc.lowerLvalue(expr);
                return .{ .v = lv.addr, .ty = .ptr_ };
            },
            .pre_inc, .pre_dec => {
                const lv = try fc.lowerLvalue(expr);
                if (fc.lockAtomicIncDec(lv, op == .pre_inc)) |pair| return pair.new;
                const old = try fc.loadLvalue(lv, whole.span);
                const nv = fc.incDec(old, op == .pre_inc, lv);
                fc.storeLvalue(lv, nv);
                return nv;
            },
            .deref => unreachable, // handled by lowerLvalueRvalue
        }
    }

    fn lowerPostfix(fc: *FnCtx, op: ast.PostOp, expr: *ast.Expr) Error!TV {
        const lv = try fc.lowerLvalue(expr);
        if (fc.lockAtomicIncDec(lv, op == .inc)) |pair| return pair.old;
        const old = try fc.loadLvalue(lv, expr.span);
        const nv = fc.incDec(old, op == .inc, lv);
        fc.storeLvalue(lv, nv);
        return old;
    }

    /// Inside a lock block, ++/-- on an integer scalar lvalue is one atomic
    /// add (the LOCK INC/DEC of TempleOS). Returns null when the operation is
    /// not atomicizable (outside lock, pointers, floats), leaving the plain
    /// load/op/store path to handle it.
    fn lockAtomicIncDec(fc: *FnCtx, lv: Lvalue, inc: bool) ?struct { old: TV, new: TV } {
        const l = fc.l;
        if (fc.lock_depth == 0) return null;
        const w = scalarVTy(lv.ty) orelse return null;
        if (w == .ptr_ or w.isFloat()) return null;
        const wty = l.llvmTy(w);
        const delta = c.LLVMConstInt(wty, if (inc) 1 else @bitCast(@as(u64, @bitCast(@as(i64, -1)))), 1);
        const old = c.LLVMBuildAtomicRMW(l.b, .add, lv.addr, delta, .seq_cst, 0);
        const new = c.LLVMBuildAdd(l.b, old, delta, "");
        return .{ .old = .{ .v = old, .ty = w }, .new = .{ .v = new, .ty = w } };
    }

    /// Inside a lock block, `+= -= &= |= ^=` on an integer scalar lvalue is
    /// one atomic read-modify-write (the LOCK-prefixable x86 ops; shifts,
    /// mul, div, and floats were never LOCK-able and stay non-atomic).
    /// Returns the stored (new) value, or null when not atomicizable.
    fn lockAtomicCompound(fc: *FnCtx, lv: Lvalue, op: ast.AssignOp, rv: TV) ?TV {
        const l = fc.l;
        if (fc.lock_depth == 0) return null;
        const w = scalarVTy(lv.ty) orelse return null;
        if (w == .ptr_ or w.isFloat()) return null;
        const rmw: c.AtomicRMWBinOp = switch (op) {
            .add => .add,
            .sub => .sub,
            .bit_and => .@"and",
            .bit_or => .@"or",
            .bit_xor => .xor,
            else => return null,
        };
        const d = fc.coerce(rv, w);
        const old = c.LLVMBuildAtomicRMW(l.b, rmw, lv.addr, d.v, .seq_cst, 0);
        const new = switch (rmw) {
            .add => c.LLVMBuildAdd(l.b, old, d.v, ""),
            .sub => c.LLVMBuildSub(l.b, old, d.v, ""),
            .@"and" => c.LLVMBuildAnd(l.b, old, d.v, ""),
            .@"or" => c.LLVMBuildOr(l.b, old, d.v, ""),
            else => c.LLVMBuildXor(l.b, old, d.v, ""),
        };
        return .{ .v = new, .ty = w };
    }

    fn incDec(fc: *FnCtx, old: TV, inc: bool, lv: Lvalue) TV {
        const l = fc.l;
        if (old.ty == .ptr_) {
            var stride: i64 = 1;
            if (derefTy(lv.ty)) |elem| stride = @intCast(l.layouts.strideOf(elem));
            const step: i64 = if (inc) stride else -stride;
            return .{ .v = l.gepByteV(old.v, l.constI64(step)), .ty = .ptr_ };
        }
        if (old.ty.isFloat()) {
            const one = c.LLVMConstReal(l.ty_f64, 1);
            const v = if (inc)
                c.LLVMBuildFAdd(l.b, old.v, one, "")
            else
                c.LLVMBuildFSub(l.b, old.v, one, "");
            return .{ .v = v, .ty = .f64_ };
        }
        const wide = fc.coerce(old, .i64_);
        const one = l.constI64(1);
        const v = if (inc)
            c.LLVMBuildAdd(l.b, wide.v, one, "")
        else
            c.LLVMBuildSub(l.b, wide.v, one, "");
        return fc.coerce(.{ .v = v, .ty = .i64_ }, old.ty);
    }

    fn buildBin(fc: *FnCtx, op: ast.BinOp, vt: VTy, signed: bool, a: *c.Value, b: *c.Value, span: source.Span) Error!*c.Value {
        const l = fc.l;
        if (vt == .f64_) {
            return switch (op) {
                .add => c.LLVMBuildFAdd(l.b, a, b, ""),
                .sub => c.LLVMBuildFSub(l.b, a, b, ""),
                .mul => c.LLVMBuildFMul(l.b, a, b, ""),
                .div => c.LLVMBuildFDiv(l.b, a, b, ""),
                .mod => c.LLVMBuildFRem(l.b, a, b, ""),
                else => l.failAt(span, "operator `{s}` is not defined for F64", .{op.spelling()}),
            };
        }
        return switch (op) {
            .add => c.LLVMBuildAdd(l.b, a, b, ""),
            .sub => c.LLVMBuildSub(l.b, a, b, ""),
            .mul => c.LLVMBuildMul(l.b, a, b, ""),
            .div => if (signed) c.LLVMBuildSDiv(l.b, a, b, "") else c.LLVMBuildUDiv(l.b, a, b, ""),
            .mod => if (signed) c.LLVMBuildSRem(l.b, a, b, "") else c.LLVMBuildURem(l.b, a, b, ""),
            .bit_and => c.LLVMBuildAnd(l.b, a, b, ""),
            .bit_or => c.LLVMBuildOr(l.b, a, b, ""),
            .bit_xor => c.LLVMBuildXor(l.b, a, b, ""),
            .shl => c.LLVMBuildShl(l.b, a, b, ""),
            .shr => if (signed) c.LLVMBuildAShr(l.b, a, b, "") else c.LLVMBuildLShr(l.b, a, b, ""),
            else => l.failAt(span, "binary operator `{s}` not lowered", .{op.spelling()}),
        };
    }

    fn lowerBinary(fc: *FnCtx, op: ast.BinOp, lhs: *ast.Expr, rhs: *ast.Expr, whole: *ast.Expr) Error!TV {
        if (op == .log_and or op == .log_or) return fc.lowerLogical(op, lhs, rhs);
        if (op == .log_xor) return fc.lowerLogXor(lhs, rhs);
        if (op == .pow) return fc.lowerPow(lhs, rhs);
        const lptr = isPtrLike(lhs);
        const rptr = isPtrLike(rhs);
        if ((lptr or rptr) and (op == .add or op == .sub)) {
            return fc.lowerPtrArith(op, lhs, rhs, lptr, rptr);
        }
        if (isCmpOp(op)) {
            if (lptr or rptr) {
                const a = try fc.lowerPtrValue(lhs);
                const b = try fc.lowerPtrValue(rhs);
                const cmp = fc.buildCmp(op, .ptr_, false, a, b);
                return fc.boolToI64(cmp);
            }
            const vt = promoted(lhs, rhs);
            const signed = signedRel(lhs, rhs);
            const a = fc.coerce(try fc.lowerExpr(lhs), vt);
            const b = fc.coerce(try fc.lowerExpr(rhs), vt);
            return fc.boolToI64(fc.buildCmp(op, vt, signed, a.v, b.v));
        }
        const vt = promoted(lhs, rhs);
        const signed = signedLeft(lhs);
        const a = fc.coerce(try fc.lowerExpr(lhs), vt);
        const b = fc.coerce(try fc.lowerExpr(rhs), vt);
        const v = try fc.buildBin(op, vt, signed, a.v, b.v, whole.span);
        return .{ .v = v, .ty = vt };
    }

    fn lowerPtrArith(fc: *FnCtx, op: ast.BinOp, lhs: *ast.Expr, rhs: *ast.Expr, lptr: bool, rptr: bool) Error!TV {
        const l = fc.l;
        if (op == .sub and lptr and rptr) {
            // Pointer difference: byte difference divided by the stride.
            var stride: i64 = 1;
            if (lhs.ty) |t| {
                if (derefTy(t)) |elem| stride = @intCast(l.layouts.strideOf(elem));
            }
            if (stride < 1) stride = 1;
            const a = try fc.lowerPtrValue(lhs);
            const b = try fc.lowerPtrValue(rhs);
            const ai = c.LLVMBuildPtrToInt(l.b, a, l.ty_i64, "");
            const bi = c.LLVMBuildPtrToInt(l.b, b, l.ty_i64, "");
            const diff = c.LLVMBuildSub(l.b, ai, bi, "");
            const res = c.LLVMBuildSDiv(l.b, diff, l.constI64(stride), "");
            return .{ .v = res, .ty = .i64_ };
        }
        var ptr_e = lhs;
        var int_e = rhs;
        if (!lptr) {
            ptr_e = rhs;
            int_e = lhs;
        }
        var stride: u64 = 1;
        if (ptr_e.ty) |t| {
            if (derefTy(t)) |elem| stride = l.layouts.strideOf(elem);
        }
        const p = try fc.lowerPtrValue(ptr_e);
        var i = fc.coerce(try fc.lowerExpr(int_e), .i64_);
        if (op == .sub) {
            i = .{ .v = c.LLVMBuildNeg(l.b, i.v, ""), .ty = .i64_ };
        }
        return .{ .v = l.gepScaled(p, i.v, stride), .ty = .ptr_ };
    }

    fn lowerPtrValue(fc: *FnCtx, e: *ast.Expr) Error!*c.Value {
        const v = try fc.lowerExpr(e);
        return fc.coerce(v, .ptr_).v;
    }

    /// Short-circuit && / ||, yielding I64 0/1 through a phi.
    fn lowerLogical(fc: *FnCtx, op: ast.BinOp, lhs: *ast.Expr, rhs: *ast.Expr) Error!TV {
        const l = fc.l;
        const rhs_b = fc.newBlock("log.rhs");
        const short_b = fc.newBlock("log.short");
        const join = fc.newBlock("log.join");

        const cv = try fc.lowerCond(lhs);
        if (op == .log_and) {
            fc.condBr(cv, rhs_b, short_b);
        } else {
            fc.condBr(cv, short_b, rhs_b);
        }

        fc.position(short_b);
        const short_val = l.constI64(if (op == .log_and) 0 else 1);
        fc.br(join);

        fc.position(rhs_b);
        const rv = try fc.lowerExpr(rhs);
        const norm = fc.boolToI64(fc.nonZero(rv));
        const rhs_end = fc.curBlock();
        fc.br(join);

        fc.position(join);
        const phi = c.LLVMBuildPhi(l.b, l.ty_i64, "");
        var vals = [_]*c.Value{ short_val, norm.v };
        var blocks = [_]*c.BasicBlock{ short_b, rhs_end };
        c.LLVMAddIncoming(phi, &vals, &blocks, 2);
        return .{ .v = phi, .ty = .i64_ };
    }

    /// `a ^^ b`: both sides evaluated (no short-circuit), normalized to 0/1,
    /// XORed.
    fn lowerLogXor(fc: *FnCtx, lhs: *ast.Expr, rhs: *ast.Expr) Error!TV {
        const l = fc.l;
        const a = fc.boolToI64(fc.nonZero(try fc.lowerExpr(lhs)));
        const b = fc.boolToI64(fc.nonZero(try fc.lowerExpr(rhs)));
        return .{ .v = c.LLVMBuildXor(l.b, a.v, b.v, ""), .ty = .i64_ };
    }

    /// HolyC backtick exponentiation: both operands to F64, llvm.pow.f64.
    fn lowerPow(fc: *FnCtx, lhs: *ast.Expr, rhs: *ast.Expr) Error!TV {
        const l = fc.l;
        const a = fc.coerce(try fc.lowerExpr(lhs), .f64_);
        const b = fc.coerce(try fc.lowerExpr(rhs), .f64_);
        var params = [_]*c.Type{ l.ty_f64, l.ty_f64 };
        const pow_fn = try l.libcFn("llvm.pow.f64", l.ty_f64, &params, false);
        var args = [_]*c.Value{ a.v, b.v };
        return .{ .v = l.callLib(pow_fn, &args), .ty = .f64_ };
    }

    fn lowerAssign(fc: *FnCtx, op: ast.AssignOp, tgt: *ast.Expr, value: *ast.Expr) Error!TV {
        const l = fc.l;
        if (tgt.ty) |tty| {
            if (tty.isAggregate()) {
                if (op != .assign) {
                    return l.failAt(tgt.span, "compound assignment on an aggregate", .{});
                }
                const dst = try fc.lowerAggregateAddr(tgt);
                const src = try fc.lowerAggregateAddr(value);
                l.memCpy(dst, src, l.layouts.sizeOf(tty));
                return .{ .v = dst, .ty = .ptr_ };
            }
        }

        const lv = try fc.lowerLvalue(tgt);
        if (op == .assign) {
            const v = try fc.lowerExpr(value);
            const cv = try fc.coerceToAst(v, lv.ty, value.span);
            fc.storeLvalue(lv, cv);
            return cv;
        }

        const target_vt = scalarVTy(lv.ty) orelse .i64_;
        if (target_vt == .ptr_ and (op == .add or op == .sub)) {
            const old = try fc.loadLvalue(lv, tgt.span);
            var stride: u64 = 1;
            if (derefTy(lv.ty)) |elem| stride = l.layouts.strideOf(elem);
            var i = fc.coerce(try fc.lowerExpr(value), .i64_);
            if (op == .sub) {
                i = .{ .v = c.LLVMBuildNeg(l.b, i.v, ""), .ty = .i64_ };
            }
            const nv = TV{ .v = l.gepScaled(old.v, i.v, stride), .ty = .ptr_ };
            fc.storeLvalue(lv, nv);
            return nv;
        }

        // Inside lock{}, the LOCK-prefixable compound ops become one atomic
        // read-modify-write (value evaluated first, non-atomically).
        if (fc.lock_depth > 0 and !exprIsF64(value)) {
            switch (op) {
                .add, .sub, .bit_and, .bit_or, .bit_xor => {
                    const rv0 = try fc.lowerExpr(value);
                    if (fc.lockAtomicCompound(lv, op, rv0)) |nv| return nv;
                    // Not atomicizable (pointer/float target): fall through
                    // by finishing the plain path with the value we lowered.
                    var pty0: VTy = .i64_;
                    if (target_vt.isFloat()) pty0 = .f64_;
                    const old0 = fc.coerce(try fc.loadLvalue(lv, tgt.span), pty0);
                    const rvp = fc.coerce(rv0, pty0);
                    const bop0: ast.BinOp = switch (op) {
                        .add => .add,
                        .sub => .sub,
                        .bit_and => .bit_and,
                        .bit_or => .bit_or,
                        else => .bit_xor,
                    };
                    const v0 = try fc.buildBin(bop0, pty0, signedLeft(tgt), old0.v, rvp.v, tgt.span);
                    const res0 = fc.coerce(.{ .v = v0, .ty = pty0 }, target_vt);
                    fc.storeLvalue(lv, res0);
                    return res0;
                },
                else => {},
            }
        }

        // Compound assignment: promote to I64/F64, operate, truncate back.
        var pty: VTy = .i64_;
        if (target_vt.isFloat() or exprIsF64(value)) pty = .f64_;
        const old = fc.coerce(try fc.loadLvalue(lv, tgt.span), pty);
        const rv = fc.coerce(try fc.lowerExpr(value), pty);
        const bop: ast.BinOp = switch (op) {
            .add => .add,
            .sub => .sub,
            .mul => .mul,
            .div => .div,
            .mod => .mod,
            .bit_and => .bit_and,
            .bit_or => .bit_or,
            .bit_xor => .bit_xor,
            .shl => .shl,
            .shr => .shr,
            .assign => unreachable,
        };
        const v = try fc.buildBin(bop, pty, signedLeft(tgt), old.v, rv.v, tgt.span);
        const res = fc.coerce(.{ .v = v, .ty = pty }, target_vt);
        fc.storeLvalue(lv, res);
        return res;
    }

    // ---- lvalues ----

    fn lowerLvalue(fc: *FnCtx, e: *ast.Expr) Error!Lvalue {
        const l = fc.l;
        switch (e.kind) {
            .ident => |name| {
                if (fc.lookup(name)) |info| {
                    var addr = info.addr;
                    if (info.indirect) {
                        addr = c.LLVMBuildLoad2(l.b, l.ty_ptr, addr, "");
                    }
                    return .{ .addr = addr, .ty = info.ty };
                }
                if (l.globals.get(name)) |g| {
                    return .{ .addr = g.value, .ty = g.ty };
                }
                return l.failAt(e.span, "unknown identifier `{s}`", .{name});
            },
            .unary => |k| {
                if (k.op != .deref) {
                    return l.failAt(e.span, "expression is not an lvalue", .{});
                }
                const bt = k.expr.ty orelse prim_i64;
                const pointee = derefTy(bt) orelse return l.failAt(e.span, "dereference of a non-pointer", .{});
                const addr = try fc.lowerPtrValue(k.expr);
                return .{ .addr = addr, .ty = pointee };
            },
            .index => |k| {
                const bt = k.base.ty orelse prim_i64;
                const elem = derefTy(bt) orelse return l.failAt(e.span, "indexing a non-array/pointer", .{});
                const base_addr = try fc.arrayOrPtrBase(k.base);
                const idx = fc.coerce(try fc.lowerExpr(k.index), .i64_);
                const stride = l.layouts.strideOf(elem);
                return .{ .addr = l.gepScaled(base_addr, idx.v, stride), .ty = elem };
            },
            .member => |k| {
                var base_addr: *c.Value = undefined;
                var class: []const u8 = undefined;
                if (k.arrow) {
                    const bt = k.base.ty orelse prim_i64;
                    const inner = derefTy(bt) orelse return l.failAt(e.span, "-> on a non-pointer", .{});
                    base_addr = try fc.lowerPtrValue(k.base);
                    class = className(inner) orelse return l.failAt(e.span, "member access on a non-class", .{});
                } else {
                    const bt = k.base.ty orelse prim_i64;
                    base_addr = try fc.lowerAggregateAddr(k.base);
                    class = className(bt) orelse return l.failAt(e.span, "member access on a non-class", .{});
                }
                const lay = l.layouts.get(class) orelse return l.failAt(e.span, "unknown class `{s}`", .{class});
                const f = lay.field(k.field) orelse return l.failAt(e.span, "unknown field `{s}`", .{k.field});
                return .{ .addr = l.gepByte(base_addr, f.offset), .ty = f.ty };
            },
            else => return l.failAt(e.span, "expression is not an lvalue", .{}),
        }
    }

    fn arrayOrPtrBase(fc: *FnCtx, base: *ast.Expr) Error!*c.Value {
        if (base.ty) |t| {
            if (t == .array) {
                const lv = try fc.lowerLvalue(base);
                return lv.addr;
            }
        }
        return fc.lowerPtrValue(base);
    }

    fn lowerAggregateAddr(fc: *FnCtx, e: *ast.Expr) Error!*c.Value {
        const l = fc.l;
        switch (e.kind) {
            .call => {
                const v = try fc.lowerExpr(e);
                return v.v;
            },
            .init_list, .designated_init => {
                const ty = e.ty orelse return l.failAt(e.span, "untyped aggregate literal", .{});
                const size = l.layouts.sizeOf(ty);
                const slot = fc.allocaBytes(size, l.layouts.alignOf(ty), "agg.tmp");
                l.memZero(slot, size);
                try fc.lowerInitInto(slot, ty, e);
                return slot;
            },
            else => {
                const lv = try fc.lowerLvalue(e);
                return lv.addr;
            },
        }
    }

    // ---- calls ----

    fn lowerCall(fc: *FnCtx, callee: *ast.Expr, args: []const ?*ast.Expr, whole: *ast.Expr) Error!TV {
        const l = fc.l;
        switch (callee.kind) {
            .ident => |name| {
                const is_local = fc.lookup(name) != null;
                const is_global = l.globals.contains(name);
                if (!is_local and !is_global) {
                    return fc.lowerNamedCall(name, args, whole.span);
                }
            },
            else => {},
        }
        return fc.lowerIndirectCall(callee, args, whole.span);
    }

    fn lowerIndirectCall(fc: *FnCtx, callee: *ast.Expr, args: []const ?*ast.Expr, span: source.Span) Error!TV {
        const l = fc.l;
        const cty = callee.ty orelse return l.failAt(span, "indirect call on an untyped callee", .{});
        const fp = switch (cty) {
            .func_ptr => |fp| fp,
            else => return l.failAt(span, "indirect call on a non-function-pointer", .{}),
        };
        const callee_v = try fc.lowerPtrValue(callee);

        var param_tys: std.ArrayList(*c.Type) = .empty;
        var call_args: std.ArrayList(*c.Value) = .empty;
        var ret_ty: *c.Type = l.ty_void;
        var sret: ?*c.Value = null;
        var ret_scalar: ?VTy = null;
        if (!isVoidTy(fp.ret.*)) {
            if (fp.ret.isAggregate()) {
                sret = fc.allocaBytes(l.layouts.sizeOf(fp.ret.*), l.layouts.alignOf(fp.ret.*), "sret");
                try param_tys.append(l.arena, l.ty_ptr);
                try call_args.append(l.arena, sret.?);
            } else {
                ret_scalar = scalarVTy(fp.ret.*) orelse .i64_;
                ret_ty = l.llvmTy(ret_scalar.?);
            }
        }
        for (args, 0..) |arg, i| {
            const a = arg orelse return l.failAt(span, "a skipped argument is only allowed when calling a named function", .{});
            if (i < fp.params.len) {
                const av = try fc.lowerFixedArg(a, fp.params[i], span);
                try param_tys.append(l.arena, c.LLVMTypeOf(av));
                try call_args.append(l.arena, av);
            } else {
                // Extra arguments beyond the declared parameters are passed
                // by value class (the Go lowering did the same).
                const v = try fc.lowerExpr(a);
                const av = switch (v.ty) {
                    .f64_, .ptr_ => v,
                    else => fc.coerce(v, .i64_),
                };
                try param_tys.append(l.arena, c.LLVMTypeOf(av.v));
                try call_args.append(l.arena, av.v);
            }
        }
        const fn_ty = c.LLVMFunctionType(ret_ty, if (param_tys.items.len == 0) null else param_tys.items.ptr, @intCast(param_tys.items.len), 0);
        const cv = c.LLVMBuildCall2(l.b, fn_ty, callee_v, if (call_args.items.len == 0) null else call_args.items.ptr, @intCast(call_args.items.len), "");
        if (sret) |s| return .{ .v = s, .ty = .ptr_ };
        if (ret_scalar) |vt| return .{ .v = cv, .ty = vt };
        return l.constInt(.i64_, 0);
    }

    /// The class name a `lastclass` default resolves to: the named type the
    /// preceding argument is, or points to; "" otherwise.
    fn lastClassName(i: usize, args: []const ?*ast.Expr, params: []const ast.Param) []const u8 {
        if (i == 0) return "";
        var prev: ?ast.Type = null;
        if (i - 1 < args.len) {
            if (args[i - 1]) |a| {
                if (a.ty) |t| prev = t;
            }
        }
        if (prev == null and i - 1 < params.len) prev = params[i - 1].ty;
        var t = prev orelse return "";
        if (t == .ptr) t = t.ptr.*;
        return className(t) orelse "";
    }

    fn lowerFixedArg(fc: *FnCtx, a: *ast.Expr, pty: ast.Type, span: source.Span) Error!*c.Value {
        const l = fc.l;
        if (pty == .array) {
            return fc.lowerPtrValue(a);
        }
        if (pty.isAggregate()) {
            return fc.lowerAggregateAddr(a);
        }
        const v = try fc.lowerExpr(a);
        const vt = scalarVTy(pty) orelse return l.failAt(span, "non-scalar argument not lowered", .{});
        return fc.coerce(v, vt).v;
    }

    /// Binds a resolved parameter value in the temporary default-evaluation
    /// scope, so a later default may reference an earlier parameter.
    fn bindParamValue(fc: *FnCtx, name: []const u8, ty: ast.Type, value: *c.Value) Error!void {
        if (name.len == 0) return;
        if (ty.isAggregate()) return;
        const l = fc.l;
        const vt = scalarVTy(ty) orelse .i64_;
        const slot = fc.allocaTy(l.llvmTy(vt), name);
        _ = c.LLVMBuildStore(l.b, value, slot);
        try fc.bind(name, .{ .ty = ty, .addr = slot });
    }

    fn lowerNamedCall(fc: *FnCtx, name: []const u8, args: []const ?*ast.Expr, span: source.Span) Error!TV {
        const l = fc.l;
        const sig = l.sigs.getPtr(name);
        const defined = sig != null and sig.?.has_body;
        if (!defined) {
            if (prim_names.get(name)) |pk| {
                return fc.emitPrim(pk, args, span);
            }
        }
        const s = sig orelse return l.failAt(span, "unknown function `{s}`", .{name});

        const params = s.def.params;
        const fixed = @min(params.len, args.len);

        // Resolve the declared parameters: supplied arguments in the
        // caller's scope; skipped/omitted positions from the parameter's
        // default, evaluated in a callee scope where the other parameters
        // are bound.
        const resolved = try l.arena.alloc(?*c.Value, params.len);
        @memset(resolved, null);
        for (0..fixed) |i| {
            const a = args[i] orelse continue; // skipped: filled from the default below
            resolved[i] = try fc.lowerFixedArg(a, params[i].ty, span);
        }
        var need_defaults = false;
        for (resolved) |r| {
            if (r == null) need_defaults = true;
        }
        if (need_defaults) {
            const saved = fc.scopes;
            fc.scopes = .empty;
            try fc.pushScope();
            var default_err: ?Error = null;
            for (params, 0..) |p, i| {
                if (resolved[i] == null) {
                    var dflt = p.default_value orelse {
                        default_err = l.failAt(span, "missing argument with no default", .{});
                        break;
                    };
                    if (dflt.kind == .lastclass) {
                        // `lastclass` resolves, per call site, to the class
                        // name of the preceding argument.
                        const synth = try l.arena.create(ast.Expr);
                        synth.* = .{
                            .kind = .{ .str_lit = lastClassName(i, args, params) },
                            .span = dflt.span,
                            .ty = ty_u8_ptr,
                        };
                        dflt = synth;
                    }
                    resolved[i] = fc.lowerFixedArg(dflt, p.ty, span) catch |e| {
                        default_err = e;
                        break;
                    };
                }
                fc.bindParamValue(p.name, p.ty, resolved[i].?) catch |e| {
                    default_err = e;
                    break;
                };
            }
            fc.scopes = saved;
            if (default_err) |e| return e;
        }

        var call_args: std.ArrayList(*c.Value) = .empty;
        var sret: ?*c.Value = null;
        const ret_agg = !isVoidTy(s.def.ret) and s.def.ret.isAggregate();
        if (ret_agg) {
            sret = fc.allocaBytes(l.layouts.sizeOf(s.def.ret), l.layouts.alignOf(s.def.ret), "sret");
            try call_args.append(l.arena, sret.?);
        }
        for (resolved) |r| try call_args.append(l.arena, r.?);

        const is_varargs = s.def.varargs;
        if (is_varargs and s.def.import) {
            // A C-ABI variadic import (e.g. printf): pass the variadic
            // arguments per the platform C ABI, not through argc/argv.
            for (args[fixed..]) |arg| {
                const a = arg orelse return l.failAt(span, "a skipped argument is not allowed in a variadic argument position", .{});
                const v = try fc.lowerExpr(a);
                const av = switch (v.ty) {
                    .f64_, .ptr_ => v,
                    else => fc.coerce(v, .i64_),
                };
                try call_args.append(l.arena, av.v);
            }
        } else if (is_varargs) {
            // HolyC varargs: box each extra argument into an 8-byte cell of
            // a stack buffer, pass (count, buffer).
            const var_args = args[fixed..];
            const n = var_args.len;
            const buf = fc.allocaBytes(@max(8 * n, 8), 8, "varargs");
            for (var_args, 0..) |arg, k| {
                const a = arg orelse return l.failAt(span, "a skipped argument is not allowed in a variadic argument position", .{});
                const v = try fc.lowerExpr(a);
                const at = l.gepByte(buf, 8 * @as(u64, k));
                const sv = switch (v.ty) {
                    .f64_, .ptr_ => v,
                    else => fc.coerce(v, .i64_),
                };
                _ = c.LLVMBuildStore(l.b, sv.v, at);
            }
            try call_args.append(l.arena, l.constI64(@intCast(n)));
            try call_args.append(l.arena, buf);
        } else if (args.len > fixed) {
            return l.failAt(span, "too many arguments in call to `{s}`", .{name});
        }

        // An `_extern <LABEL> <sig>` binding calls the asm-defined label (an
        // external symbol the standalone block defines) under the HolyC name.
        const callee = if (s.def.asm_label.len > 0) s.def.asm_label else name;
        const f = try l.fnValue(callee, s);
        const cv = c.LLVMBuildCall2(l.b, f.fn_ty, f.value, if (call_args.items.len == 0) null else call_args.items.ptr, @intCast(call_args.items.len), "");
        if (ret_agg) return .{ .v = sret.?, .ty = .ptr_ };
        if (isVoidTy(s.def.ret)) return l.constInt(.i64_, 0);
        return .{ .v = cv, .ty = scalarVTy(s.def.ret) orelse .i64_ };
    }

    // ---- primitives (goref backend/arch runtime, on libc) ----

    fn emitPrim(fc: *FnCtx, pk: PrimKind, args: []const ?*ast.Expr, span: source.Span) Error!TV {
        const l = fc.l;
        var vals: std.ArrayList(TV) = .empty;
        for (args) |arg| {
            const a = arg orelse return l.failAt(span, "a skipped argument is not allowed here", .{});
            try vals.append(l.arena, try fc.lowerExpr(a));
        }
        const darwin = l.tgt.os == .darwin;

        switch (pk) {
            .std_write, .write => {
                if (vals.items.len < 3) return l.failAt(span, "StdWrite/Write expects 3 arguments", .{});
                var params = [_]*c.Type{ l.ty_i32, l.ty_ptr, l.ty_i64 };
                const f = try l.libcFn("write", l.ty_i64, &params, false);
                var a = [_]*c.Value{ fc.coerce(vals.items[0], .i32_).v, fc.coerce(vals.items[1], .ptr_).v, fc.coerce(vals.items[2], .i64_).v };
                return .{ .v = l.callLib(f, &a), .ty = .i64_ };
            },
            .malloc => {
                if (vals.items.len < 1) return l.failAt(span, "MAlloc expects 1 argument", .{});
                var params = [_]*c.Type{l.ty_i64};
                const f = try l.libcFn("malloc", l.ty_ptr, &params, false);
                var a = [_]*c.Value{fc.coerce(vals.items[0], .i64_).v};
                return .{ .v = l.callLib(f, &a), .ty = .ptr_ };
            },
            .free => {
                if (vals.items.len < 1) return l.failAt(span, "Free expects 1 argument", .{});
                var params = [_]*c.Type{l.ty_ptr};
                const f = try l.libcFn("free", l.ty_void, &params, false);
                var a = [_]*c.Value{fc.coerce(vals.items[0], .ptr_).v};
                _ = l.callLib(f, &a);
                return l.constInt(.i64_, 0);
            },
            .msize => {
                if (vals.items.len < 1) return l.failAt(span, "MSize expects 1 argument", .{});
                var params = [_]*c.Type{l.ty_ptr};
                const f = try l.libcFn(if (darwin) "malloc_size" else "malloc_usable_size", l.ty_i64, &params, false);
                var a = [_]*c.Value{fc.coerce(vals.items[0], .ptr_).v};
                return .{ .v = l.callLib(f, &a), .ty = .i64_ };
            },
            .heap_extend => {
                // Contract: grow the last heap block in place, else NULL.
                // libc cannot grow in place, so this is always NULL.
                return .{ .v = c.LLVMConstPointerNull(l.ty_ptr), .ty = .ptr_ };
            },
            .exit, .exit_raw => {
                if (vals.items.len < 1) return l.failAt(span, "Exit expects 1 argument", .{});
                if (pk == .exit) try fc.emitAtexitRun();
                var params = [_]*c.Type{l.ty_i32};
                const f = try l.libcFn(if (pk == .exit) "exit" else "_Exit", l.ty_void, &params, false);
                var a = [_]*c.Value{fc.coerce(vals.items[0], .i32_).v};
                _ = l.callLib(f, &a);
                return l.constInt(.i64_, 0);
            },
            .read => {
                if (vals.items.len < 3) return l.failAt(span, "Read expects 3 arguments", .{});
                var params = [_]*c.Type{ l.ty_i32, l.ty_ptr, l.ty_i64 };
                const f = try l.libcFn("read", l.ty_i64, &params, false);
                var a = [_]*c.Value{ fc.coerce(vals.items[0], .i32_).v, fc.coerce(vals.items[1], .ptr_).v, fc.coerce(vals.items[2], .i64_).v };
                return .{ .v = l.callLib(f, &a), .ty = .i64_ };
            },
            .system => {
                if (vals.items.len < 1) return l.failAt(span, "System expects 1 argument", .{});
                var params = [_]*c.Type{l.ty_ptr};
                const f = try l.libcFn("system", l.ty_i32, &params, false);
                var a = [_]*c.Value{fc.coerce(vals.items[0], .ptr_).v};
                return .{ .v = c.LLVMBuildSExt(l.b, l.callLib(f, &a), l.ty_i64, ""), .ty = .i64_ };
            },
            .getpid, .getppid, .getuid, .getgid => {
                const nm = switch (pk) {
                    .getpid => "getpid",
                    .getppid => "getppid",
                    .getuid => "getuid",
                    else => "getgid",
                };
                const f = try l.libcFn(nm, l.ty_i32, &.{}, false);
                return .{ .v = c.LLVMBuildSExt(l.b, l.callLib(f, &.{}), l.ty_i64, ""), .ty = .i64_ };
            },
            .unix_ns, .nano_ns, .cpu_ns => {
                const clk: i32 = switch (pk) {
                    .unix_ns => 0, // CLOCK_REALTIME (same id on both)
                    .nano_ns => if (darwin) 6 else 1, // CLOCK_MONOTONIC
                    else => if (darwin) 12 else 2, // CLOCK_PROCESS_CPUTIME_ID
                };
                const ts = fc.allocaBytes(16, 8, "ts");
                var params = [_]*c.Type{ l.ty_i32, l.ty_ptr };
                const f = try l.libcFn("clock_gettime", l.ty_i32, &params, false);
                var a = [_]*c.Value{ l.constI32(clk), ts };
                _ = l.callLib(f, &a);
                const sec = c.LLVMBuildLoad2(l.b, l.ty_i64, ts, "");
                const nsec = c.LLVMBuildLoad2(l.b, l.ty_i64, l.gepByte(ts, 8), "");
                const scaled = c.LLVMBuildMul(l.b, sec, l.constI64(1_000_000_000), "");
                return .{ .v = c.LLVMBuildAdd(l.b, scaled, nsec, ""), .ty = .i64_ };
            },
            .sleep => {
                if (vals.items.len < 1) return l.failAt(span, "Sleep expects 1 argument", .{});
                const ns = fc.coerce(vals.items[0], .i64_).v;
                try fc.emitNanosleep(ns);
                return l.constInt(.i64_, 0);
            },
            .open => {
                if (vals.items.len < 2) return l.failAt(span, "Open expects at least 2 arguments", .{});
                const path = fc.coerce(vals.items[0], .ptr_).v;
                const flags = fc.coerce(vals.items[1], .i64_).v;
                var oflags: *c.Value = undefined;
                if (darwin) {
                    // HolyC uses Linux-style open flags; remap the ones
                    // darwin numbers differently.
                    var res = c.LLVMBuildAnd(l.b, flags, l.constI64(3), ""); // access mode
                    const remap = [_][2]i64{ .{ 0x40, 0x200 }, .{ 0x200, 0x400 }, .{ 0x400, 0x8 } }; // O_CREAT O_TRUNC O_APPEND
                    for (remap) |m| {
                        const bit = c.LLVMBuildAnd(l.b, flags, l.constI64(m[0]), "");
                        const is_set = c.LLVMBuildICmp(l.b, .ne, bit, l.constI64(0), "");
                        const with = c.LLVMBuildOr(l.b, res, l.constI64(m[1]), "");
                        res = c.LLVMBuildSelect(l.b, is_set, with, res, "");
                    }
                    oflags = res;
                } else {
                    oflags = flags;
                }
                const oflags32 = c.LLVMBuildTrunc(l.b, oflags, l.ty_i32, "");
                const mode32 = if (vals.items.len >= 3)
                    fc.coerce(vals.items[2], .i32_).v
                else
                    l.constI32(0);
                var params = [_]*c.Type{ l.ty_ptr, l.ty_i32 };
                const f = try l.libcFn("open", l.ty_i32, &params, true); // variadic: the mode
                var a = [_]*c.Value{ path, oflags32, mode32 };
                const r = c.LLVMBuildSExt(l.b, l.callLib(f, &a), l.ty_i64, "");
                return fc.errnoFix(r);
            },
            .lseek => {
                if (vals.items.len < 3) return l.failAt(span, "LSeek expects 3 arguments", .{});
                var params = [_]*c.Type{ l.ty_i32, l.ty_i64, l.ty_i32 };
                const f = try l.libcFn("lseek", l.ty_i64, &params, false);
                var a = [_]*c.Value{ fc.coerce(vals.items[0], .i32_).v, fc.coerce(vals.items[1], .i64_).v, fc.coerce(vals.items[2], .i32_).v };
                return fc.errnoFix(l.callLib(f, &a));
            },
            .close => {
                if (vals.items.len < 1) return l.failAt(span, "Close expects 1 argument", .{});
                var params = [_]*c.Type{l.ty_i32};
                const f = try l.libcFn("close", l.ty_i32, &params, false);
                var a = [_]*c.Value{fc.coerce(vals.items[0], .i32_).v};
                const r = c.LLVMBuildSExt(l.b, l.callLib(f, &a), l.ty_i64, "");
                return fc.errnoFix(r);
            },
            .socket => {
                if (vals.items.len < 3) return l.failAt(span, "Socket expects 3 arguments", .{});
                var params = [_]*c.Type{ l.ty_i32, l.ty_i32, l.ty_i32 };
                const f = try l.libcFn("socket", l.ty_i32, &params, false);
                var a = [_]*c.Value{ fc.coerce(vals.items[0], .i32_).v, fc.coerce(vals.items[1], .i32_).v, fc.coerce(vals.items[2], .i32_).v };
                const r = c.LLVMBuildSExt(l.b, l.callLib(f, &a), l.ty_i64, "");
                return fc.errnoFix(r);
            },
            .connect => {
                if (vals.items.len < 3) return l.failAt(span, "Connect expects 3 arguments", .{});
                var params = [_]*c.Type{ l.ty_i32, l.ty_ptr, l.ty_i32 };
                const f = try l.libcFn("connect", l.ty_i32, &params, false);
                var a = [_]*c.Value{ fc.coerce(vals.items[0], .i32_).v, fc.coerce(vals.items[1], .ptr_).v, fc.coerce(vals.items[2], .i32_).v };
                const r = c.LLVMBuildSExt(l.b, l.callLib(f, &a), l.ty_i64, "");
                return fc.errnoFix(r);
            },
            .bind => {
                if (vals.items.len < 3) return l.failAt(span, "Bind expects 3 arguments", .{});
                var params = [_]*c.Type{ l.ty_i32, l.ty_ptr, l.ty_i32 };
                const f = try l.libcFn("bind", l.ty_i32, &params, false);
                var a = [_]*c.Value{ fc.coerce(vals.items[0], .i32_).v, fc.coerce(vals.items[1], .ptr_).v, fc.coerce(vals.items[2], .i32_).v };
                const r = c.LLVMBuildSExt(l.b, l.callLib(f, &a), l.ty_i64, "");
                return fc.errnoFix(r);
            },
            .listen => {
                if (vals.items.len < 2) return l.failAt(span, "Listen expects 2 arguments", .{});
                var params = [_]*c.Type{ l.ty_i32, l.ty_i32 };
                const f = try l.libcFn("listen", l.ty_i32, &params, false);
                var a = [_]*c.Value{ fc.coerce(vals.items[0], .i32_).v, fc.coerce(vals.items[1], .i32_).v };
                const r = c.LLVMBuildSExt(l.b, l.callLib(f, &a), l.ty_i64, "");
                return fc.errnoFix(r);
            },
            .accept => {
                if (vals.items.len < 3) return l.failAt(span, "Accept expects 3 arguments", .{});
                var params = [_]*c.Type{ l.ty_i32, l.ty_ptr, l.ty_ptr };
                const f = try l.libcFn("accept", l.ty_i32, &params, false);
                var a = [_]*c.Value{ fc.coerce(vals.items[0], .i32_).v, fc.coerce(vals.items[1], .ptr_).v, fc.coerce(vals.items[2], .ptr_).v };
                const r = c.LLVMBuildSExt(l.b, l.callLib(f, &a), l.ty_i64, "");
                return fc.errnoFix(r);
            },
            .setsockopt => {
                if (vals.items.len < 5) return l.failAt(span, "SetSockOpt expects 5 arguments", .{});
                var params = [_]*c.Type{ l.ty_i32, l.ty_i32, l.ty_i32, l.ty_ptr, l.ty_i32 };
                const f = try l.libcFn("setsockopt", l.ty_i32, &params, false);
                var a = [_]*c.Value{ fc.coerce(vals.items[0], .i32_).v, fc.coerce(vals.items[1], .i32_).v, fc.coerce(vals.items[2], .i32_).v, fc.coerce(vals.items[3], .ptr_).v, fc.coerce(vals.items[4], .i32_).v };
                const r = c.LLVMBuildSExt(l.b, l.callLib(f, &a), l.ty_i64, "");
                return fc.errnoFix(r);
            },
            .shutdown => {
                if (vals.items.len < 2) return l.failAt(span, "Shutdown expects 2 arguments", .{});
                var params = [_]*c.Type{ l.ty_i32, l.ty_i32 };
                const f = try l.libcFn("shutdown", l.ty_i32, &params, false);
                var a = [_]*c.Value{ fc.coerce(vals.items[0], .i32_).v, fc.coerce(vals.items[1], .i32_).v };
                const r = c.LLVMBuildSExt(l.b, l.callLib(f, &a), l.ty_i64, "");
                return fc.errnoFix(r);
            },
            .remove => {
                if (vals.items.len < 1) return l.failAt(span, "Remove expects 1 argument", .{});
                var params = [_]*c.Type{l.ty_ptr};
                const f = try l.libcFn("remove", l.ty_i32, &params, false);
                var a = [_]*c.Value{fc.coerce(vals.items[0], .ptr_).v};
                const r = c.LLVMBuildSExt(l.b, l.callLib(f, &a), l.ty_i64, "");
                return fc.errnoFix(r);
            },
            .rename => {
                if (vals.items.len < 2) return l.failAt(span, "Rename expects 2 arguments", .{});
                var params = [_]*c.Type{ l.ty_ptr, l.ty_ptr };
                const f = try l.libcFn("rename", l.ty_i32, &params, false);
                var a = [_]*c.Value{ fc.coerce(vals.items[0], .ptr_).v, fc.coerce(vals.items[1], .ptr_).v };
                const r = c.LLVMBuildSExt(l.b, l.callLib(f, &a), l.ty_i64, "");
                return fc.errnoFix(r);
            },
            .mkdir => {
                if (vals.items.len < 1) return l.failAt(span, "Mkdir expects at least 1 argument", .{});
                var params = [_]*c.Type{ l.ty_ptr, l.ty_i32 };
                const f = try l.libcFn("mkdir", l.ty_i32, &params, false);
                const mode = if (vals.items.len >= 2) fc.coerce(vals.items[1], .i32_).v else l.constI32(0o755);
                var a = [_]*c.Value{ fc.coerce(vals.items[0], .ptr_).v, mode };
                const r = c.LLVMBuildSExt(l.b, l.callLib(f, &a), l.ty_i64, "");
                return fc.errnoFix(r);
            },
            .chdir => {
                if (vals.items.len < 1) return l.failAt(span, "Chdir expects 1 argument", .{});
                var params = [_]*c.Type{l.ty_ptr};
                const f = try l.libcFn("chdir", l.ty_i32, &params, false);
                var a = [_]*c.Value{fc.coerce(vals.items[0], .ptr_).v};
                const r = c.LLVMBuildSExt(l.b, l.callLib(f, &a), l.ty_i64, "");
                return fc.errnoFix(r);
            },
            .getcwd => {
                if (vals.items.len < 2) return l.failAt(span, "Getcwd expects 2 arguments", .{});
                var params = [_]*c.Type{ l.ty_ptr, l.ty_i64 };
                const f = try l.libcFn("getcwd", l.ty_ptr, &params, false);
                var a = [_]*c.Value{ fc.coerce(vals.items[0], .ptr_).v, fc.coerce(vals.items[1], .i64_).v };
                const r = l.callLib(f, &a);
                return .{ .v = c.LLVMBuildPtrToInt(l.b, r, l.ty_i64, ""), .ty = .i64_ };
            },
            .gettid => {
                if (darwin) {
                    const f = try l.libcFn("pthread_self", l.ty_ptr, &.{}, false);
                    const r = l.callLib(f, &.{});
                    return .{ .v = c.LLVMBuildPtrToInt(l.b, r, l.ty_i64, ""), .ty = .i64_ };
                }
                const f = try l.libcFn("gettid", l.ty_i32, &.{}, false);
                return .{ .v = c.LLVMBuildSExt(l.b, l.callLib(f, &.{}), l.ty_i64, ""), .ty = .i64_ };
            },
            .thread => {
                if (vals.items.len < 2) return l.failAt(span, "Thread expects 2 arguments", .{});
                // pair = malloc(16); pair[0]=fn, pair[8]=arg;
                // pthread_create(&tid, NULL, shim, pair); handle = tid.
                var m_params = [_]*c.Type{l.ty_i64};
                const malloc_fn = try l.libcFn("malloc", l.ty_ptr, &m_params, false);
                var m_args = [_]*c.Value{l.constI64(16)};
                const pair = l.callLib(malloc_fn, &m_args);
                _ = c.LLVMBuildStore(l.b, fc.coerce(vals.items[0], .ptr_).v, pair);
                _ = c.LLVMBuildStore(l.b, fc.coerce(vals.items[1], .i64_).v, l.gepByte(pair, 8));
                const shim = try l.threadShim();
                const tid_slot = fc.allocaBytes(8, 8, "tid");
                var p_params = [_]*c.Type{ l.ty_ptr, l.ty_ptr, l.ty_ptr, l.ty_ptr };
                const create_fn = try l.libcFn("pthread_create", l.ty_i32, &p_params, false);
                var p_args = [_]*c.Value{ tid_slot, c.LLVMConstPointerNull(l.ty_ptr), shim.value, pair };
                const rc = l.callLib(create_fn, &p_args);
                const handle = c.LLVMBuildLoad2(l.b, l.ty_i64, tid_slot, "");
                const ok = c.LLVMBuildICmp(l.b, .eq, rc, l.constI32(0), "");
                const r = c.LLVMBuildSelect(l.b, ok, handle, l.constI64(-1), "");
                return .{ .v = r, .ty = .i64_ };
            },
            .join => {
                if (vals.items.len < 1) return l.failAt(span, "Join expects 1 argument", .{});
                const ret_slot = fc.allocaBytes(8, 8, "join.ret");
                _ = c.LLVMBuildStore(l.b, l.constI64(0), ret_slot);
                var params = [_]*c.Type{ l.ty_ptr, l.ty_ptr };
                const f = try l.libcFn("pthread_join", l.ty_i32, &params, false);
                var a = [_]*c.Value{ fc.coerce(vals.items[0], .ptr_).v, ret_slot };
                _ = l.callLib(f, &a);
                return .{ .v = c.LLVMBuildLoad2(l.b, l.ty_i64, ret_slot, ""), .ty = .i64_ };
            },
            .thread_yield => {
                const f = try l.libcFn("sched_yield", l.ty_i32, &.{}, false);
                return .{ .v = c.LLVMBuildSExt(l.b, l.callLib(f, &.{}), l.ty_i64, ""), .ty = .i64_ };
            },
            .thread_exit => {
                if (vals.items.len < 1) return l.failAt(span, "ThreadExit expects 1 argument", .{});
                const rp = c.LLVMBuildIntToPtr(l.b, fc.coerce(vals.items[0], .i64_).v, l.ty_ptr, "");
                var params = [_]*c.Type{l.ty_ptr};
                const f = try l.libcFn("pthread_exit", l.ty_void, &params, false);
                var a = [_]*c.Value{rp};
                _ = l.callLib(f, &a);
                return l.constInt(.i64_, 0);
            },
            .thread_detach => {
                if (vals.items.len < 1) return l.failAt(span, "ThreadDetach expects 1 argument", .{});
                var params = [_]*c.Type{l.ty_ptr};
                const f = try l.libcFn("pthread_detach", l.ty_i32, &params, false);
                var a = [_]*c.Value{fc.coerce(vals.items[0], .ptr_).v};
                return .{ .v = c.LLVMBuildSExt(l.b, l.callLib(f, &a), l.ty_i64, ""), .ty = .i64_ };
            },
            .atomic_load, .atomic_store, .atomic_add, .atomic_swap, .atomic_cas => {
                return fc.emitAtomic(pk, args, vals.items, span);
            },
            .futex_wait, .futex_wake, .futex_wait_ns => {
                return fc.emitFutex(pk, vals.items, span);
            },
        }
    }

    /// r >= 0 ? r : -errno — HolyC's failure convention for filesystem
    /// primitives (the Go @errno_fixup helper, minus the cross-OS errno
    /// renumbering, which no golden observes).
    fn errnoFix(fc: *FnCtx, r: *c.Value) Error!TV {
        const l = fc.l;
        const darwin = l.tgt.os == .darwin;
        const f = try l.libcFn(if (darwin) "__error" else "__errno_location", l.ty_ptr, &.{}, false);
        const ep = l.callLib(f, &.{});
        const e32 = c.LLVMBuildLoad2(l.b, l.ty_i32, ep, "");
        const e64 = c.LLVMBuildSExt(l.b, e32, l.ty_i64, "");
        const neg = c.LLVMBuildNeg(l.b, e64, "");
        const ok = c.LLVMBuildICmp(l.b, .sge, r, l.constI64(0), "");
        return .{ .v = c.LLVMBuildSelect(l.b, ok, r, neg, ""), .ty = .i64_ };
    }

    fn emitNanosleep(fc: *FnCtx, ns: *c.Value) Error!void {
        const l = fc.l;
        const ts = fc.allocaBytes(16, 8, "ts");
        const billion = l.constI64(1_000_000_000);
        const sec = c.LLVMBuildSDiv(l.b, ns, billion, "");
        const nsec = c.LLVMBuildSRem(l.b, ns, billion, "");
        _ = c.LLVMBuildStore(l.b, sec, ts);
        _ = c.LLVMBuildStore(l.b, nsec, l.gepByte(ts, 8));
        var params = [_]*c.Type{ l.ty_ptr, l.ty_ptr };
        const f = try l.libcFn("nanosleep", l.ty_i32, &params, false);
        var a = [_]*c.Value{ ts, c.LLVMConstPointerNull(l.ty_ptr) };
        _ = l.callLib(f, &a);
    }

    fn emitAtomic(fc: *FnCtx, pk: PrimKind, args: []const ?*ast.Expr, vals: []const TV, span: source.Span) Error!TV {
        const l = fc.l;
        // The access width comes from the pointee of the first argument.
        var w: VTy = .i64_;
        if (args.len > 0) {
            if (args[0]) |a0| {
                if (a0.ty) |t| {
                    if (derefTy(t)) |elem| {
                        if (scalarVTy(elem)) |vt| w = vt;
                    }
                }
            }
        }
        if (vals.len < 1) return l.failAt(span, "atomic expects a pointer argument", .{});
        const p = fc.coerce(vals[0], .ptr_).v;
        const wty = l.llvmTy(w);
        const walign: c_uint = @intCast(@as(u8, w.bits()) / 8);
        switch (pk) {
            .atomic_load => {
                const v = c.LLVMBuildLoad2(l.b, wty, p, "");
                c.LLVMSetOrdering(v, .seq_cst);
                c.LLVMSetAlignment(v, walign);
                return fc.coerce(.{ .v = v, .ty = w }, .i64_);
            },
            .atomic_store => {
                if (vals.len < 2) return l.failAt(span, "AtomicStore expects 2 arguments", .{});
                const v = fc.coerce(vals[1], w);
                const st = c.LLVMBuildStore(l.b, v.v, p);
                c.LLVMSetOrdering(st, .seq_cst);
                c.LLVMSetAlignment(st, walign);
                return l.constInt(.i64_, 0);
            },
            .atomic_add => {
                if (vals.len < 2) return l.failAt(span, "AtomicAdd expects 2 arguments", .{});
                const d = fc.coerce(vals[1], w);
                const old = c.LLVMBuildAtomicRMW(l.b, .add, p, d.v, .seq_cst, 0);
                // HolyC's AtomicAdd returns the new value.
                const new = c.LLVMBuildAdd(l.b, old, d.v, "");
                return fc.coerce(.{ .v = new, .ty = w }, .i64_);
            },
            .atomic_swap => {
                if (vals.len < 2) return l.failAt(span, "AtomicSwap expects 2 arguments", .{});
                const v = fc.coerce(vals[1], w);
                const old = c.LLVMBuildAtomicRMW(l.b, .xchg, p, v.v, .seq_cst, 0);
                return fc.coerce(.{ .v = old, .ty = w }, .i64_);
            },
            else => { // atomic_cas
                if (vals.len < 3) return l.failAt(span, "AtomicCas expects 3 arguments", .{});
                const expected = fc.coerce(vals[1], w);
                const desired = fc.coerce(vals[2], w);
                const pair = c.LLVMBuildAtomicCmpXchg(l.b, p, expected.v, desired.v, .seq_cst, .seq_cst, 0);
                const old = c.LLVMBuildExtractValue(l.b, pair, 0, "");
                return fc.coerce(.{ .v = old, .ty = w }, .i64_);
            },
        }
    }

    fn emitFutex(fc: *FnCtx, pk: PrimKind, vals: []const TV, span: source.Span) Error!TV {
        const l = fc.l;
        if (l.tgt.os == .linux) {
            // The futex syscall through libc syscall(2). FUTEX_WAIT=0, FUTEX_WAKE=1.
            const nr: i64 = if (l.tgt.arch == .amd64) 202 else 98;
            var params = [_]*c.Type{l.ty_i64};
            const f = try l.libcFn("syscall", l.ty_i64, &params, true);
            switch (pk) {
                .futex_wait => {
                    if (vals.len < 2) return l.failAt(span, "FutexWait expects 2 arguments", .{});
                    var a = [_]*c.Value{ l.constI64(nr), fc.coerce(vals[0], .ptr_).v, l.constI64(0), fc.coerce(vals[1], .i64_).v, c.LLVMConstPointerNull(l.ty_ptr) };
                    return .{ .v = l.callLib(f, &a), .ty = .i64_ };
                },
                .futex_wake => {
                    if (vals.len < 2) return l.failAt(span, "FutexWake expects 2 arguments", .{});
                    var a = [_]*c.Value{ l.constI64(nr), fc.coerce(vals[0], .ptr_).v, l.constI64(1), fc.coerce(vals[1], .i64_).v };
                    return .{ .v = l.callLib(f, &a), .ty = .i64_ };
                },
                else => {
                    if (vals.len < 3) return l.failAt(span, "FutexWaitNs expects 3 arguments", .{});
                    const ts = fc.allocaBytes(16, 8, "futex.ts");
                    const ns = fc.coerce(vals[2], .i64_).v;
                    const billion = l.constI64(1_000_000_000);
                    _ = c.LLVMBuildStore(l.b, c.LLVMBuildSDiv(l.b, ns, billion, ""), ts);
                    _ = c.LLVMBuildStore(l.b, c.LLVMBuildSRem(l.b, ns, billion, ""), l.gepByte(ts, 8));
                    var a = [_]*c.Value{ l.constI64(nr), fc.coerce(vals[0], .ptr_).v, l.constI64(0), fc.coerce(vals[1], .i64_).v, ts };
                    return .{ .v = l.callLib(f, &a), .ty = .i64_ };
                },
            }
        }
        // Darwin: no public futex; emulate cheaply (unexercised): a wait is
        // a short sleep while the value still matches, a wake is a no-op.
        switch (pk) {
            .futex_wait, .futex_wait_ns => {
                if (vals.len < 2) return l.failAt(span, "futex wait expects at least 2 arguments", .{});
                const p = fc.coerce(vals[0], .ptr_).v;
                const cur = c.LLVMBuildLoad2(l.b, l.ty_i64, p, "");
                const eq = c.LLVMBuildICmp(l.b, .eq, cur, fc.coerce(vals[1], .i64_).v, "");
                const sleep_b = fc.newBlock("futex.sleep");
                const done_b = fc.newBlock("futex.done");
                fc.condBr(eq, sleep_b, done_b);
                fc.position(sleep_b);
                const ns: *c.Value = if (pk == .futex_wait_ns and vals.len >= 3)
                    fc.coerce(vals[2], .i64_).v
                else
                    l.constI64(1_000_000); // 1ms poll
                try fc.emitNanosleep(ns);
                fc.br(done_b);
                fc.position(done_b);
                return l.constInt(.i64_, 0);
            },
            else => return l.constInt(.i64_, 0), // futex_wake
        }
    }
};

// ---- inline assembly ----
//
// HolyC asm blocks are lowered by rendering them back to assembler text and
// handing that text to LLVM (the Zig/LLVM equivalent of the Go compiler's
// per-arch assemblers in backend/arch/{amd64,arm64}):
//
//   - A standalone labelled top-level block becomes module-level asm defining
//     its labels as global symbols; `_extern LABEL sig;` call sites call the
//     label as an ordinary external function.
//   - A labelless block inside a function becomes one side-effecting inline
//     asm call. A HolyC variable named as an operand (the Go frame-slot
//     rewrite) is passed by address as an `r` input and referenced through a
//     register-indirect memory operand; a `reg <REG>` pinned variable whose
//     register the block names is synced through the block as a tied
//     `{reg}` input / `={reg}` output pair (the Go allocator serviced the
//     pinned slot from the register for the whole function; syncing at the
//     block boundary preserves the observable variable/register contract).
//
// amd64 text is rendered in Intel syntax (HolyC asm is `mnemonic dst, src`);
// the other arches in their standard GAS syntax. HolyC always spells named
// registers and bracket memory operands; each arch's descriptor renders its
// native form (`[a0 + 8]` → `8(a0)` on riscv64, `R3` → `3` on ppc64le,
// `R2` → `%r2` on s390x). Intra-block labels become assembler-local `${:uid}`
// labels, which cannot collide across blocks.

/// Everything arch-specific about rendering and constraining an asm block.
/// The register vocabulary (operand classification + the pinnable GP set)
/// lives with the front end in asm_regs.zig; adding an architecture means
/// one entry there and one descriptor here (see docs/asm-roadmap.md).
const AsmArchInfo = struct {
    dialect: c.InlineAsmDialect,
    /// Prefix rendered before an integer immediate ("#" on arm64).
    imm_prefix: []const u8,
    /// The always-clobbered tail of every inline-asm constraint string:
    /// memory plus the arch's flags — correctness over performance.
    baseline_clobbers: []const u8,
    /// Bracketing for standalone module-level asm blocks (module asm defaults
    /// to AT&T, so Intel-dialect text carries syntax directives).
    module_prologue: []const u8,
    module_epilogue: []const u8,
    /// The constraint class for a HolyC-variable address input. Plain "r" is
    /// wrong where r0-as-base means "no base": PPC needs "b" (base register)
    /// and s390x needs "a" (address register), else regalloc may hand the
    /// address to r0 and the rendered 0($N) reads absolute address 0.
    var_constraint: []const u8 = "r",
    /// Renders a register operand in the assembler's spelling. Most arches
    /// write the (lowercased) source name as-is; PPC wants the bare number
    /// and s390x wants a `%` prefix.
    renderReg: *const fn (g: *AsmGen, name: []const u8) Error!void,
    /// Renders a HolyC-variable operand as an indirect reference through
    /// input operand $opnum (the variable's address).
    renderVarRef: *const fn (g: *AsmGen, opnum: usize, width: u64) Error!void,
    renderMem: *const fn (g: *AsmGen, m: *const ast.AsmMem, span: source.Span) Error!void,
};

const amd64_info = AsmArchInfo{
    .dialect = .intel,
    .imm_prefix = "",
    .baseline_clobbers = "~{dirflag},~{fpsr},~{flags},~{memory}",
    .module_prologue = ".intel_syntax noprefix\n.text\n.p2align 4\n",
    .module_epilogue = ".att_syntax prefix\n",
    .renderReg = &AsmGen.putLower,
    .renderVarRef = &AsmGen.renderVarRefIntel,
    .renderMem = &AsmGen.renderMemIntel,
};

const arm64_info = AsmArchInfo{
    .dialect = .att,
    .imm_prefix = "#",
    .baseline_clobbers = "~{cc},~{memory}",
    .module_prologue = ".text\n.p2align 2\n",
    .module_epilogue = "",
    .renderReg = &AsmGen.putLower,
    .renderVarRef = &AsmGen.renderVarRefArm64,
    .renderMem = &AsmGen.renderMemArm64,
};

const riscv64_info = AsmArchInfo{
    .dialect = .att,
    // Plain integers; RISC-V assembler syntax has no immediate sigil.
    .imm_prefix = "",
    // No flags register on RISC-V: memory is the only baseline clobber.
    .baseline_clobbers = "~{memory}",
    .module_prologue = ".text\n.p2align 2\n",
    .module_epilogue = "",
    .renderReg = &AsmGen.putLower,
    .renderVarRef = &AsmGen.renderVarRefRiscv,
    .renderMem = &AsmGen.renderMemRiscv,
};

const ppc64le_info = AsmArchInfo{
    .dialect = .att,
    .imm_prefix = "",
    // `cc` is the clang spelling for the PPC condition register.
    .baseline_clobbers = "~{cc},~{memory}",
    .module_prologue = ".text\n.p2align 2\n",
    .module_epilogue = "",
    .var_constraint = "b",
    .renderReg = &AsmGen.renderRegPpc,
    .renderVarRef = &AsmGen.renderVarRefDispBase,
    .renderMem = &AsmGen.renderMemPpc,
};

const s390x_info = AsmArchInfo{
    .dialect = .att,
    .imm_prefix = "",
    .baseline_clobbers = "~{cc},~{memory}",
    .module_prologue = ".text\n.p2align 2\n",
    .module_epilogue = "",
    .var_constraint = "a",
    .renderReg = &AsmGen.renderRegS390,
    .renderVarRef = &AsmGen.renderVarRefDispBase,
    .renderMem = &AsmGen.renderMemS390,
};

fn asmArchInfo(arch: target_mod.Arch) *const AsmArchInfo {
    return switch (arch) {
        .amd64 => &amd64_info,
        .arm64 => &arm64_info,
        .riscv64 => &riscv64_info,
        .ppc64le => &ppc64le_info,
        .s390x => &s390x_info,
    };
}

/// The Intel operand-size keyword for an access width in bytes.
fn asmWidthKeyword(width: u64) []const u8 {
    return switch (width) {
        1 => "byte",
        2 => "word",
        4 => "dword",
        else => "qword",
    };
}

/// The access width of a typed memory operand's spelling (`U64 SF_ARG1[RBP]`);
/// null for an unknown spelling. The Go asmWidth mapping.
fn asmTyWidth(ty: []const u8) ?u64 {
    const map = std.StaticStringMap(u64).initComptime(.{
        .{ "I8", 1 },  .{ "U8", 1 },
        .{ "I16", 2 }, .{ "U16", 2 },
        .{ "I32", 4 }, .{ "U32", 4 },
        .{ "I64", 8 }, .{ "U64", 8 },
    });
    return map.get(ty);
}

/// Renders one asm block to assembler text. fc is the enclosing function for
/// an inline block, or null for a standalone module-level block.
const AsmGen = struct {
    l: *Lowerer,
    a: *const ast.AsmStmt,
    info: *const AsmArchInfo,
    fc: ?*FnCtx,
    /// Label name -> index of its item in a.insts. The map index names the
    /// rendered assembler-local label.
    labels: std.StringArrayHashMapUnmanaged(usize) = .empty,
    /// `reg <REG>` locals whose pinned register the block names.
    pins: std.ArrayList(Pin) = .empty,
    /// HolyC variables named as operands, deduplicated, in first-use order.
    vars: std.ArrayList(Var) = .empty,
    /// Referenced canonical GP registers that are not pinned: clobbers.
    clobbers: std.ArrayList([]const u8) = .empty,
    text: std.ArrayList(u8) = .empty,

    const Pin = struct { local: Local, reg: []const u8 };
    const Var = struct { name: []const u8, local: Local, width: u64 };

    fn put(g: *AsmGen, comptime fmt: []const u8, args: anytype) Error!void {
        try g.text.print(g.l.arena, fmt, args);
    }

    fn putLower(g: *AsmGen, s: []const u8) Error!void {
        for (s) |ch| try g.text.append(g.l.arena, std.ascii.toLower(ch));
    }

    /// An inline block's intra-block label, spelled as an assembler-local
    /// symbol (`L`/`.L` prefix per object format). `${:uid}` expands to a
    /// per-asm-instance unique id, so the label cannot collide with another
    /// block's — or with a duplicated copy of its own (LLVM may clone inline
    /// asm during optimization). The Intel-dialect parser rejects GAS numeric
    /// local labels (`1:`/`1b`), so named labels are used on both arches.
    fn putLocalLabel(g: *AsmGen, map_idx: usize) Error!void {
        const prefix = if (g.l.tgt.os == .darwin) "L" else ".L";
        try g.put("{s}asm{d}_${{:uid}}", .{ prefix, map_idx });
    }

    fn collectLabels(g: *AsmGen) Error!void {
        for (g.a.insts, 0..) |*inst, i| {
            if (!inst.isLabel()) continue;
            const gop = try g.labels.getOrPut(g.l.arena, inst.label);
            if (gop.found_existing) {
                return g.l.failAt(inst.span, "asm label `{s}` is defined more than once", .{inst.label});
            }
            gop.value_ptr.* = i;
        }
    }

    /// Gathers the block's register and variable references (inline blocks
    /// only): every named GP register becomes a pinned-variable sync when an
    /// in-scope `reg <REG>` local claims it, and a clobber otherwise.
    fn collectOperands(g: *AsmGen) Error!void {
        const l = g.l;
        var regs: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (g.a.insts) |*inst| {
            for (inst.operands) |op| switch (op.kind) {
                .reg => |r| if (asm_regs.canonGp(l.tgt.arch, r)) |cr| try regs.put(l.arena, cr, {}),
                .mem => |m| {
                    if (asm_regs.canonGp(l.tgt.arch, m.base)) |cr| try regs.put(l.arena, cr, {});
                    if (asm_regs.canonGp(l.tgt.arch, m.index)) |cr| try regs.put(l.arena, cr, {});
                },
                .variable => |name| try g.addVar(name, op.span),
                else => {},
            };
        }
        for (regs.keys()) |r| {
            if (g.fc.?.pinnedLocal(r)) |local| {
                try g.pins.append(l.arena, .{ .local = local, .reg = r });
            } else {
                try g.clobbers.append(l.arena, r);
            }
        }
    }

    fn addVar(g: *AsmGen, name: []const u8, span: source.Span) Error!void {
        for (g.vars.items) |v| {
            if (std.mem.eql(u8, v.name, name)) return;
        }
        const l = g.l;
        const fc = g.fc.?;
        const local = fc.lookup(name) orelse {
            if (l.globals.contains(name)) {
                return l.failAt(span, "inline asm cannot name the global `{s}` directly; take its address into a register and dereference it, e.g. `U8 reg <REG> *p = &{s};` then `[<REG>]`", .{ name, name });
            }
            return l.failAt(span, "unknown variable `{s}` in inline asm", .{name});
        };
        const width = l.layouts.sizeOf(local.ty);
        if (local.indirect or local.ty.isAggregate() or scalarVTy(local.ty) == null or
            (width != 1 and width != 2 and width != 4 and width != 8))
        {
            return l.failAt(span, "inline asm cannot reference the non-scalar variable `{s}`", .{name});
        }
        try g.vars.append(l.arena, .{ .name = name, .local = local, .width = width });
    }

    fn varIndex(g: *const AsmGen, name: []const u8) usize {
        for (g.vars.items, 0..) |v, i| {
            if (std.mem.eql(u8, v.name, name)) return i;
        }
        unreachable; // every variable operand was collected
    }

    fn render(g: *AsmGen) Error!void {
        for (g.a.insts) |*inst| {
            if (inst.isLabel()) {
                if (g.fc == null) {
                    // A standalone block's labels are (decorated) global
                    // symbols, the `_extern` binding targets.
                    const dec = try g.l.symbolName(inst.label);
                    try g.put(".globl {s}\n{s}:\n", .{ dec, dec });
                } else {
                    try g.putLocalLabel(g.labels.getIndex(inst.label).?);
                    try g.put(":\n", .{});
                }
                continue;
            }
            try g.put("\t", .{});
            try g.putLower(inst.mnemonic);
            for (inst.operands, 0..) |op, j| {
                try g.text.appendSlice(g.l.arena, if (j == 0) "\t" else ", ");
                try g.renderOperand(op);
            }
            try g.put("\n", .{});
        }
    }

    fn renderOperand(g: *AsmGen, op: ast.AsmOperand) Error!void {
        const l = g.l;
        switch (op.kind) {
            .reg => |r| try g.info.renderReg(g, r),
            .imm => |v| try g.put("{s}{d}", .{ g.info.imm_prefix, v }),
            .variable => |name| {
                if (g.fc == null) {
                    return l.failAt(op.span, "a standalone asm block has no stack frame and cannot reference the HolyC variable `{s}`", .{name});
                }
                // The variable's address is input operand $N (after the pin
                // outputs and pin inputs); reference it indirectly.
                const idx = g.varIndex(name);
                const opnum = 2 * g.pins.items.len + idx;
                try g.info.renderVarRef(g, opnum, g.vars.items[idx].width);
            },
            .sym => |name| {
                // `&name`: a branch target, resolved within the block (the Go
                // assemblers resolved fixups against the block's labels).
                const map_idx = g.labels.getIndex(name) orelse
                    return l.failAt(op.span, "asm branch to undefined label `{s}`", .{name});
                if (g.fc == null) {
                    try g.put("{s}", .{try l.symbolName(name)});
                } else {
                    try g.putLocalLabel(map_idx);
                }
            },
            .mem => |m| {
                if (m.disp_sym.len > 0) {
                    return l.failAt(op.span, "the symbolic asm displacement `{s}` is not supported", .{m.disp_sym});
                }
                try g.info.renderMem(g, m, op.span);
            },
        }
    }

    fn renderVarRefIntel(g: *AsmGen, opnum: usize, width: u64) Error!void {
        try g.put("{s} ptr [${d}]", .{ asmWidthKeyword(width), opnum });
    }

    fn renderVarRefArm64(g: *AsmGen, opnum: usize, width: u64) Error!void {
        _ = width; // the access width comes from the instruction's register operand
        try g.put("[${d}]", .{opnum});
    }

    fn renderMemIntel(g: *AsmGen, m: *const ast.AsmMem, span: source.Span) Error!void {
        if (m.ty.len > 0) {
            const w = asmTyWidth(m.ty) orelse
                return g.l.failAt(span, "unknown asm memory-operand type `{s}`", .{m.ty});
            try g.put("{s} ptr ", .{asmWidthKeyword(w)});
        }
        try g.put("[", .{});
        var have_term = false;
        if (m.base.len > 0) {
            try g.putLower(m.base);
            have_term = true;
        }
        if (m.index.len > 0) {
            if (have_term) try g.put(" + ", .{});
            try g.putLower(m.index);
            if (m.scale > 1) try g.put("*{d}", .{m.scale});
            have_term = true;
        }
        if (m.disp != 0 or !have_term) {
            if (!have_term) {
                try g.put("{d}", .{m.disp});
            } else if (m.disp < 0) {
                try g.put(" - {d}", .{-m.disp});
            } else {
                try g.put(" + {d}", .{m.disp});
            }
        }
        try g.put("]", .{});
    }

    fn renderMemArm64(g: *AsmGen, m: *const ast.AsmMem, span: source.Span) Error!void {
        if (m.ty.len > 0) {
            return g.l.failAt(span, "a typed memory operand is not supported in arm64 asm", .{});
        }
        if (m.base.len == 0) {
            return g.l.failAt(span, "an arm64 memory operand requires a base register", .{});
        }
        try g.put("[", .{});
        try g.putLower(m.base);
        if (m.index.len > 0) {
            try g.put(", ", .{});
            try g.putLower(m.index);
            if (m.scale > 1) {
                try g.put(", lsl #{d}", .{std.math.log2_int(u64, @intCast(m.scale))});
            }
        } else if (m.disp != 0) {
            try g.put(", #{d}", .{m.disp});
        }
        try g.put("]", .{});
    }

    fn renderVarRefRiscv(g: *AsmGen, opnum: usize, width: u64) Error!void {
        _ = width; // the access width comes from the instruction mnemonic (lb/lh/lw/ld)
        try g.put("0(${d})", .{opnum});
    }

    fn renderMemRiscv(g: *AsmGen, m: *const ast.AsmMem, span: source.Span) Error!void {
        if (m.ty.len > 0) {
            return g.l.failAt(span, "a typed memory operand is not supported in riscv64 asm", .{});
        }
        if (m.base.len == 0) {
            return g.l.failAt(span, "a riscv64 memory operand requires a base register", .{});
        }
        if (m.index.len > 0) {
            // RISC-V addressing is displacement(base) only; there is no
            // base+index form to render.
            return g.l.failAt(span, "riscv64 memory operands support base+displacement only", .{});
        }
        try g.put("{d}(", .{m.disp});
        try g.putLower(m.base);
        try g.put(")", .{});
    }

    /// PPC assembler operands are bare register numbers (the LLVM parser
    /// rejects `r3`): the source's named register renders as its number.
    /// Prefixless specials (lr/ctr/xer) pass through — they only appear via
    /// mnemonics, so the assembler rejects them as operands with a good error.
    fn renderRegPpc(g: *AsmGen, name: []const u8) Error!void {
        const digits = std.mem.indexOfAny(u8, name, "0123456789") orelse
            return g.putLower(name);
        try g.text.appendSlice(g.l.arena, name[digits..]);
    }

    /// s390x assembler operands require the `%` prefix (`%r2`).
    fn renderRegS390(g: *AsmGen, name: []const u8) Error!void {
        try g.text.append(g.l.arena, '%');
        try g.putLower(name);
    }

    /// Shared by ppc64le and s390x: a variable reference is a plain
    /// displacement(base) through the address operand; the access width
    /// comes from the mnemonic.
    fn renderVarRefDispBase(g: *AsmGen, opnum: usize, width: u64) Error!void {
        _ = width;
        try g.put("0(${d})", .{opnum});
    }

    /// PPC addressing is displacement(base); the indexed form is a separate
    /// mnemonic family (ldx/stdx) taking plain register operands.
    fn renderMemPpc(g: *AsmGen, m: *const ast.AsmMem, span: source.Span) Error!void {
        if (m.ty.len > 0) {
            return g.l.failAt(span, "a typed memory operand is not supported in ppc64le asm", .{});
        }
        if (m.base.len == 0) {
            return g.l.failAt(span, "a ppc64le memory operand requires a base register", .{});
        }
        if (m.index.len > 0) {
            return g.l.failAt(span, "ppc64le memory operands support base+displacement only (use the indexed-form mnemonics, e.g. LDX, with register operands)", .{});
        }
        try g.put("{d}(", .{m.disp});
        try renderRegPpc(g, m.base);
        try g.put(")", .{});
    }

    /// s390x D(X,B) addressing: displacement(index,base), unscaled.
    fn renderMemS390(g: *AsmGen, m: *const ast.AsmMem, span: source.Span) Error!void {
        if (m.ty.len > 0) {
            return g.l.failAt(span, "a typed memory operand is not supported in s390x asm", .{});
        }
        if (m.base.len == 0) {
            return g.l.failAt(span, "an s390x memory operand requires a base register", .{});
        }
        if (m.scale > 1) {
            return g.l.failAt(span, "s390x has no scaled index; scale the index in a register first", .{});
        }
        try g.put("{d}(", .{m.disp});
        if (m.index.len > 0) {
            try renderRegS390(g, m.index);
            try g.put(",", .{});
        }
        try renderRegS390(g, m.base);
        try g.put(")", .{});
    }
};

// ---- tests ----
