//! The HolyC compiler front end as a reusable module: lex, preprocess, parse,
//! reflect, check, layout. The `hcc` CLI drives it and hands the checked
//! program to the `llvm` backend module; the language server and the
//! integration harness consume it directly. Links nothing (no LLVM).

pub const source = @import("source.zig");
pub const diag = @import("diag.zig");
pub const token = @import("token.zig");
pub const Lexer = @import("Lexer.zig");
pub const target = @import("target.zig");
pub const core = @import("core.zig");
pub const Preprocessor = @import("Preprocessor.zig");
pub const ast = @import("ast.zig");
pub const asm_regs = @import("asm_regs.zig");
pub const Parser = @import("Parser.zig");
pub const layout = @import("layout.zig");
pub const Sema = @import("Sema.zig");
pub const reflect = @import("reflect.zig");
pub const frontend = @import("frontend.zig");
pub const ast_render = @import("ast_render.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
