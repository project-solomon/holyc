//! The HolyC language server: JSON-RPC 2.0 over LSP base-protocol framing,
//! driven by the hcc front end (without its LLVM backend).
//!
//! The transport is abstract: the server reads frames from any *std.Io.Reader
//! and writes to any *std.Io.Writer, so main.zig binds it to stdin/stdout and
//! tests to in-memory streams. Only protocol frames go to `out`; logs go to
//! stderr.
//!
//! Protocol subset (mirrored in the initialize capabilities):
//!   - textDocumentSync = 1 (full): every didChange replaces the whole text.
//!   - Positions count bytes, not UTF-16 code units (HolyC sources are ASCII;
//!     see position.zig).
//!   - Unknown requests get MethodNotFound; unknown notifications are ignored.

const Server = @This();

const std = @import("std");
const hcc = @import("hcc");
const framing = @import("framing.zig");
const uri_util = @import("uri.zig");
const position = @import("position.zig");
const nav = @import("nav.zig");

gpa: std.mem.Allocator,
io: std.Io,
in: *std.Io.Reader,
out: *std.Io.Writer,
/// Ordered #include <...> search path (HCC_ROOT/pkg, HCC_ROOT/std), so analysis
/// resolves standard-library and package includes like hcc. Set by main after
/// init; empty means std/pkg includes won't resolve.
include_path: []const []const u8 = &.{},
/// uri → open document. Keys and texts are gpa-owned.
docs: std.StringArrayHashMapUnmanaged(Document) = .empty,
/// Directory the embedded core is extracted into (`<HCC_ROOT>/.cache/core`)
/// so go-to-definition can jump into it. gpa-owned; set by main. Null disables
/// go-to-definition into the core.
core_cache_dir: ?[]const u8 = null,
/// Whether the core has been written to core_cache_dir this session.
core_extracted: bool = false,
/// The workspace root path (gpa-owned), or null in single-file mode. When set,
/// the server scans it for HolyC files and maintains ws_defs for cross-file
/// go-to-definition.
root: ?[]u8 = null,
/// uri → that file's top-level definitions and identifier uses, backing
/// cross-file go-to-definition and find-references (for files the user has not
/// opened). Keys are gpa-owned; each value owns an arena holding its names.
ws_defs: std.StringArrayHashMapUnmanaged(FileIndex) = .empty,
shutdown_requested: bool = false,
/// Set by the exit notification; run() returns it.
exit_code: ?u8 = null,

/// JSON-RPC error codes (the subset this server emits).
const ErrorCode = struct {
    const parse_error: i64 = -32700;
    const invalid_request: i64 = -32600;
    const method_not_found: i64 = -32601;
};

/// LSP SymbolKind values used by documentSymbol.
const SymbolKind = struct {
    const class: i64 = 5;
    const field: i64 = 8;
    const function: i64 = 12;
    const variable: i64 = 13;
};

const Document = struct {
    /// The current buffer contents (gpa-owned).
    text: []u8,
    /// The most recent successful front-end run; kept across failed rebuilds
    /// so hover/documentSymbol keep answering (against its own snapshot).
    analysis: ?Analysis = null,
};

/// One front-end run's outputs, owned by one heap-allocated arena (the
/// ArenaAllocator must not live on the stack or in a map slot: moving it by
/// value would dangle its internal state).
const Analysis = struct {
    arena: *std.heap.ArenaAllocator,
    /// The text snapshot the program was built from (arena-owned). AST spans
    /// are byte ranges into this, and identifier slices point into it, so it
    /// must outlive `program`, hence the same arena.
    src: []const u8,
    program: hcc.ast.Program,
    /// The source-file table (indexed by span.file), arena-owned. Maps a
    /// non-zero file id (the core and #includes) to its FileInfo, so
    /// go-to-definition can resolve a declaration back to its origin file.
    files: []const hcc.source.FileInfo,
    /// Every macro and its #define site (arena-owned), so go-to-definition can
    /// jump from a macro use to its definition.
    macros: []const hcc.Preprocessor.MacroDef,

    fn deinit(a: Analysis, gpa: std.mem.Allocator) void {
        a.arena.deinit();
        gpa.destroy(a.arena);
    }
};

/// One file's contribution to the workspace index: its top-level declarations
/// (for cross-file go-to-definition) and its bare-identifier uses (for
/// cross-file find-references). The arena owns the name strings (ranges are
/// plain values), so a file can be re-indexed by swapping the whole struct.
const FileIndex = struct {
    arena: *std.heap.ArenaAllocator,
    defs: []const nav.Def,
    uses: []const nav.Use,

    fn deinit(fi: FileIndex, gpa: std.mem.Allocator) void {
        fi.arena.deinit();
        gpa.destroy(fi.arena);
    }
};

pub const Error = error{ WriteFailed, OutOfMemory };

pub fn init(gpa: std.mem.Allocator, io: std.Io, in: *std.Io.Reader, out: *std.Io.Writer) Server {
    return .{ .gpa = gpa, .io = io, .in = in, .out = out };
}

pub fn deinit(s: *Server) void {
    for (s.docs.keys(), s.docs.values()) |key, doc| {
        s.gpa.free(key);
        s.gpa.free(doc.text);
        if (doc.analysis) |a| a.deinit(s.gpa);
    }
    s.docs.deinit(s.gpa);
    for (s.ws_defs.keys(), s.ws_defs.values()) |key, fi| {
        s.gpa.free(key);
        fi.deinit(s.gpa);
    }
    s.ws_defs.deinit(s.gpa);
    if (s.root) |r| s.gpa.free(r);
    if (s.core_cache_dir) |d| s.gpa.free(d);
}

