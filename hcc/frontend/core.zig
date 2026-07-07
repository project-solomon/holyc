//! The always-resident HolyC prelude: predefined constants, CTask (exceptions),
//! the print core (StrPrint), and reflection (KClass). Embedded into the hcc
//! binary from `hcc/frontend/core/`. The hosted runtime (heap, I/O, threads)
//! lives in the on-disk standard library (`std/`), opt-in per program.
//! The preprocessor injects the prelude ahead of every program
//! (`Preprocessor.injectPrelude`), resolving the prelude's own #includes against
//! this table. User code may not #include these files directly; they are
//! implicit and always in scope.

const std = @import("std");

/// The prelude's boot file, the #include list injection starts from.
pub const root = "Lib.HC";

pub const File = struct {
    /// Forward-slash path relative to the prelude root, as the prelude's own
    /// #includes spell it (e.g. "MAllocFree.HC").
    path: []const u8,
    contents: []const u8,
};

/// Every prelude file. Order mirrors Lib.HC's authored #include list for
/// readability; lookup is by path.
pub const files = [_]File{
    .{ .path = "Lib.HC", .contents = @embedFile("core/Lib.HC") },
    .{ .path = "KConfig.HC", .contents = @embedFile("core/KConfig.HC") },
    .{ .path = "CTask.HC", .contents = @embedFile("core/CTask.HC") },
    .{ .path = "StrPrint.HC", .contents = @embedFile("core/StrPrint.HC") },
    .{ .path = "KClass.HC", .contents = @embedFile("core/KClass.HC") },
};

/// The contents of the prelude file at an (already normalized, forward-slash)
/// path, or null.
pub fn get(path: []const u8) ?[]const u8 {
    for (&files) |*f| {
        if (std.mem.eql(u8, f.path, path)) return f.contents;
    }
    return null;
}

pub fn exists(path: []const u8) bool {
    return get(path) != null;
}

test "root file is present and non-empty" {
    try std.testing.expect(get(root).?.len > 0);
    try std.testing.expect(exists("StrPrint.HC"));
    try std.testing.expect(!exists("NotAFile.HC"));
}

test "table matches hcc/frontend/core/ on disk" {
    // Adding a prelude file without updating the table (or vice versa) must
    // fail. The build injects the absolute path of the package's src/ dir.
    const build_options = @import("build_options");
    const io = std.testing.io;
    var dir = try std.Io.Dir.openDirAbsolute(io, build_options.core_dir, .{ .iterate = true });
    defer dir.close(io);

    var count: usize = 0;
    var walker = try dir.walk(std.testing.allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        count += 1;
        var norm_buf: [256]u8 = undefined;
        const norm = norm_buf[0..entry.path.len];
        _ = std.mem.replace(u8, entry.path, std.fs.path.sep_str, "/", norm);
        try std.testing.expect(exists(norm));
    }
    try std.testing.expectEqual(files.len, count);
}
