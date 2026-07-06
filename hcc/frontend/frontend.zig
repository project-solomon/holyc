//! The shared front-end pipeline: preprocess → parse → synthesize reflection
//! metadata → semantic analysis → layout. The CLI driver and the tests both
//! run compilations through this single entry point, mirroring the order of
//! the Go compiler's Parse().
//!
//! Every pass reports through the shared Diagnostics. On a sema or layout
//! failure run still returns error.CompileFailed, but the diagnostics carry
//! every error and warning the passes produced.

const std = @import("std");
const diag = @import("diag.zig");
const source = @import("source.zig");
const target_mod = @import("target.zig");
const ast = @import("ast.zig");
const Preprocessor = @import("Preprocessor.zig");
const Parser = @import("Parser.zig");
const Sema = @import("Sema.zig");
const reflect = @import("reflect.zig");
const layout = @import("layout.zig");

pub const Result = struct {
    /// The type-annotated, laid-out program.
    program: ast.Program,
};

pub const Options = struct {
    /// Directory that relative #include "..." paths in the top-level source
    /// resolve against; also fixes file 0's directory for privacy purposes.
    base_dir: []const u8 = ".",
    /// Seeds the predefined target macros (_WIN32/__linux__/…).
    target: target_mod.Target,
    /// Injects the implicit prelude ahead of the base source.
    inject_prelude: bool = true,
    /// When set, receives the source-file table (indexed by Diagnostic.file /
    /// span.file) even if compilation fails partway — so a driver can render
    /// file names on early lex/preprocess/parse errors, where no Program
    /// exists yet.
    files_out: ?*[]const source.FileInfo = null,
};

/// Runs the whole front end over src. The result's Expr types are annotated
/// in place and program.layouts is filled in.
pub fn run(
    arena: std.mem.Allocator,
    diags: *diag.Diagnostics,
    io: std.Io,
    src: []const u8,
    opts: Options,
) diag.Error!Result {
    var pp = try Preprocessor.init(arena, diags, io, src, .{
        .base_dir = opts.base_dir,
        .target = opts.target,
        .inject_prelude = opts.inject_prelude,
    });
    defer if (opts.files_out) |out| {
        out.* = pp.sourceFiles();
    };
    var parser = Parser.init(arena, diags, &pp);
    var program = try parser.parse();

    // Synthesize class-reflection tables (if Class/ClassRep is used), then
    // type-check, then compute aggregate layouts — the Go Parse() order.
    try reflect.synthReflectMeta(arena, &program);
    try Sema.check(arena, diags, &program);
    try layout.compute(arena, diags, &program);
    return .{ .program = program };
}