/// The message loop: runs until the exit notification or end of stream.
/// Returns the process exit code (0 for exit-after-shutdown, 1 otherwise).
pub fn run(s: *Server) Error!u8 {
    while (s.exit_code == null) {
        const body = framing.readFrame(s.in, s.gpa) catch |e| switch (e) {
            // Clean end of session (editor died without `exit`).
            error.EndOfStream => break,
            // A malformed frame must not kill the loop; resync on the next
            // header block.
            error.MissingContentLength => {
                std.debug.print("holyc-lsp: dropping frame without Content-Length\n", .{});
                continue;
            },
            // Transport is unrecoverable.
            error.StreamTooLong, error.ReadFailed => {
                std.debug.print("holyc-lsp: transport failure, exiting\n", .{});
                break;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer s.gpa.free(body);
        try s.handleMessage(body);
    }
    return s.exit_code orelse 1;
}

fn handleMessage(s: *Server, body: []const u8) Error!void {
    var parsed = std.json.parseFromSlice(std.json.Value, s.gpa, body, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return s.sendError(null, ErrorCode.parse_error, "invalid JSON"),
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return s.sendError(null, ErrorCode.invalid_request, "expected a JSON-RPC object");
    const obj = root.object;
    // A message without a method is a response to a server-initiated request;
    // this server never sends any, so drop it.
    const method_val = obj.get("method") orelse return;
    if (method_val != .string) return s.sendError(null, ErrorCode.invalid_request, "method must be a string");
    const method = method_val.string;
    const params: std.json.Value = obj.get("params") orelse .null;
    const id: ?std.json.Value = if (obj.get("id")) |v| (if (v == .null) null else v) else null;

    if (id) |id_val| {
        // Requests: everything else is answered, even when unknown.
        if (std.mem.eql(u8, method, "initialize")) {
            try s.handleInitialize(id_val, params);
        } else if (std.mem.eql(u8, method, "shutdown")) {
            s.shutdown_requested = true;
            try s.replyNull(id_val);
        } else if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
            try s.replyDocumentSymbol(id_val, params);
        } else if (std.mem.eql(u8, method, "textDocument/hover")) {
            try s.replyHover(id_val, params);
        } else if (std.mem.eql(u8, method, "textDocument/definition")) {
            try s.replyDefinition(id_val, params);
        } else if (std.mem.eql(u8, method, "textDocument/references")) {
            try s.replyReferences(id_val, params);
        } else {
            try s.sendError(id_val, ErrorCode.method_not_found, method);
        }
    } else {
        // Notifications: unknown ones are ignored by protocol rule.
        if (std.mem.eql(u8, method, "exit")) {
            s.exit_code = if (s.shutdown_requested) 0 else 1;
        } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            try s.handleDidOpen(params);
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            try s.handleDidChange(params);
        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            try s.handleDidClose(params);
        }
    }
}

// ---- JSON plumbing ----

/// Field lookup on a dynamic JSON value; null unless `v` is an object with
/// that member.
fn get(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn getString(v: std.json.Value, key: []const u8) ?[]const u8 {
    const f = get(v, key) orelse return null;
    return if (f == .string) f.string else null;
}

fn getU32(v: std.json.Value, key: []const u8) ?u32 {
    const f = get(v, key) orelse return null;
    if (f != .integer) return null;
    return std.math.cast(u32, f.integer);
}

/// A message under construction: JSON accumulates in memory, then leaves as
/// one frame. Usage: begin → write via .jw → send.
const Outgoing = struct {
    aw: std.Io.Writer.Allocating,
    jw: std.json.Stringify,

    fn deinit(m: *Outgoing) void {
        m.aw.deinit();
    }

    /// Opens the response envelope through the "result" key; the caller
    /// writes the result value, then calls send().
    fn beginResponse(m: *Outgoing, id: std.json.Value) error{WriteFailed}!void {
        m.jw.writer = &m.aw.writer;
        try m.jw.beginObject();
        try m.jw.objectField("jsonrpc");
        try m.jw.write("2.0");
        try m.jw.objectField("id");
        try m.jw.write(id);
        try m.jw.objectField("result");
    }

    fn beginNotification(m: *Outgoing, method: []const u8) error{WriteFailed}!void {
        m.jw.writer = &m.aw.writer;
        try m.jw.beginObject();
        try m.jw.objectField("jsonrpc");
        try m.jw.write("2.0");
        try m.jw.objectField("method");
        try m.jw.write(method);
        try m.jw.objectField("params");
    }
};

fn beginMessage(s: *Server) Outgoing {
    return .{
        .aw = .init(s.gpa),
        .jw = .{ .writer = undefined, .options = .{} },
    };
}

/// Closes the envelope object and writes the frame.
fn send(s: *Server, m: *Outgoing) error{WriteFailed}!void {
    try m.jw.endObject();
    try framing.writeFrame(s.out, m.aw.written());
}

fn sendError(s: *Server, id: ?std.json.Value, code: i64, message: []const u8) error{WriteFailed}!void {
    var m = s.beginMessage();
    defer m.deinit();
    m.jw.writer = &m.aw.writer;
    try m.jw.beginObject();
    try m.jw.objectField("jsonrpc");
    try m.jw.write("2.0");
    try m.jw.objectField("id");
    try m.jw.write(id orelse .null);
    try m.jw.objectField("error");
    try m.jw.beginObject();
    try m.jw.objectField("code");
    try m.jw.write(code);
    try m.jw.objectField("message");
    try m.jw.write(message);
    try m.jw.endObject();
    try s.send(&m);
}

fn replyNull(s: *Server, id: std.json.Value) error{WriteFailed}!void {
    var m = s.beginMessage();
    defer m.deinit();
    try m.beginResponse(id);
    try m.jw.write(null);
    try s.send(&m);
}

fn writePosition(jw: *std.json.Stringify, p: position.Position) error{WriteFailed}!void {
    try jw.beginObject();
    try jw.objectField("line");
    try jw.write(p.line);
    try jw.objectField("character");
    try jw.write(p.character);
    try jw.endObject();
}

fn writeRange(jw: *std.json.Stringify, start: position.Position, end: position.Position) error{WriteFailed}!void {
    try jw.beginObject();
    try jw.objectField("start");
    try writePosition(jw, start);
    try jw.objectField("end");
    try writePosition(jw, end);
    try jw.endObject();
}

/// A span's byte range rendered against the analysis snapshot.
fn writeSpanRange(jw: *std.json.Stringify, src: []const u8, span: hcc.source.Span) error{WriteFailed}!void {
    try writeRange(
        jw,
        position.offsetToPosition(src, span.start),
        position.offsetToPosition(src, span.end),
    );
}

// ---- lifecycle ----

fn handleInitialize(s: *Server, id: std.json.Value, params: std.json.Value) Error!void {
    var m = s.beginMessage();
    defer m.deinit();
    try m.beginResponse(id);
    try m.jw.beginObject();
    try m.jw.objectField("capabilities");
    try m.jw.beginObject();
    try m.jw.objectField("textDocumentSync");
    try m.jw.write(1); // full sync
    try m.jw.objectField("documentSymbolProvider");
    try m.jw.write(true);
    try m.jw.objectField("hoverProvider");
    try m.jw.write(true);
    try m.jw.objectField("definitionProvider");
    try m.jw.write(true);
    try m.jw.objectField("referencesProvider");
    try m.jw.write(true);
    try m.jw.endObject();
    try m.jw.objectField("serverInfo");
    try m.jw.beginObject();
    try m.jw.objectField("name");
    try m.jw.write("holyc-lsp");
    try m.jw.endObject();
    try m.jw.endObject();
    try s.send(&m);

    // Answer initialize first (so the client sees capabilities promptly), then
    // build the cross-file definition index. Best-effort: absent/odd params or
    // an unreadable tree leave the workspace index empty.
    try s.setupWorkspace(params);
}

/// Records the workspace root from the initialize params (rootUri preferred over
/// the deprecated rootPath) and scans it for the cross-file definition index.
fn setupWorkspace(s: *Server, params: std.json.Value) Error!void {
    if (getString(params, "rootUri")) |root_uri| {
        s.root = (uri_util.filePath(s.gpa, root_uri) catch return) orelse null;
    } else if (getString(params, "rootPath")) |root_path| {
        s.root = try s.gpa.dupe(u8, root_path);
    }
    if (s.root) |root| try s.indexWorkspace(root);
}

// ---- document synchronization ----

fn handleDidOpen(s: *Server, params: std.json.Value) Error!void {
    const td = get(params, "textDocument") orelse return;
    const uri = getString(td, "uri") orelse return;
    const text = getString(td, "text") orelse return;
    const doc = try s.upsertText(uri, text);
    try s.analyzeAndPublish(uri, doc);
}

fn handleDidChange(s: *Server, params: std.json.Value) Error!void {
    const td = get(params, "textDocument") orelse return;
    const uri = getString(td, "uri") orelse return;
    const changes = get(params, "contentChanges") orelse return;
    if (changes != .array or changes.array.items.len == 0) return;
    // Full sync: each change carries the entire new text; the last one wins.
    const last = changes.array.items[changes.array.items.len - 1];
    const text = getString(last, "text") orelse return;
    const doc = try s.upsertText(uri, text);
    try s.analyzeAndPublish(uri, doc);
}

fn handleDidClose(s: *Server, params: std.json.Value) Error!void {
    const td = get(params, "textDocument") orelse return;
    const uri = getString(td, "uri") orelse return;
    if (s.docs.fetchSwapRemove(uri)) |kv| {
        s.gpa.free(kv.key);
        s.gpa.free(kv.value.text);
        if (kv.value.analysis) |a| a.deinit(s.gpa);
    }
    // The buffer's live definitions are gone; fall back to the saved file on
    // disk so cross-file navigation keeps working (and drops unsaved edits).
    if (s.root != null) {
        s.wsRemove(uri);
        if (uri_util.filePath(s.gpa, uri) catch null) |path| {
            defer s.gpa.free(path);
            s.wsIndexPath(path) catch {};
        }
    }
    // Clear the document's diagnostics in the editor.
    var m = s.beginMessage();
    defer m.deinit();
    try m.beginNotification("textDocument/publishDiagnostics");
    try m.jw.beginObject();
    try m.jw.objectField("uri");
    try m.jw.write(uri);
    try m.jw.objectField("diagnostics");
    try m.jw.beginArray();
    try m.jw.endArray();
    try m.jw.endObject();
    try s.send(&m);
}

/// Stores `text` as the document's current buffer, creating the entry on
/// first open.
fn upsertText(s: *Server, uri: []const u8, text: []const u8) error{OutOfMemory}!*Document {
    const text_copy = try s.gpa.dupe(u8, text);
    errdefer s.gpa.free(text_copy);
    if (s.docs.getPtr(uri)) |doc| {
        s.gpa.free(doc.text);
        doc.text = text_copy;
        return doc;
    }
    const uri_copy = try s.gpa.dupe(u8, uri);
    errdefer s.gpa.free(uri_copy);
    try s.docs.put(s.gpa, uri_copy, .{ .text = text_copy });
    return s.docs.getPtr(uri_copy).?;
}

/// Builds the #include <...> search path: $HCC_ROOT/pkg (third-party packages)
/// then $HCC_ROOT/std (standard library), the same resolution hcc uses minus
/// the -I dirs. HCC_ROOT defaults to the parent of the running binary's dir
/// (bin/holyc-lsp yields the root beside bin/std); an unresolvable root is
/// skipped. `env` is anything with `get(key) ?[]const u8` (the environment map).
pub fn computeIncludePath(arena: std.mem.Allocator, io: std.Io, env: anytype) error{OutOfMemory}![]const []const u8 {
    var path: std.ArrayList([]const u8) = .empty;
    if (resolveRoot(arena, io, env)) |root| {
        try path.append(arena, try std.fs.path.join(arena, &.{ root, "pkg" }));
        try path.append(arena, try std.fs.path.join(arena, &.{ root, "std" }));
    }
    return path.items;
}

/// The toolchain root: $HCC_ROOT, else the parent of the running binary's
/// directory (bin/holyc-lsp yields the tree beside bin/), else null.
fn resolveRoot(arena: std.mem.Allocator, io: std.Io, env: anytype) ?[]const u8 {
    return env.get("HCC_ROOT") orelse blk: {
        const bindir = std.process.executableDirPathAlloc(io, arena) catch break :blk null;
        break :blk std.fs.path.dirname(bindir);
    };
}

/// Where to extract the embedded core for go-to-definition into it:
/// `<HCC_ROOT>/.cache/core`. Returned gpa-owned (lives for the server), or null
/// when the root cannot be resolved. Set onto `core_cache_dir` by main.
pub fn coreCacheDir(gpa: std.mem.Allocator, io: std.Io, env: anytype) ?[]u8 {
    var tmp = std.heap.ArenaAllocator.init(gpa);
    defer tmp.deinit();
    const a = tmp.allocator();
    const root = resolveRoot(a, io, env) orelse return null;
    const dir = std.fs.path.join(a, &.{ root, ".cache", "core" }) catch return null;
    return gpa.dupe(u8, dir) catch null;
}

// ---- analysis and diagnostics ----

/// Runs the front end over the document and publishes diagnostics. On
/// success the analysis (arena + program + text snapshot) replaces the
/// cached one; on failure the previous successful analysis is kept and the
/// new arena is torn down after publishing.
fn analyzeAndPublish(s: *Server, uri: []const u8, doc: *Document) Error!void {
    const arena_ptr = try s.gpa.create(std.heap.ArenaAllocator);
    arena_ptr.* = std.heap.ArenaAllocator.init(s.gpa);
    var keep = false;
    defer if (!keep) {
        arena_ptr.deinit();
        s.gpa.destroy(arena_ptr);
    };
    const arena = arena_ptr.allocator();

    // Analyze an arena-owned snapshot: the AST slices into its source text,
    // and doc.text is freed on the next edit.
    const src = try arena.dupe(u8, doc.text);

    // Relative #include paths resolve against the document's directory.
    const base_dir = blk: {
        const path = try uri_util.filePath(arena, uri) orelse break :blk ".";
        break :blk std.fs.path.dirname(path) orelse ".";
    };

    var diags = hcc.diag.Diagnostics.init(arena);
    var files: []const hcc.source.FileInfo = &.{};
    // No exe_runner: running an #exe block needs the LLVM backend, which the
    // server never links. The frontend skips #exe blocks without an executor,
    // so a file using #exe still analyzes (its generated code is not visible to
    // the editor).
    const result: ?hcc.frontend.Result = hcc.frontend.run(arena, &diags, s.io, src, .{
        .base_dir = base_dir,
        .target = hcc.target.Target.host(),
        .inject_core = true,
        .include_path = s.include_path,
        .files_out = &files,
    }) catch |e| switch (e) {
        error.CompileFailed => null,
        error.OutOfMemory => return error.OutOfMemory,
    };

    try s.publishDiagnostics(uri, diags.list.items, files);

    if (result) |res| {
        if (doc.analysis) |old| old.deinit(s.gpa);
        doc.analysis = .{ .arena = arena_ptr, .src = src, .program = res.program, .files = files, .macros = res.macros };
        keep = true;
        // Keep the cross-file index in step with the live buffer (best-effort:
        // an index-update OOM must not fail the diagnostics publish).
        if (s.root != null) s.wsUpdateDoc(uri, doc.analysis.?) catch {};
    }
}

fn publishDiagnostics(
    s: *Server,
    uri: []const u8,
    diagnostics: []const hcc.diag.Diagnostic,
    files: []const hcc.source.FileInfo,
) Error!void {
    var scratch_state = std.heap.ArenaAllocator.init(s.gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    var m = s.beginMessage();
    defer m.deinit();
    try m.beginNotification("textDocument/publishDiagnostics");
    try m.jw.beginObject();
    try m.jw.objectField("uri");
    try m.jw.write(uri);
    try m.jw.objectField("diagnostics");
    try m.jw.beginArray();
    for (diagnostics) |d| {
        // Diagnostics from the open buffer (file 0) map to their position;
        // ones from includes or the core land at 0:0 with the origin file
        // named in the message.
        var pos: position.Position = .{ .line = 0, .character = 0 };
        var message = d.message;
        if (d.file == 0) {
            pos = .{
                .line = if (d.pos.line > 0) d.pos.line - 1 else 0,
                .character = if (d.pos.col > 0) d.pos.col - 1 else 0,
            };
        } else {
            const name = if (d.file < files.len)
                try std.fmt.allocPrint(scratch, "{f}", .{files[d.file]})
            else
                "<unknown>";
            message = try std.fmt.allocPrint(scratch, "in {s}: {s}", .{ name, d.message });
        }
        try m.jw.beginObject();
        try m.jw.objectField("range");
        try writeRange(&m.jw, pos, pos);
        try m.jw.objectField("severity");
        try m.jw.write(@as(i64, if (d.severity == .@"error") 1 else 2));
        try m.jw.objectField("source");
        try m.jw.write("hcc");
        try m.jw.objectField("message");
        try m.jw.write(message);
        try m.jw.endObject();
    }
    try m.jw.endArray();
    try m.jw.endObject();
    try s.send(&m);
}

// ---- workspace definition index ----

/// Whether name ends in a HolyC extension (.HC or .hc).
fn isHolyCFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".HC") or std.mem.endsWith(u8, name, ".hc");
}

/// Whether a workspace-relative path passes through a directory the scan skips:
/// hidden directories (.git and friends) and common dependency/build output.
fn pathHasSkippedDir(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, std.fs.path.sep);
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (seg[0] == '.') return true;
        if (std.mem.eql(u8, seg, "node_modules") or std.mem.eql(u8, seg, "zig-out") or
            std.mem.eql(u8, seg, "target") or std.mem.eql(u8, seg, "build")) return true;
    }
    return false;
}

