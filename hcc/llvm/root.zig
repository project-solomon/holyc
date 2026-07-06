//! The LLVM backend as its own module: bindings for the LLVM-C API, the
//! AST→LLVM-IR lowering, and the emit pipeline (verify → optimize → object →
//! link). This is the only module that links libLLVM (see build.zig); it
//! consumes the checked AST through the `hcc` front-end module.
//!
//! Note: no source FILE in here may be named llvm.zig — Zig mangles decls as
//! "<file>.<decl>", and LLVM rejects symbols in its reserved "llvm." intrinsic
//! namespace. The directory name is fine, as are c.zig and backend.zig.

pub const c = @import("c.zig");
pub const lower = @import("lower.zig");

const backend = @import("backend.zig");
pub const Error = backend.Error;
pub const EmitKind = backend.EmitKind;
pub const Options = backend.Options;
pub const emit = backend.emit;

test {
    @import("std").testing.refAllDecls(@This());
}
