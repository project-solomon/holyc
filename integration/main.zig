//! The integration harness: a standalone black-box test driver with no code
//! dependency on the compiler. It invokes the installed `hcc` from the PATH
//! (run install.sh to build and install it from source), compiles every
//! fixture in the testdata directory with it, runs each produced executable,
//! and byte-compares its stdout against the reviewed golden `<fixture>.out`.
//!
//! Usage: integration <testdata-dir>
//!
//! Fixtures run in sorted order with a live progress line each (compile and
//! run timings); failures print their detail immediately, and the run ends
//! with a timed summary.
//!
//! Fixtures are the contract and are never edited or skipped to make a run
//! pass; if a fixture legitimately needs different behavior, the harness
//! compiles/runs that file with different hcc CLI arguments instead.
//!
//! Host target only; exit codes of the fixture binaries are not compared —
//! goldens are stdout only, matching the retired Go conform_test.go. Exits 0
//! iff every fixture matches its golden.

const std = @import("std");

const usage = "usage: integration <testdata-dir>\n";

/// The compiler under test, resolved from the PATH at spawn time (install it
/// with install.sh).
const hcc = "hcc";

/// Scratch dir for the compiled fixture executables: deterministic, inside
/// the (gitignored) zig-out, wiped before and after a run.
const tmp_dir_path = "zig-out/integration-tmp";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const out = &stderr_writer.interface;
    defer out.flush() catch {};

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // argv[0]
    const testdata_dir = args.next() orelse {
        try out.writeAll(usage);
        try out.flush();
        std.process.exit(2);
    };

    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, testdata_dir, .{ .iterate = true }) catch |e| {
        try out.print("integration: cannot open testdata dir {s}: {s}\n", .{ testdata_dir, @errorName(e) });
        try out.flush();
        std.process.exit(2);
    };
    defer dir.close(io);

    // Collect and sort the fixture names first: deterministic run order, a
    // real total for the header, and a column width for aligned output.
    var names: std.ArrayList([]const u8) = .empty;
    var max_name_len: usize = 0;
    {
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".HC")) continue;
            const name = try arena.dupe(u8, entry.name);
            try names.append(arena, name);
            max_name_len = @max(max_name_len, name.len);
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    if (names.items.len == 0) {
        try out.print("integration: no .HC fixtures found in {s}\n", .{testdata_dir});
        try out.flush();
        std.process.exit(2);
    }

    try out.print("integration: {s} (from PATH) over {s} — {d} fixtures\n", .{ hcc, testdata_dir, names.items.len });
    try out.flush();

    cwd.deleteTree(io, tmp_dir_path) catch {};
    try cwd.createDirPath(io, tmp_dir_path);
    defer cwd.deleteTree(io, tmp_dir_path) catch {};

    const t_start = std.Io.Clock.Timestamp.now(io, .awake);
    var passed: usize = 0;
    var failed: usize = 0;
    for (names.items, 1..) |name, i| {
        var arena_state = std.heap.ArenaAllocator.init(init.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();

        const stem = name[0 .. name.len - ".HC".len];
        const src_path = try std.fs.path.join(a, &.{ testdata_dir, name });
        const golden_name = try std.fmt.allocPrint(a, "{s}.out", .{stem});
        const golden = try dir.readFileAlloc(io, golden_name, a, .limited(16 << 20));

        // The progress prefix goes out before the work so a hang is
        // attributable to a fixture.
        try out.print("  [{d:>2}/{d}] {s}", .{ i, names.items.len, name });
        try padTo(out, name.len, max_name_len);
        try out.flush();

        // Compile with the driver under test.
        const exe_path = try std.fs.path.join(a, &.{ tmp_dir_path, stem });
        const t0 = std.Io.Clock.Timestamp.now(io, .awake);
        const compile = std.process.run(a, io, .{
            .argv = &.{ hcc, "-o", exe_path, src_path },
            .stdout_limit = .limited(1 << 20),
            .stderr_limit = .limited(1 << 20),
        }) catch |e| {
            try out.print("  FAIL\n  spawning {s} failed: {s} (is hcc installed? run install.sh)\n", .{ hcc, @errorName(e) });
            failed += 1;
            continue;
        };
        const t_compiled = std.Io.Clock.Timestamp.now(io, .awake);
        const compiled_ok = switch (compile.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!compiled_ok) {
            try out.print("  FAIL (compile)\n{s}", .{compile.stderr});
            failed += 1;
            continue;
        }

        // Run the produced binary and collect stdout (std.process.run drains
        // the pipes before waiting, so a large output cannot deadlock).
        const run_result = std.process.run(a, io, .{
            .argv = &.{exe_path},
            .stdout_limit = .limited(16 << 20),
        }) catch |e| {
            try out.print("  FAIL (run): {s}\n", .{@errorName(e)});
            failed += 1;
            continue;
        };
        const t_ran = std.Io.Clock.Timestamp.now(io, .awake);

        // Byte-compare against the golden (stdout only, like Go).
        if (!std.mem.eql(u8, run_result.stdout, golden)) {
            try out.writeAll("  FAIL (golden mismatch)\n");
            try reportDiff(out, name, golden, run_result.stdout);
            failed += 1;
            continue;
        }
        passed += 1;
        try out.writeAll("  ok");
        try printMs(out, t0.durationTo(t_compiled), " compile");
        try printMs(out, t_compiled.durationTo(t_ran), " run");
        try out.print("  {d}B out\n", .{run_result.stdout.len});
        try out.flush();
    }

    const total = t_start.durationTo(std.Io.Clock.Timestamp.now(io, .awake));
    const total_s = @as(f64, @floatFromInt(total.raw.toNanoseconds())) / 1e9;
    try out.print("integration: {d} passed, {d} failed in {d:.1}s\n", .{ passed, failed, total_s });
    try out.flush();
    if (failed > 0) std.process.exit(1);
}

/// Pads the fixture name column so the ok/FAIL verdicts align.
fn padTo(w: *std.Io.Writer, len: usize, width: usize) !void {
    var i = len;
    while (i < width) : (i += 1) try w.writeByte(' ');
}

/// Prints a duration in whole milliseconds with a label, e.g. " 41ms compile".
fn printMs(w: *std.Io.Writer, d: std.Io.Clock.Duration, label: []const u8) !void {
    const ns = d.raw.toNanoseconds();
    const ms: u64 = @intCast(@divTrunc(@max(0, ns), std.time.ns_per_ms));
    try w.print("  {d:>4}ms{s}", .{ ms, label });
}

/// Renders a byte-exact first-difference report for a golden mismatch.
fn reportDiff(w: *std.Io.Writer, name: []const u8, want: []const u8, got: []const u8) !void {
    var i: usize = 0;
    const n = @min(want.len, got.len);
    while (i < n and want[i] == got[i]) i += 1;
    const lo = if (i > 24) i - 24 else 0;
    try w.print(
        \\fixture {s}: output disagrees with the golden
        \\  want ({d} bytes), got ({d} bytes), first difference at byte {d}
        \\  want[{d}..]: "{f}"
        \\  got [{d}..]: "{f}"
        \\
    , .{
        name,    want.len,
        got.len, i,
        lo,      std.zig.fmtString(want[lo..@min(want.len, i + 48)]),
        lo,      std.zig.fmtString(got[lo..@min(got.len, i + 48)]),
    });
}