/// Walks the workspace root and indexes every HolyC file's top-level
/// definitions. Unreadable entries and files that do not parse standalone are
/// skipped; a file cap bounds pathological trees.
fn indexWorkspace(s: *Server, root: []const u8) Error!void {
    var dir = std.Io.Dir.openDirAbsolute(s.io, root, .{ .iterate = true }) catch return;
    defer dir.close(s.io);
    var walker = dir.walk(s.gpa) catch return;
    defer walker.deinit();

    const max_files = 5000;
    var indexed: usize = 0;
    while (walker.next(s.io) catch null) |entry| {
        if (entry.kind != .file or !isHolyCFile(entry.basename)) continue;
        if (pathHasSkippedDir(entry.path)) continue;
        if (indexed >= max_files) break;
        const abs = std.fs.path.join(s.gpa, &.{ root, entry.path }) catch continue;
        defer s.gpa.free(abs);
        s.wsIndexPath(abs) catch {};
        indexed += 1;
    }
}

/// Reads one file from disk, analyses it standalone, and records its top-level
/// definitions under its file:// URI. Any read/parse failure leaves the index
/// unchanged for that file.
fn wsIndexPath(s: *Server, abs_path: []const u8) Error!void {
    var tmp_state = std.heap.ArenaAllocator.init(s.gpa);
    defer tmp_state.deinit();
    const tmp = tmp_state.allocator();

    const src = std.Io.Dir.cwd().readFileAlloc(s.io, abs_path, tmp, .limited(16 << 20)) catch return;
    var diags = hcc.diag.Diagnostics.init(tmp);
    const base_dir = std.fs.path.dirname(abs_path) orelse ".";
    const res = hcc.frontend.run(tmp, &diags, s.io, src, .{
        .base_dir = base_dir,
        .target = hcc.target.Target.host(),
        .inject_core = true,
        .include_path = s.include_path,
    }) catch return;

    const uri = try nav.pathToUri(s.gpa, abs_path);
    try s.wsUpsert(uri, src, res.program.items);
}

