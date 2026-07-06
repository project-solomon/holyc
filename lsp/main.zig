//! holyc-lsp: the HolyC language server, driven by the same compiler front
//! end as hcc (the `hcc` module without its LLVM backend linked).
//!
//! Speaks JSON-RPC 2.0 with LSP base-protocol framing over stdio: frames in
//! on stdin, frames out on stdout (nothing else ever goes to stdout), logs on
//! stderr. See Server.zig for the capability surface.

const std = @import("std");
const hcc = @import("hcc");
const Server = @import("Server.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var in_buf: [64 * 1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &in_buf);
    var out_buf: [64 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &out_buf);

    // The server is long-running: a general-purpose allocator, not the
    // process arena (which only ever grows).
    var server = Server.init(
        std.heap.smp_allocator,
        io,
        &stdin_reader.interface,
        &stdout_writer.interface,
    );
    defer server.deinit();

    const code = try server.run();
    std.process.exit(code);
}

test {
    // The front end is reachable without LLVM: keep this compiling.
    _ = hcc.frontend;
    _ = @import("framing.zig");
    _ = @import("uri.zig");
    _ = @import("position.zig");
    _ = @import("Server.zig");
    _ = @import("server_test.zig");
}
