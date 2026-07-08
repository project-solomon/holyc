//! Benchmark harness: standalone driver, no code dependency on the compiler.
//! Invokes the installed `hcc` from PATH (run install.sh) and `clang`. Each
//! case in the benchmarks directory is a `<stem>.HC` / `<stem>.c` pair of the
//! same workload; compiles the HolyC side with hcc and the C side with clang
//! at every optimization level, then reports the target (the host; neither
//! compiler cross-compiles) and two tables of mean wall-clock times, one for
//! execution and one for compilation. Ratios are hcc/clang (above 1.00x, hcc
//! is slower). Outputs are not compared; timing only.
//!
//! Usage: bench <benchmarks-dir>

const std = @import("std");

const usage = "usage: bench <benchmarks-dir>\n";

/// Compiler under test, resolved from PATH at spawn time (install.sh).
const hcc = "hcc";

/// Scratch dir for compiled fixture executables: deterministic, inside the
/// (gitignored) zig-out, wiped before and after a run.
const tmp_dir_path = "zig-out/bench-tmp";

/// clang optimization levels to compare against. -O4 is an alias for -O3, so
/// the ladder stops there.
const opt_levels = [_][]const u8{ "-O0", "-O1", "-O2", "-O3" };

/// Column 0 is hcc; the rest are clang at each optimization level.
const n_cols = 1 + opt_levels.len;

/// Timed repetitions per command (each preceded by one untimed warmup).
const compile_runs = 3;
const exec_runs = 5;

const Row = struct {
    name: []const u8,
    compile_ms: [n_cols]f64,
    exec_ms: [n_cols]f64,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // argv[0]
    const benchmarks_dir = args.next() orelse {
        try stderr.writeAll(usage);
        try stderr.flush();
        std.process.exit(2);
    };

    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, benchmarks_dir, .{ .iterate = true }) catch |e| {
        try stderr.print("bench: cannot open benchmarks dir {s}: {s}\n", .{ benchmarks_dir, @errorName(e) });
        try stderr.flush();
        std.process.exit(2);
    };
    defer dir.close(io);

    // Pair up <stem>.HC / <stem>.c files; benchmarked only when both sides
    // exist.
    var hc_stems: std.ArrayList([]const u8) = .empty;
    var c_stems: std.StringHashMapUnmanaged(void) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".HC")) {
            try hc_stems.append(a, try a.dupe(u8, entry.name[0 .. entry.name.len - ".HC".len]));
        } else if (std.mem.endsWith(u8, entry.name, ".c")) {
            try c_stems.put(a, try a.dupe(u8, entry.name[0 .. entry.name.len - ".c".len]), {});
        }
    }
    var stems: std.ArrayList([]const u8) = .empty;
    for (hc_stems.items) |stem| {
        if (c_stems.contains(stem)) {
            try stems.append(a, stem);
        } else {
            try stderr.print("bench: {s}.HC has no {s}.c counterpart, skipping\n", .{ stem, stem });
        }
    }
    if (stems.items.len == 0) {
        try stderr.print("bench: no .HC/.c fixture pairs found in {s}\n", .{benchmarks_dir});
        try stderr.flush();
        std.process.exit(2);
    }
    std.mem.sort([]const u8, stems.items, {}, stringLessThan);

    // The target both compilers build for. Neither cross-compiles (no --target
    // is passed), so both target the host; clang's -dumpmachine is the
    // authoritative triple for that machine.
    const target = try hostTriple(a, io);
    try stderr.print("bench: target {s} (host)\n", .{target});
    try stderr.flush();

    cwd.deleteTree(io, tmp_dir_path) catch {};
    try cwd.createDirPath(io, tmp_dir_path);
    defer cwd.deleteTree(io, tmp_dir_path) catch {};

    var rows: std.ArrayList(Row) = .empty;
    for (stems.items) |stem| {
        try stderr.print("bench: {s}\n", .{stem});
        try stderr.flush();

        const hc_src = try std.fs.path.join(a, &.{ benchmarks_dir, try std.fmt.allocPrint(a, "{s}.HC", .{stem}) });
        const c_src = try std.fs.path.join(a, &.{ benchmarks_dir, try std.fmt.allocPrint(a, "{s}.c", .{stem}) });

        var row: Row = .{ .name = stem, .compile_ms = undefined, .exec_ms = undefined };

        // Column 0: hcc. Remaining columns: clang at each -O level.
        var exes: [n_cols][]const u8 = undefined;
        exes[0] = try std.fs.path.join(a, &.{ tmp_dir_path, try std.fmt.allocPrint(a, "{s}.hcc", .{stem}) });
        row.compile_ms[0] = try timedMeanMs(a, io, stderr, &.{ hcc, "-o", exes[0], hc_src }, compile_runs);
        for (opt_levels, 1..) |level, col| {
            exes[col] = try std.fs.path.join(a, &.{ tmp_dir_path, try std.fmt.allocPrint(a, "{s}{s}", .{ stem, level }) });
            row.compile_ms[col] = try timedMeanMs(a, io, stderr, &.{ "clang", level, "-o", exes[col], c_src }, compile_runs);
        }
        for (exes, 0..) |exe, col| {
            row.exec_ms[col] = try timedMeanMs(a, io, stderr, &.{exe}, exec_runs);
        }
        try rows.append(a, row);
    }

    try stdout.print("target: {s} (host; hcc and clang default, no cross-compile)\n\n", .{target});
    try printTable(stdout, "Compile time", compile_runs, rows.items, .compile);
    try stdout.writeAll("\n");
    try printTable(stdout, "Execution time", exec_runs, rows.items, .exec);
    try stdout.flush();
}

fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

/// Host target triple both compilers build for, from `clang -dumpmachine`
/// (clang is required for the C side anyway). "unknown" if clang can't be
/// queried.
fn hostTriple(a: std.mem.Allocator, io: std.Io) ![]const u8 {
    const result = std.process.run(a, io, .{
        .argv = &.{ "clang", "-dumpmachine" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return "unknown";
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) return "unknown";
    return std.mem.trim(u8, result.stdout, " \t\r\n");
}

/// Runs argv once untimed (warmup), then `runs` more times, returning the mean
/// wall-clock duration in ms. Any non-zero exit aborts the whole bench run: a
/// fixture that fails to compile or crashes would otherwise skew the tables.
fn timedMeanMs(
    a: std.mem.Allocator,
    io: std.Io,
    stderr: *std.Io.Writer,
    argv: []const []const u8,
    runs: usize,
) !f64 {
    try runChecked(a, io, stderr, argv);
    var total_ns: f64 = 0;
    for (0..runs) |_| {
        const t0 = std.Io.Clock.now(.awake, io);
        try runChecked(a, io, stderr, argv);
        const t1 = std.Io.Clock.now(.awake, io);
        total_ns += @floatFromInt(t0.durationTo(t1).nanoseconds);
    }
    return total_ns / @as(f64, @floatFromInt(runs)) / std.time.ns_per_ms;
}

fn runChecked(
    a: std.mem.Allocator,
    io: std.Io,
    stderr: *std.Io.Writer,
    argv: []const []const u8,
) !void {
    const result = std.process.run(a, io, .{
        .argv = argv,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch |e| {
        try stderr.print("bench: spawning {s} failed: {s}\n", .{ argv[0], @errorName(e) });
        try stderr.flush();
        return error.CommandFailed;
    };
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        try stderr.print("bench: command {s} failed:\n{s}", .{ argv[0], result.stderr });
        try stderr.flush();
        return error.CommandFailed;
    }
}

fn printTable(
    w: *std.Io.Writer,
    title: []const u8,
    runs: usize,
    rows: []const Row,
    which: enum { exec, compile },
) !void {
    try w.print("{s} (mean of {d} runs, ms; ratio is hcc/clang — above 1.00x hcc is slower)\n", .{ title, runs });

    var name_w: usize = "fixture".len;
    for (rows) |row| name_w = @max(name_w, row.name.len);

    // hcc is the baseline column; clang columns are wider to fit the ratio.
    const clang_w = 10 + 1 + "(99.99x)".len;
    try w.print("{s:<[1]}", .{ "fixture", name_w });
    try w.print("  {s:>10}", .{"hcc"});
    for (opt_levels) |level| {
        var buf: [16]u8 = undefined;
        const header = try std.fmt.bufPrint(&buf, "clang {s}", .{level});
        try w.print("  {s:>[1]}", .{ header, clang_w });
    }
    try w.writeAll("\n");

    for (rows) |row| {
        const ms = switch (which) {
            .exec => row.exec_ms,
            .compile => row.compile_ms,
        };
        try w.print("{s:<[1]}", .{ row.name, name_w });
        try w.print("  {d:>10.2}", .{ms[0]});
        for (ms[1..]) |v| {
            var buf: [32]u8 = undefined;
            const cell = try std.fmt.bufPrint(&buf, "{d:.2} ({d:.2}x)", .{ v, ms[0] / v });
            try w.print("  {s:>[1]}", .{ cell, clang_w });
        }
        try w.writeAll("\n");
    }
}