/// Updates the open document's entry in the index from its live analysis, so
/// other files' go-to-definition reflects unsaved edits here.
fn wsUpdateDoc(s: *Server, uri: []const u8, analysis: Analysis) Error!void {
    const uri_copy = try s.gpa.dupe(u8, uri);
    try s.wsUpsert(uri_copy, analysis.src, analysis.program.items);
}

/// Stores uri_owned's definitions, replacing any prior entry. Takes ownership of
/// uri_owned: it is stored as the map key, or freed when the key already exists
/// or the update is dropped. Best-effort: an allocation failure while building
/// the entry drops it rather than propagating.
fn wsUpsert(s: *Server, uri_owned: []u8, src: []const u8, items: []const *hcc.ast.Stmt) error{OutOfMemory}!void {
    errdefer s.gpa.free(uri_owned); // only on the create-failure path below
    const arena_ptr = try s.gpa.create(std.heap.ArenaAllocator);
    arena_ptr.* = std.heap.ArenaAllocator.init(s.gpa);

    const arena = arena_ptr.allocator();
    var fi = FileIndex{ .arena = arena_ptr, .defs = &.{}, .uses = &.{} };
    fi.defs = nav.collectDefs(arena, src, items) catch return s.wsDrop(fi, uri_owned);
    fi.uses = nav.collectUses(arena, src, items) catch return s.wsDrop(fi, uri_owned);

    if (s.ws_defs.getPtr(uri_owned)) |old| {
        old.deinit(s.gpa);
        old.* = fi;
        s.gpa.free(uri_owned); // key already stored; drop the duplicate
    } else {
        s.ws_defs.put(s.gpa, uri_owned, fi) catch return s.wsDrop(fi, uri_owned);
    }
}

