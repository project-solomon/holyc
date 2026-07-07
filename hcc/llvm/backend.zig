//! Code generator: drives the LLVM-C API (linked in-process from the system
//! LLVM; see build.zig's -Dllvm-prefix) to translate the checked AST into an
//! LLVM module, verify and optimize it, emit a native object, and link the
//! final artifact with the host C toolchain.

const std = @import("std");
const c = @import("c.zig");
const diag = @import("hcc").diag;
const ast = @import("hcc").ast;
const target_mod = @import("hcc").target;
const lower = @import("lower.zig");

pub const Error = diag.Error;

/// What the driver asks the backend to produce.
pub const EmitKind = enum { exe, obj, shared };

pub const Options = struct {
    target: target_mod.Target,
    kind: EmitKind,
    out_path: []const u8,
    /// Libraries to link against (-l), so `extern` imports resolve beyond
    /// libc; and extra search directories (-L).
    libs: []const []const u8 = &.{},
    lib_dirs: []const []const u8 = &.{},
    /// Explicit C compiler driver for the link step (--cc / HCC_CC). null
    /// picks the default: the system `cc` for the host target, or
    /// `zig cc -target <triple>` (bundled sysroots) for a cross target.
    cc: ?[]const u8 = null,
    /// Run the standard LLVM optimization pipeline (default<O2>). Off is
    /// useful when debugging the lowering.
    optimize: bool = true,
    /// Print the LLVM IR to stderr before verification (debugging aid).
    dump_ir: bool = false,
};

// LLVM target registration is idempotent; a plain flag suffices for the
// driver's single-threaded compilations.
var targets_initialized = false;

fn ensureTargets() void {
    if (!targets_initialized) {
        c.initAllTargets();
        targets_initialized = true;
    }
}

/// Compiles a checked program to opts.out_path. Errors are reported through
/// diags with stage .codegen.
pub fn emit(
    arena: std.mem.Allocator,
    diags: *diag.Diagnostics,
    io: std.Io,
    prog: *const ast.Program,
    opts: Options,
) Error!void {
    ensureTargets();

    const ctx = c.LLVMContextCreate();
    defer c.LLVMContextDispose(ctx);
    const module = c.LLVMModuleCreateWithNameInContext("hcc", ctx);
    defer c.LLVMDisposeModule(module);
    const builder = c.LLVMCreateBuilderInContext(ctx);
    defer c.LLVMDisposeBuilder(builder);

    // Target machine first, so the module carries the right data layout while
    // lowering runs.
    var triple_buf: [64]u8 = undefined;
    const triple = opts.target.llvmTriple(&triple_buf);
    const triple_z = try arena.dupeZ(u8, triple);

    var target_ptr: *c.Target = undefined;
    var err_msg: ?[*:0]u8 = null;
    if (c.LLVMGetTargetFromTriple(triple_z, &target_ptr, &err_msg) != 0) {
        defer if (err_msg) |m| c.LLVMDisposeMessage(m);
        return diags.fail(.codegen, 0, .{}, "LLVM does not recognize target {s}: {s}", .{
            triple, if (err_msg) |m| std.mem.span(m) else "unknown error",
        });
    }
    // riscv64 needs its baseline spelled out: bare "generic" is RV64I only
    // (no multiply, no atomics, no hardware float), and Linux userland is
    // RV64GC with the lp64d ABI (which requires D). amd64/arm64 baselines
    // already include everything the lowering emits.
    const features: [*:0]const u8 = switch (opts.target.arch) {
        .riscv64 => "+m,+a,+f,+d,+c",
        else => "",
    };
    const tm = c.LLVMCreateTargetMachine(target_ptr, triple_z, "generic", features, .default, .pic, .default);
    defer c.LLVMDisposeTargetMachine(tm);
    const td = c.LLVMCreateTargetDataLayout(tm);
    defer c.LLVMDisposeTargetData(td);
    c.LLVMSetTarget(module, triple_z);
    c.LLVMSetModuleDataLayout(module, td);

    try lower.run(arena, diags, .{
        .ctx = ctx,
        .module = module,
        .builder = builder,
        .prog = prog,
        .target = opts.target,
        // Objects and shared libraries are separate-compilation units: their
        // public user definitions export; an executable is a whole program.
        .mode = if (opts.kind == .exe) .exe else .library,
    });

    if (opts.dump_ir) {
        const ir_text = c.LLVMPrintModuleToString(module);
        defer c.LLVMDisposeMessage(ir_text);
        std.debug.print("{s}\n", .{std.mem.span(ir_text)});
    }

    var verify_msg: ?[*:0]u8 = null;
    if (c.LLVMVerifyModule(module, .return_status, &verify_msg) != 0) {
        defer if (verify_msg) |m| c.LLVMDisposeMessage(m);
        return diags.fail(.codegen, 0, .{}, "internal error: generated LLVM module is invalid: {s}", .{
            if (verify_msg) |m| std.mem.span(m) else "unknown error",
        });
    }
    if (verify_msg) |m| c.LLVMDisposeMessage(m);

    if (opts.optimize) {
        const pbo = c.LLVMCreatePassBuilderOptions();
        defer c.LLVMDisposePassBuilderOptions(pbo);
        if (c.LLVMRunPasses(module, "default<O2>", tm, pbo)) |run_err| {
            const m = c.LLVMGetErrorMessage(run_err);
            defer c.LLVMDisposeErrorMessage(m);
            return diags.fail(.codegen, 0, .{}, "LLVM optimization failed: {s}", .{std.mem.span(m)});
        }
    }

    // Emit the object: directly to out_path for --emit obj, else to a
    // temporary next to the final artifact, cleaned up after linking.
    const obj_path = if (opts.kind == .obj)
        opts.out_path
    else
        // The suffix must end in ".o": compiler drivers (zig cc in
        // particular) classify link inputs by extension.
        try std.fmt.allocPrint(arena, "{s}.tmp.o", .{opts.out_path});
    const obj_path_z = try arena.dupeZ(u8, obj_path);

    var emit_msg: ?[*:0]u8 = null;
    if (c.LLVMTargetMachineEmitToFile(tm, module, obj_path_z, .object, &emit_msg) != 0) {
        defer if (emit_msg) |m| c.LLVMDisposeMessage(m);
        return diags.fail(.codegen, 0, .{}, "cannot write object {s}: {s}", .{
            obj_path, if (emit_msg) |m| std.mem.span(m) else "unknown error",
        });
    }
    if (opts.kind == .obj) return;
    defer std.Io.Dir.cwd().deleteFile(io, obj_path) catch {};

    try link(arena, diags, io, obj_path, opts);
}

