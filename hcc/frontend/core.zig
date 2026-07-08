//! The always-resident HolyC core: predefined constants, CTask (exceptions),
//! the print core (StrPrint), and reflection (KClass). Embedded into the hcc
//! binary from `hcc/frontend/core/`. The hosted runtime (heap, I/O, threads)
//! lives in the on-disk standard library (`std/`), opt-in per program.
//!
//! The preprocessor injects the core ahead of every program
//! (`Preprocessor.injectCore`) by pushing each file in this table as a source
//! frame. User code may not #include these files directly; they are implicit and
//! always in scope.

const std = @import("std");

pub const File = struct {
    /// Forward-slash path relative to the core root, as the core's own #includes
    /// spell it (e.g. "MAllocFree.HC").
    path: []const u8,
    contents: []const u8,
};

/// Every core file, in boot order: injectCore injects them in this order, so
/// KConfig (NULL/TRUE/FALSE and the other macros) must come first. Lookup is by
/// path.
pub const files = [_]File{
    .{ .path = "KConfig.HC", .contents = @embedFile("core/KConfig.HC") },
    .{ .path = "CTask.HC", .contents = @embedFile("core/CTask.HC") },
    .{ .path = "StrPrint.HC", .contents = @embedFile("core/StrPrint.HC") },
    .{ .path = "KClass.HC", .contents = @embedFile("core/KClass.HC") },
};

/// Contents of the core file at an (already normalized, forward-slash) path, or
/// null.
pub fn get(path: []const u8) ?[]const u8 {
    for (&files) |*f| {
        if (std.mem.eql(u8, f.path, path)) return f.contents;
    }
    return null;
}

pub fn exists(path: []const u8) bool {
    return get(path) != null;
}

test "core files are present and non-empty" {
    try std.testing.expect(files.len > 0);
    try std.testing.expect(get("KConfig.HC").?.len > 0);
    try std.testing.expect(exists("StrPrint.HC"));
    try std.testing.expect(!exists("NotAFile.HC"));
}

test "table matches hcc/frontend/core/ on disk" {
    // Adding a core file without updating the table (or vice versa) must fail.
    // The build injects the absolute path of the package's src/ dir.
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