/// Discards a half-built index entry and its key (used when indexing a file
/// runs out of memory; the file is left unindexed).
fn wsDrop(s: *Server, fi: FileIndex, uri_owned: []u8) void {
    fi.deinit(s.gpa);
    s.gpa.free(uri_owned);
}

/// Forgets uri's definitions.
fn wsRemove(s: *Server, uri: []const u8) void {
    if (s.ws_defs.fetchSwapRemove(uri)) |kv| {
        s.gpa.free(kv.key);
        kv.value.deinit(s.gpa);
    }
}

// ---- textDocument/definition & textDocument/references ----

/// A cross-file definition candidate: the URI of the declaring file (borrowed
/// from the index key) and the name's range within it.
const WsMatch = struct { uri: []const u8, range: nav.Range };

fn lessByUri(_: void, a: WsMatch, b: WsMatch) bool {
    return std.mem.lessThan(u8, a.uri, b.uri);
}

/// Writes a Location object {uri, range}.
fn writeLoc(jw: *std.json.Stringify, uri: []const u8, range: nav.Range) error{WriteFailed}!void {
    try jw.beginObject();
    try jw.objectField("uri");
    try jw.write(uri);
    try jw.objectField("range");
    try writeRange(jw, range.start, range.end);
    try jw.endObject();
}

/// Extracts the embedded core to core_cache_dir once per session, so a
/// go-to-definition into the core has a real file to point at. Returns the
/// directory on success, or null when disabled (no cache dir) or the write
/// fails, in which case core navigation is skipped. Overwrites each session
/// so the cache always matches this binary's embedded core.
fn ensureCoreExtracted(s: *Server) ?[]const u8 {
    const dir = s.core_cache_dir orelse return null;
    if (s.core_extracted) return dir;
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(s.io, dir) catch return null;
    for (hcc.core.files) |f| {
        const full = std.fs.path.join(s.gpa, &.{ dir, f.path }) catch return null;
        defer s.gpa.free(full);
        if (std.fs.path.dirname(full)) |parent| cwd.createDirPath(s.io, parent) catch {};
        cwd.writeFile(s.io, .{ .sub_path = full, .data = f.contents }) catch return null;
    }
    s.core_extracted = true;
    return dir;
}