/// Links through a C compiler driver, which brings in crt, libc, and the
/// platform linker. The driver is opts.cc when given; otherwise the system
/// `cc` for the host target, or `zig cc -target <triple>` for a cross target
/// (Zig ships headers and libc stubs for every triple hcc supports, so no
/// sysroot setup is needed).
fn link(arena: std.mem.Allocator, diags: *diag.Diagnostics, io: std.Io, obj_path: []const u8, opts: Options) Error!void {
    const host = std.meta.eql(opts.target, target_mod.Target.host());
    var argv: std.ArrayList([]const u8) = .empty;
    if (opts.cc) |driver| {
        try argv.append(arena, driver);
    } else if (host) {
        try argv.append(arena, "cc");
    } else {
        try argv.appendSlice(arena, &.{ "zig", "cc", "-target", try zigTriple(arena, opts.target) });
    }
    const driver_name = argv.items[0];
    try argv.appendSlice(arena, &.{ obj_path, "-o", opts.out_path });
    if (opts.kind == .shared) try argv.append(arena, "-shared");
    for (opts.lib_dirs) |dir| {
        try argv.append(arena, try std.fmt.allocPrint(arena, "-L{s}", .{dir}));
    }
    for (opts.libs) |lib| {
        try argv.append(arena, try std.fmt.allocPrint(arena, "-l{s}", .{lib}));
    }

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
    }) catch |e| {
        if (!host and opts.cc == null) {
            return diags.fail(.codegen, 0, .{}, "cannot run `zig` to cross-link for {f}: {s}; install Zig, pass --cc <cross-driver>, or use --emit obj", .{ opts.target, @errorName(e) });
        }
        return diags.fail(.codegen, 0, .{}, "cannot run the linker driver `{s}`: {s}", .{ driver_name, @errorName(e) });
    };
    const term = child.wait(io) catch |e| {
        return diags.fail(.codegen, 0, .{}, "waiting for `{s}` failed: {s}", .{ driver_name, @errorName(e) });
    };
    switch (term) {
        .exited => |code| if (code != 0) {
            return diags.fail(.codegen, 0, .{}, "linking {s} failed: {s} exited with {d}", .{ opts.out_path, driver_name, code });
        },
        else => return diags.fail(.codegen, 0, .{}, "linking {s} failed: {s} terminated abnormally", .{ opts.out_path, driver_name }),
    }
}

/// The target in Zig's triple spelling (arch-os[-abi]) for `zig cc -target`.
/// The ABI is always spelled for linux/windows so the choice doesn't ride on
/// zig's per-OS default (glibc unless --target said musl; mingw on windows
/// unless it said msvc).
fn zigTriple(arena: std.mem.Allocator, t: target_mod.Target) Error![]const u8 {
    const arch = switch (t.arch) {
        .amd64 => "x86_64",
        .arm64 => "aarch64",
        .riscv64 => "riscv64",
        .ppc64le => "powerpc64le",
        .s390x => "s390x",
    };
    return switch (t.os) {
        .darwin => try std.fmt.allocPrint(arena, "{s}-macos", .{arch}),
        .linux => try std.fmt.allocPrint(arena, "{s}-linux-{s}", .{
            arch, @as([]const u8, if (t.abi == .musl) "musl" else "gnu"),
        }),
        .windows => try std.fmt.allocPrint(arena, "{s}-windows-{s}", .{
            arch, @as([]const u8, if (t.abi == .msvc) "msvc" else "gnu"),
        }),
    };
}
