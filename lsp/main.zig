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

    // The angle-bracket #include search path (HCC_ROOT/pkg, HCC_ROOT/std),
    // resolved the same way hcc does, so the editor sees the standard library
    // and third-party packages. Lives for the server's lifetime; best-effort
    // (a path that cannot be resolved leaves std includes unresolved).
    var include_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer include_arena.deinit();
    server.include_path = Server.computeIncludePath(include_arena.allocator(), io, init.environ_map) catch &.{};

    // Where the embedded core is extracted so go-to-definition can jump into
    // it (`<HCC_ROOT>/.cache/core`). gpa-owned; freed in server.deinit.
    server.core_cache_dir = Server.coreCacheDir(std.heap.smp_allocator, io, init.environ_map);

    const code = try server.run();
    std.process.exit(code);
}

test {
    // The front end is reachable without LLVM: keep this compiling.
    _ = hcc.frontend;
    _ = @import("framing.zig");
    _ = @import("uri.zig");
    _ = @import("position.zig");
    _ = @import("nav.zig");
    _ = @import("Server.zig");
    _ = @import("server_test.zig");
}