/// Answers go-to-definition. A declaration in the same file wins (precise, and
/// reflecting unsaved edits); then the embedded core (jumping into an
/// extracted copy of its source); otherwise the workspace index is consulted so
/// the jump can cross files. Replies null when the cursor is already on the
/// declaration (so the editor falls back to find-all-references) or when there
/// is nothing to jump to.
fn replyDefinition(s: *Server, id: std.json.Value, params: std.json.Value) Error!void {
    const uri = getString(get(params, "textDocument") orelse .null, "uri") orelse return s.replyNull(id);
    const doc = s.docs.getPtr(uri) orelse return s.replyNull(id);
    const pos_val = get(params, "position") orelse return s.replyNull(id);
    const pos: position.Position = .{
        .line = getU32(pos_val, "line") orelse return s.replyNull(id),
        .character = getU32(pos_val, "character") orelse return s.replyNull(id),
    };

    // The cursor word comes from the live buffer, so navigation still works when
    // the current text does not parse (e.g. an include-fragment opened alone):
    // the same-file lookup below is skipped, but cross-file still resolves.
    const text = doc.text;
    const offset = position.positionToOffset(text, pos);
    const word = nav.wordAt(text, offset);
    if (word.len == 0) return s.replyNull(id);

    // Same-file declaration wins, when the buffer has a good parse to search.
    if (doc.analysis) |analysis| {
        if (nav.findDef(analysis.src, analysis.program.items, word)) |off| {
            // Already on the declaration: yield null so the editor falls back to
            // find-all-references.
            if (off.start <= offset and offset <= off.end) return s.replyNull(id);
            var m = s.beginMessage();
            defer m.deinit();
            try m.beginResponse(id);
            try writeLoc(&m.jw, uri, nav.rangeFromOffsets(analysis.src, off));
            return s.send(&m);
        }
        // Then the embedded core: jump into an extracted copy of its source.
        if (nav.findCoreDef(analysis.program.items, analysis.files, word)) |pd| {
            if (s.ensureCoreExtracted()) |dir| {
                var sa = std.heap.ArenaAllocator.init(s.gpa);
                defer sa.deinit();
                const a = sa.allocator();
                const path = try std.fs.path.join(a, &.{ dir, pd.core_name });
                const loc_uri = try nav.pathToUri(a, path);
                var m = s.beginMessage();
                defer m.deinit();
                try m.beginResponse(id);
                try writeLoc(&m.jw, loc_uri, pd.range);
                return s.send(&m);
            }
        }
        // Then a macro (#define): jump from a use to its definition site. The
        // def span is the macro name itself; resolve its file the same way as a
        // core declaration (the user's own file, or the extracted core).
        for (analysis.macros) |md| {
            if (!std.mem.eql(u8, md.name, word))
                continue;
            const off = nav.Offsets{ .start = md.def.start, .end = md.def.end };
            if (md.def.file == 0) {
                var m = s.beginMessage();
                defer m.deinit();
                try m.beginResponse(id);
                try writeLoc(&m.jw, uri, nav.rangeFromOffsets(analysis.src, off));
                return s.send(&m);
            }
            if (md.def.file < analysis.files.len) {
                const core_name = analysis.files[md.def.file].name;
                if (hcc.core.get(core_name)) |ctext| {
                    if (s.ensureCoreExtracted()) |dir| {
                        var sa = std.heap.ArenaAllocator.init(s.gpa);
                        defer sa.deinit();
                        const a = sa.allocator();
                        const path = try std.fs.path.join(a, &.{ dir, core_name });
                        const loc_uri = try nav.pathToUri(a, path);
                        var m = s.beginMessage();
                        defer m.deinit();
                        try m.beginResponse(id);
                        try writeLoc(&m.jw, loc_uri, nav.rangeFromOffsets(ctext, off));
                        return s.send(&m);
                    }
                }
            }
            break; // matched the macro name but its location is unresolvable
        }
    }

    // Otherwise, a definition in another workspace file.
    var scratch_state = std.heap.ArenaAllocator.init(s.gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    var matches: std.ArrayList(WsMatch) = .empty;
    for (s.ws_defs.keys(), s.ws_defs.values()) |key, fd| {
        if (std.mem.eql(u8, key, uri)) continue;
        for (fd.defs) |d| {
            if (std.mem.eql(u8, d.name, word)) try matches.append(scratch, .{ .uri = key, .range = d.range });
        }
    }
    if (matches.items.len == 0) return s.replyNull(id);
    std.mem.sort(WsMatch, matches.items, {}, lessByUri);

    var m = s.beginMessage();
    defer m.deinit();
    try m.beginResponse(id);
    if (matches.items.len == 1) {
        try writeLoc(&m.jw, matches.items[0].uri, matches.items[0].range);
    } else {
        try m.jw.beginArray();
        for (matches.items) |match| try writeLoc(&m.jw, match.uri, match.range);
        try m.jw.endArray();
    }
    return s.send(&m);
}

/// Answers find-all-references: every bare-identifier use of the word under the
/// cursor across the workspace, plus the declaration when the client asks for
/// it. The current file's uses come from its live parse; other files' from the
/// workspace index. Always a list (empty, never null).
fn replyReferences(s: *Server, id: std.json.Value, params: std.json.Value) Error!void {
    const uri = getString(get(params, "textDocument") orelse .null, "uri") orelse return s.replyEmptyArray(id);
    const doc = s.docs.getPtr(uri) orelse return s.replyEmptyArray(id);
    const pos_val = get(params, "position") orelse return s.replyEmptyArray(id);
    const pos: position.Position = .{
        .line = getU32(pos_val, "line") orelse return s.replyEmptyArray(id),
        .character = getU32(pos_val, "character") orelse return s.replyEmptyArray(id),
    };
    const include_decl = blk: {
        const ctx = get(params, "context") orelse break :blk false;
        const inc = get(ctx, "includeDeclaration") orelse break :blk false;
        break :blk inc == .bool and inc.bool;
    };

    // The cursor word comes from the live buffer, so a just-typed use resolves.
    const word = nav.wordAt(doc.text, position.positionToOffset(doc.text, pos));

    var scratch_state = std.heap.ArenaAllocator.init(s.gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    var m = s.beginMessage();
    defer m.deinit();
    try m.beginResponse(id);
    try m.jw.beginArray();
    if (word.len > 0) {
        // Current file: read from the live parse (fresh, and works without a
        // workspace root).
        if (doc.analysis) |analysis| {
            if (include_decl) {
                if (nav.findDef(analysis.src, analysis.program.items, word)) |off| {
                    try writeLoc(&m.jw, uri, nav.rangeFromOffsets(analysis.src, off));
                }
            }
            const refs = nav.collectRefs(scratch, analysis.src, analysis.program.items, word) catch &.{};
            for (refs) |r| try writeLoc(&m.jw, uri, r);
        }
        // Every other workspace file: from the index.
        for (s.ws_defs.keys(), s.ws_defs.values()) |key, fi| {
            if (std.mem.eql(u8, key, uri)) continue;
            if (include_decl) {
                for (fi.defs) |d| {
                    if (std.mem.eql(u8, d.name, word)) try writeLoc(&m.jw, key, d.range);
                }
            }
            for (fi.uses) |u| {
                if (std.mem.eql(u8, u.name, word)) try writeLoc(&m.jw, key, u.range);
            }
        }
    }
    try m.jw.endArray();
    return s.send(&m);
}

/// Replies with an empty JSON array.
fn replyEmptyArray(s: *Server, id: std.json.Value) error{WriteFailed}!void {
    var m = s.beginMessage();
    defer m.deinit();
    try m.beginResponse(id);
    try m.jw.beginArray();
    try m.jw.endArray();
    try s.send(&m);
}

// ---- textDocument/documentSymbol ----

fn replyDocumentSymbol(s: *Server, id: std.json.Value, params: std.json.Value) Error!void {
    const uri = getString(get(params, "textDocument") orelse .null, "uri") orelse
        return s.replyNull(id);
    const doc = s.docs.getPtr(uri) orelse return s.replyNull(id);
    const analysis = doc.analysis orelse return s.replyNull(id);

    var scratch_state = std.heap.ArenaAllocator.init(s.gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    var m = s.beginMessage();
    defer m.deinit();
    try m.beginResponse(id);
    try m.jw.beginArray();
    for (analysis.program.items) |item| {
        // The buffer's own items only: the core and includes are file != 0.
        if (item.span.file != 0) continue;
        switch (item.kind) {
            .func_def => |f| {
                const detail = renderSignature(f, scratch) catch return error.OutOfMemory;
                try writeSymbol(&m.jw, analysis.src, f.name, SymbolKind.function, detail, item.span);
                try m.jw.endObject();
            },
            .class_def => |c| {
                try writeSymbol(&m.jw, analysis.src, c.name, SymbolKind.class, null, item.span);
                try m.jw.objectField("children");
                try m.jw.beginArray();
                for (c.fields) |field| {
                    if (hcc.ast.isAnonField(field.name)) continue;
                    const detail = try hcc.ast.Type.string(field.ty, scratch);
                    try writeSymbol(&m.jw, analysis.src, field.name, SymbolKind.field, detail, field.span);
                    try m.jw.endObject();
                }
                try m.jw.endArray();
                try m.jw.endObject();
            },
            .var_decl => |decls| {
                for (decls) |decl| {
                    const detail = try hcc.ast.Type.string(decl.ty, scratch);
                    try writeSymbol(&m.jw, analysis.src, decl.name, SymbolKind.variable, detail, decl.span);
                    try m.jw.endObject();
                }
            },
            else => {},
        }
    }
    try m.jw.endArray();
    try s.send(&m);
}

/// Writes a DocumentSymbol object up to (not including) its closing brace, so
/// the caller can append "children" before ending it.
fn writeSymbol(
    jw: *std.json.Stringify,
    src: []const u8,
    name: []const u8,
    kind: i64,
    detail: ?[]const u8,
    span: hcc.source.Span,
) error{WriteFailed}!void {
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(name);
    try jw.objectField("kind");
    try jw.write(kind);
    if (detail) |d| {
        try jw.objectField("detail");
        try jw.write(d);
    }
    try jw.objectField("range");
    try writeSpanRange(jw, src, span);
    // No separate name span in the AST; the node span doubles as the
    // selection range (LSP only requires containment).
    try jw.objectField("selectionRange");
    try writeSpanRange(jw, src, span);
}

/// Renders a function signature like "I64 (I64 n, U8 *s)" for symbol details.
fn renderSignature(f: *const hcc.ast.FuncDef, arena: std.mem.Allocator) error{ OutOfMemory, WriteFailed }![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try hcc.ast.Type.render(f.ret, w);
    try w.writeAll(" (");
    for (f.params, 0..) |p, i| {
        if (i > 0) try w.writeAll(", ");
        try hcc.ast.Type.render(p.ty, w);
        if (p.name.len > 0) try w.print(" {s}", .{p.name});
    }
    if (f.varargs) {
        if (f.params.len > 0) try w.writeAll(", ");
        try w.writeAll("...");
    }
    try w.writeAll(")");
    return aw.written();
}

// ---- textDocument/hover ----

fn replyHover(s: *Server, id: std.json.Value, params: std.json.Value) Error!void {
    const uri = getString(get(params, "textDocument") orelse .null, "uri") orelse
        return s.replyNull(id);
    const doc = s.docs.getPtr(uri) orelse return s.replyNull(id);
    const analysis = doc.analysis orelse return s.replyNull(id);
    const pos_val = get(params, "position") orelse return s.replyNull(id);
    const pos: position.Position = .{
        .line = getU32(pos_val, "line") orelse return s.replyNull(id),
        .character = getU32(pos_val, "character") orelse return s.replyNull(id),
    };

    const offset = position.positionToOffset(analysis.src, pos);
    var finder: ExprFinder = .{ .offset = offset };
    finder.visitStmts(analysis.program.items);
    const expr = finder.best orelse return s.replyNull(id);

    var scratch_state = std.heap.ArenaAllocator.init(s.gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    const ty_str = try hcc.ast.Type.string(expr.ty, scratch);
    const text = switch (expr.kind) {
        .ident => |name| try std.fmt.allocPrint(scratch, "{s}: {s}", .{ name, ty_str }),
        else => ty_str,
    };
    // Annotate when the symbol under the cursor is declared in the implicit core.
    var origin: []const u8 = "";
    if (expr.kind == .ident) {
        if (nav.findCoreDef(analysis.program.items, analysis.files, expr.kind.ident)) |pd|
            origin = try std.fmt.allocPrint(scratch, "\n\n*from `{s}` (core)*", .{pd.core_name});
    }
    const value = try std.fmt.allocPrint(scratch, "```holyc\n{s}\n```{s}", .{ text, origin });

    var m = s.beginMessage();
    defer m.deinit();
    try m.beginResponse(id);
    try m.jw.beginObject();
    try m.jw.objectField("contents");
    try m.jw.beginObject();
    try m.jw.objectField("kind");
    try m.jw.write("markdown");
    try m.jw.objectField("value");
    try m.jw.write(value);
    try m.jw.endObject();
    try m.jw.objectField("range");
    try writeSpanRange(&m.jw, analysis.src, expr.span);
    try m.jw.endObject();
    try s.send(&m);
}

/// Finds the innermost (shortest-span) expression of the open buffer whose
/// byte span contains the offset.
const ExprFinder = struct {
    offset: usize,
    best: ?*const hcc.ast.Expr = null,

    fn visitStmts(f: *ExprFinder, stmts: []const *hcc.ast.Stmt) void {
        for (stmts) |stmt| f.visitStmt(stmt);
    }

    fn visitStmt(f: *ExprFinder, stmt: *const hcc.ast.Stmt) void {
        switch (stmt.kind) {
            .expr => |e| f.visitExpr(e),
            .block, .lock => |stmts| f.visitStmts(stmts),
            .var_decl => |decls| for (decls) |d| f.visitOpt(d.init),
            .if_stmt => |k| {
                f.visitExpr(k.cond);
                f.visitStmt(k.then);
                if (k.els) |els| f.visitStmt(els);
            },
            .while_stmt => |k| {
                f.visitExpr(k.cond);
                f.visitStmt(k.body);
            },
            .do_while => |k| {
                f.visitStmt(k.body);
                f.visitExpr(k.cond);
            },
            .for_stmt => |k| {
                if (k.init) |i| f.visitStmt(i);
                f.visitOpt(k.cond);
                f.visitOpt(k.step);
                f.visitStmt(k.body);
            },
            .switch_stmt => |k| {
                f.visitExpr(k.cond);
                f.visitStmt(k.body);
            },
            .case => |k| {
                f.visitOpt(k.lo);
                f.visitOpt(k.hi);
            },
            .return_stmt => |v| f.visitOpt(v),
            .throw => |v| f.visitOpt(v),
            .try_stmt => |k| {
                f.visitStmts(k.body);
                f.visitStmts(k.handler);
            },
            .func_def => |fd| {
                for (fd.params) |p| f.visitOpt(p.default_value);
                f.visitStmts(fd.body orelse &.{});
            },
            .class_def => |c| for (c.fields) |field| f.visitOpt(field.init),
            .empty, .no_warn, .default, .switch_start, .switch_end, .break_stmt, .goto_stmt, .label, .asm_stmt => {},
        }
    }

    fn visitOpt(f: *ExprFinder, expr: ?*const hcc.ast.Expr) void {
        if (expr) |e| f.visitExpr(e);
    }

    fn visitExpr(f: *ExprFinder, e: *const hcc.ast.Expr) void {
        const sp = e.span;
        if (sp.file == 0 and sp.start <= f.offset and f.offset < sp.end) {
            // `<=` so an equally-sized child (visited later) wins over its
            // parent.
            if (f.best == null or sp.end - sp.start <= spanLen(f.best.?)) f.best = e;
        }
        switch (e.kind) {
            .unary => |k| f.visitExpr(k.expr),
            .postfix => |k| f.visitExpr(k.expr),
            .binary => |k| {
                f.visitExpr(k.lhs);
                f.visitExpr(k.rhs);
            },
            .assign => |k| {
                f.visitExpr(k.target);
                f.visitExpr(k.value);
            },
            .call => |k| {
                f.visitExpr(k.callee);
                for (k.args) |arg| f.visitOpt(arg);
            },
            .index => |k| {
                f.visitExpr(k.base);
                f.visitExpr(k.index);
            },
            .member => |k| f.visitExpr(k.base),
            .cast => |k| f.visitExpr(k.expr),
            .sizeof => |k| f.visitOpt(k.expr),
            .init_list, .comma => |items| for (items) |item| f.visitExpr(item),
            .designated_init => |fields| for (fields) |field| f.visitExpr(field.value),
            .int_lit, .float_lit, .str_lit, .char_lit, .ident, .offset, .lastclass => {},
        }
    }

    fn spanLen(e: *const hcc.ast.Expr) usize {
        return e.span.end - e.span.start;
    }
};
