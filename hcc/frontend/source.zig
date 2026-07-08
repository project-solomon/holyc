//! Source locations: positions, spans, and per-file identity for diagnostics
//! and `_`-privacy.

const std = @import("std");

/// A position in a source file. Line and col are 1-based.
pub const Pos = struct {
    line: u32 = 1,
    col: u32 = 1,

    pub fn format(p: Pos, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}:{d}", .{ p.line, p.col });
    }
};

/// A half-open span [start, end) of byte offsets into a source file, with the
/// start position for diagnostics.
pub const Span = struct {
    start: usize = 0,
    end: usize = 0,
    pos: Pos = .{},
    /// Indexes the program's file table: which source file this span came from.
    /// The lexer leaves it 0 (root/top-level source); the preprocessor stamps
    /// the real id onto every token it emits from an #include frame.
    file: u32 = 0,

    pub fn format(s: Span, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}..{d}@{f}", .{ s.start, s.end, s.pos });
    }
};

/// Identifies a source file for diagnostics and `_`-privacy.
pub const FileInfo = struct {
    /// Directory components (no filename). Two files share visibility of
    /// non-public symbols iff their dirs are equal.
    dir: []const []const u8 = &.{},
    /// The file's name (empty for the top-level source), for diagnostics.
    name: []const u8 = "",

    pub fn format(fi: FileInfo, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (fi.dir.len == 0 and fi.name.len == 0) {
            try w.writeAll("<input>");
            return;
        }
        for (fi.dir, 0..) |part, i| {
            if (i > 0) try w.writeByte('/');
            try w.writeAll(part);
        }
        if (fi.name.len > 0) {
            if (fi.dir.len > 0) try w.writeByte('/');
            try w.writeAll(fi.name);
        }
    }

    pub fn eqlDir(a: FileInfo, b: FileInfo) bool {
        if (a.dir.len != b.dir.len) return false;
        for (a.dir, b.dir) |x, y| {
            if (!std.mem.eql(u8, x, y)) return false;
        }
        return true;
    }
};

test "FileInfo formatting" {
    var buf: [64]u8 = undefined;
    const empty: FileInfo = .{};
    try std.testing.expectEqualStrings("<input>", try std.fmt.bufPrint(&buf, "{f}", .{empty}));
    const nested: FileInfo = .{ .dir = &.{ "a", "b" }, .name = "c.HC" };
    try std.testing.expectEqualStrings("a/b/c.HC", try std.fmt.bufPrint(&buf, "{f}", .{nested}));
}
