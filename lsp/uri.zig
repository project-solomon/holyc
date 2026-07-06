//! Document URI helpers: extracting a filesystem path from a file:// URI.

const std = @import("std");

/// Extracts the percent-decoded filesystem path from a file:// URI, allocated
/// with `gpa` (caller frees). Returns null for non-file URIs (untitled:, ...).
pub fn filePath(gpa: std.mem.Allocator, uri: []const u8) error{OutOfMemory}!?[]u8 {
    const scheme = "file://";
    if (!std.ascii.startsWithIgnoreCase(uri, scheme)) return null;
    var rest = uri[scheme.len..];
    // Skip an authority component (usually empty: file:///...) if present.
    if (rest.len > 0 and rest[0] != '/') {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        rest = rest[slash..];
    }
    return try percentDecode(gpa, rest);
}

/// Decodes %XX escapes; malformed escapes pass through verbatim.
pub fn percentDecode(gpa: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |byte| {
                try out.append(gpa, byte);
                i += 3;
                continue;
            } else |_| {}
        }
        try out.append(gpa, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

test "file URI with percent-encoded spaces decodes correctly" {
    const gpa = std.testing.allocator;
    const path = (try filePath(gpa, "file:///path%20with%20spaces/main.HC")).?;
    defer gpa.free(path);
    try std.testing.expectEqualStrings("/path with spaces/main.HC", path);
}

test "non-file URIs and authorities" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(@as(?[]u8, null), try filePath(gpa, "untitled:Untitled-1"));

    const with_authority = (try filePath(gpa, "file://localhost/tmp/a.HC")).?;
    defer gpa.free(with_authority);
    try std.testing.expectEqualStrings("/tmp/a.HC", with_authority);
}

test "malformed percent escapes pass through" {
    const gpa = std.testing.allocator;
    const s = try percentDecode(gpa, "a%2xb%2");
    defer gpa.free(s);
    try std.testing.expectEqualStrings("a%2xb%2", s);
}
