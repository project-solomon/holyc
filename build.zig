const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Test-only configuration: the core-table drift test compares the
    // embedded file table against this directory on disk (absolute path — the
    // test binary does not run from the package root).
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "core_dir", b.pathFromRoot("hcc/frontend/core"));

    // Where the system LLVM lives (needs LLVM >= 21 with libLLVM). Only the
    // backend module links it.
    const llvm_prefix = b.option(
        []const u8,
        "llvm-prefix",
        "LLVM installation prefix (default: /opt/homebrew/opt/llvm@21)",
    ) orelse "/opt/homebrew/opt/llvm@21";

    // The front end as a reusable module: lex → preprocess → parse → reflect →
    // check → layout. Links nothing; the CLI, the backend, the language
    // server, and the e2e harness all consume it as "hcc".
    const frontend_mod = b.addModule("frontend", .{
        .root_source_file = b.path("hcc/frontend/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    frontend_mod.addImport("build_options", build_options.createModule());

    // The LLVM backend as its own module: the only place libLLVM is linked.
    const llvm_mod = b.addModule("llvm", .{
        .root_source_file = b.path("hcc/llvm/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hcc", .module = frontend_mod },
        },
    });
    // Dynamic linking against the system libLLVM is a deliberate, settled
    // choice (no static-LLVM build option): hcc stays a small binary, shares
    // the dylib with the rest of the LLVM toolchain on the machine, and
    // running it simply requires the LLVM install named by -Dllvm-prefix.
    const llvm_lib_dir = b.pathJoin(&.{ llvm_prefix, "lib" });
    llvm_mod.addLibraryPath(.{ .cwd_relative = llvm_lib_dir });
    if (target.result.os.tag == .windows) {
        // Windows LLVM packagings name the import library differently (MinGW:
        // libLLVM.dll.a or libLLVM-C.dll.a; MSVC: LLVM-C.lib), and none match
        // linkSystemLibrary's name search. Find whichever exists and link it by
        // path. Windows has no rpath, so the libLLVM DLL must be on PATH (or
        // beside the exe) at run time.
        const import_lib = findWindowsLlvmLib(b, llvm_lib_dir);
        llvm_mod.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ llvm_lib_dir, import_lib }) });
    } else {
        llvm_mod.addRPath(.{ .cwd_relative = llvm_lib_dir });
        llvm_mod.linkSystemLibrary("LLVM", .{});
    }
    llvm_mod.link_libc = true;

    const exe = b.addExecutable(.{
        .name = "hcc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("hcc/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hcc", .module = frontend_mod },
                .{ .name = "llvm", .module = llvm_mod },
            },
        }),
    });
    b.installArtifact(exe);

    // The standard library ships as on-disk source inside the self-contained
    // toolchain tree, at <root>/std — where hcc discovers it as HCC_ROOT/std
    // (HCC_ROOT being the parent of its own bin dir). Installing it under the
    // build prefix means a bare `zig build` yields a self-consistent tree:
    // zig-out/bin/hcc resolves #include <Str.HC> against zig-out/std, no install.
    const std_install = b.addInstallDirectory(.{
        .source_dir = b.path("std"),
        .install_dir = .prefix,
        .install_subdir = "std",
    });
    b.getInstallStep().dependOn(&std_install.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Build and run the hcc driver");
    run_step.dependOn(&run_cmd.step);

    // holyc-lsp: the language server, driven by the front end alone — it
    // builds and runs on machines with no LLVM.
    const lsp_mod = b.createModule(.{
        .root_source_file = b.path("lsp/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hcc", .module = frontend_mod },
        },
    });
    const lsp_exe = b.addExecutable(.{
        .name = "holyc-lsp",
        .root_module = lsp_mod,
    });
    b.installArtifact(lsp_exe);

    // Per-artifact steps for the install scripts: `zig build hcc` / `zig
    // build lsp` build and install just that binary. An LSP-only install
    // (install.sh --lsp) must work on machines with no LLVM, so it cannot go
    // through the default install step, which links hcc against libLLVM.
    const hcc_step = b.step("hcc", "Build and install only the hcc compiler");
    hcc_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    hcc_step.dependOn(&std_install.step); // ship the stdlib source with hcc
    const lsp_step = b.step("lsp", "Build and install only the holyc-lsp language server (no LLVM needed)");
    lsp_step.dependOn(&b.addInstallArtifact(lsp_exe, .{}).step);

    const frontend_tests = b.addTest(.{ .root_module = frontend_mod });
    const run_frontend_tests = b.addRunArtifact(frontend_tests);
    const llvm_tests = b.addTest(.{ .root_module = llvm_mod });
    const run_llvm_tests = b.addRunArtifact(llvm_tests);
    const lsp_tests = b.addTest(.{ .root_module = lsp_mod });
    const run_lsp_tests = b.addRunArtifact(lsp_tests);

    // The e2e harness: a standalone black-box driver with NO code
    // dependency on the compiler — it invokes the installed `hcc` from the
    // PATH (install.sh builds and installs it; the Makefile's `test` target
    // wires the two together) and reads the fixtures from disk.
    const e2e_exe = b.addExecutable(.{
        .name = "e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("e2e/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(e2e_exe);

    // The benchmark harness: same standalone shape as e2e — it
    // invokes the installed `hcc` from the PATH (the Makefile's `bench`
    // target) and times it against clang -O0..-O3 over .HC/.c fixture pairs.
    // Always ReleaseFast: the harness itself must not add measurement noise.
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    b.installArtifact(bench_exe);

    const test_step = b.step("test", "Run the frontend, backend, and LSP unit tests (see `make test` for the fixture e2e run)");
    test_step.dependOn(&run_frontend_tests.step);
    test_step.dependOn(&run_llvm_tests.step);
    test_step.dependOn(&run_lsp_tests.step);
}

/// Picks the LLVM import library to link on Windows by scanning lib_dir, since
/// its name varies by packaging. Prefers a dynamic import lib (`.dll.a`) — hcc
/// links libLLVM dynamically — and the whole-library over the C-API-only one,
/// falling back to an MSVC `.lib`. Fails with a listing when none is found, so
/// the build log names what is actually present.
fn findWindowsLlvmLib(b: *std.Build, lib_dir: []const u8) []const u8 {
    const io = b.graph.io;
    var dir = std.Io.Dir.openDirAbsolute(io, lib_dir, .{ .iterate = true }) catch |e|
        std.debug.panic("cannot open LLVM lib dir {s}: {s}", .{ lib_dir, @errorName(e) });
    defer dir.close(io);

    var best: ?[]const u8 = null;
    var best_rank: u8 = 0;
    var present: std.ArrayList(u8) = .empty; // LLVM files seen, for the error
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.indexOf(u8, entry.name, "LLVM") == null) continue;
        present.append(b.allocator, ' ') catch {};
        present.appendSlice(b.allocator, entry.name) catch {};
        const rank: u8 =
            if (std.mem.eql(u8, entry.name, "libLLVM.dll.a")) 5 else if (std.mem.eql(u8, entry.name, "libLLVM-C.dll.a")) 4 else if (std.mem.endsWith(u8, entry.name, ".dll.a")) 3 else if (std.mem.eql(u8, entry.name, "LLVM-C.lib")) 2 else if (std.mem.eql(u8, entry.name, "LLVM.lib")) 1 else 0;
        if (rank > best_rank) {
            best_rank = rank;
            best = b.allocator.dupe(u8, entry.name) catch @panic("OOM");
        }
    }
    return best orelse std.debug.panic(
        "no LLVM import library found in {s}. LLVM files present:{s}",
        .{ lib_dir, present.items },
    );
}
