//! Byte-offset ↔ LSP position conversion.
//!
//! LSP positions are 0-based line/character pairs where `character` counts
//! UTF-16 code units. HolyC sources are ASCII in practice, so this module
//! counts bytes instead: exact for ASCII, approximate for any stray
//! multi-byte UTF-8.

const std = @import("std");

pub const Position = struct {
    line: u32,
    character: u32,
};

/// Converts a byte offset into `text` to a 0-based line/character position.
/// Offsets past the end clamp to the last position.
pub fn offsetToPosition(text: []const u8, offset: usize) Position {
    const end = @min(offset, text.len);
    var line: u32 = 0;
    var line_start: usize = 0;
    for (text[0..end], 0..) |c, i| {
        if (c == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    return .{ .line = line, .character = @intCast(end - line_start) };
}

/// Converts a 0-based line/character position to a byte offset into `text`.
/// Positions past the end of a line clamp to the line end; lines past the end
/// of the text clamp to text.len.
pub fn positionToOffset(text: []const u8, pos: Position) usize {
    var i: usize = 0;
    var line: u32 = 0;
    while (line < pos.line) : (line += 1) {
        const nl = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse return text.len;
        i = nl + 1;
    }
    const line_end = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
    return @min(i + pos.character, line_end);
}

test offsetToPosition {
    const text = "abc\ndef\n\nxy";
    try std.testing.expectEqual(Position{ .line = 0, .character = 0 }, offsetToPosition(text, 0));
    try std.testing.expectEqual(Position{ .line = 0, .character = 2 }, offsetToPosition(text, 2));
    // The newline itself belongs to the line it ends.
    try std.testing.expectEqual(Position{ .line = 0, .character = 3 }, offsetToPosition(text, 3));
    try std.testing.expectEqual(Position{ .line = 1, .character = 0 }, offsetToPosition(text, 4));
    try std.testing.expectEqual(Position{ .line = 2, .character = 0 }, offsetToPosition(text, 8));
    try std.testing.expectEqual(Position{ .line = 3, .character = 2 }, offsetToPosition(text, 11));
    // Clamped past the end.
    try std.testing.expectEqual(Position{ .line = 3, .character = 2 }, offsetToPosition(text, 999));
}

test positionToOffset {
    const text = "abc\ndef\n\nxy";
    try std.testing.expectEqual(@as(usize, 0), positionToOffset(text, .{ .line = 0, .character = 0 }));
    try std.testing.expectEqual(@as(usize, 4), positionToOffset(text, .{ .line = 1, .character = 0 }));
    try std.testing.expectEqual(@as(usize, 6), positionToOffset(text, .{ .line = 1, .character = 2 }));
    // Character past the line end clamps to the line end, not into the next line.
    try std.testing.expectEqual(@as(usize, 7), positionToOffset(text, .{ .line = 1, .character = 99 }));
    try std.testing.expectEqual(@as(usize, 8), positionToOffset(text, .{ .line = 2, .character = 0 }));
    try std.testing.expectEqual(@as(usize, 11), positionToOffset(text, .{ .line = 3, .character = 99 }));
    // Line past the end clamps to text.len.
    try std.testing.expectEqual(@as(usize, 11), positionToOffset(text, .{ .line = 42, .character = 0 }));
}

test "round-trip on token starts" {
    const text = "I64 F() {\n  return 1;\n}\n";
    var offset: usize = 0;
    while (offset < text.len) : (offset += 1) {
        if (text[offset] == '\n') continue;
        const pos = offsetToPosition(text, offset);
        try std.testing.expectEqual(offset, positionToOffset(text, pos));
    }
}
