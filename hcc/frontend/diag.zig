//! Compilation diagnostics. Zig errors carry no payload, so every pass reports
//! through a shared `Diagnostics` list and returns `error.CompileFailed`: the
//! lexer, preprocessor, and parser stop at their first error; sema and layout
//! collect as many as they can before failing at the end. Warnings never fail
//! a compilation.

const std = @import("std");
const source = @import("source.zig");

pub const Severity = enum { @"error", warning };

/// Which pass raised a diagnostic; preserved so callers can tell layers apart.
pub const Stage = enum { lex, preproc, parse, sema, layout, codegen };

pub const Diagnostic = struct {
    severity: Severity,
    stage: Stage,
    /// Indexes the program's file table (0 = the root/top-level source).
    file: u32,
    pos: source.Pos,
    message: []const u8,
};

pub const Error = error{ CompileFailed, OutOfMemory };

/// The append-only diagnostics sink for one compilation. Messages are
/// formatted into the compilation arena.
pub const Diagnostics = struct {
    arena: std.mem.Allocator,
    list: std.ArrayList(Diagnostic) = .empty,

    pub fn init(arena: std.mem.Allocator) Diagnostics {
        return .{ .arena = arena };
    }

    /// Records an error and returns `error.CompileFailed`, so a first-error
    /// pass can `return diags.fail(...)` in one step.
    pub fn fail(
        d: *Diagnostics,
        stage: Stage,
        file: u32,
        pos: source.Pos,
        comptime fmt: []const u8,
        args: anytype,
    ) Error {
        try d.add(.@"error", stage, file, pos, fmt, args);
        return error.CompileFailed;
    }

    pub fn warn(
        d: *Diagnostics,
        stage: Stage,
        file: u32,
        pos: source.Pos,
        comptime fmt: []const u8,
        args: anytype,
    ) error{OutOfMemory}!void {
        try d.add(.warning, stage, file, pos, fmt, args);
    }

    pub fn add(
        d: *Diagnostics,
        severity: Severity,
        stage: Stage,
        file: u32,
        pos: source.Pos,
        comptime fmt: []const u8,
        args: anytype,
    ) error{OutOfMemory}!void {
        try d.list.append(d.arena, .{
            .severity = severity,
            .stage = stage,
            .file = file,
            .pos = pos,
            .message = try std.fmt.allocPrint(d.arena, fmt, args),
        });
    }

    pub fn hasErrors(d: *const Diagnostics) bool {
        for (d.list.items) |item| {
            if (item.severity == .@"error") return true;
        }
        return false;
    }

    /// The first error, for callers that surface a single message.
    pub fn firstError(d: *const Diagnostics) ?Diagnostic {
        for (d.list.items) |item| {
            if (item.severity == .@"error") return item;
        }
        return null;
    }
};

test "diagnostics collect and classify" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diags = Diagnostics.init(arena_state.allocator());

    try diags.warn(.sema, 0, .{ .line = 1, .col = 2 }, "unused variable `{s}`", .{"x"});
    try std.testing.expect(!diags.hasErrors());

    const err: Error!void = diags.fail(.parse, 0, .{ .line = 3, .col = 4 }, "expected `{s}`", .{";"});
    try std.testing.expectError(error.CompileFailed, err);
    try std.testing.expect(diags.hasErrors());
    try std.testing.expectEqualStrings("expected `;`", diags.firstError().?.message);
    try std.testing.expectEqual(Stage.parse, diags.firstError().?.stage);
}
