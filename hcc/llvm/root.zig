//! The LLVM backend module: LLVM-C API bindings, AST→LLVM-IR lowering, and the
//! emit pipeline (verify, optimize, object, link). The only module that links
//! libLLVM (see build.zig); it consumes the checked AST from the `hcc` module.
//!
//! No source file here may be named llvm.zig: Zig mangles decls as
//! "<file>.<decl>", and LLVM rejects symbols in its reserved "llvm." intrinsic
//! namespace. The directory name, c.zig, and backend.zig are fine.

pub const c = @import("c.zig");
pub const lower = @import("lower.zig");

const backend = @import("backend.zig");
pub const Error = backend.Error;
pub const EmitKind = backend.EmitKind;
pub const Options = backend.Options;
pub const emit = backend.emit;
pub const emitObject = backend.emitObject;
pub const linkObject = backend.linkObject;
pub const llvmVersion = backend.llvmVersion;

test {
    @import("std").testing.refAllDecls(@This());
}
