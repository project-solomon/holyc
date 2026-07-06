//! The HolyC language server: JSON-RPC 2.0 over LSP base-protocol framing,
//! driven by the hcc compiler front end (without its LLVM backend).
//!
//! The transport is abstract — the server reads frames from any
//! *std.Io.Reader and writes to any *std.Io.Writer — so main.zig binds it to
//! stdin/stdout and tests bind it to in-memory streams. Nothing but protocol
//! frames is ever written to `out`; incidental logging goes to stderr.
//!
//! Protocol subset (deliberate simplifications, mirrored in the initialize
//! capabilities):
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

gpa: std.mem.Allocator,
io: std.Io,
in: *std.Io.Reader,
out: *std.Io.Writer,
/// uri → open document. Keys and texts are gpa-owned.
docs: std.StringArrayHashMapUnmanaged(Document) = .empty,
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
    /// must outlive `program` — hence it lives in the same arena.
    src: []const u8,
    program: hcc.ast.Program,

    fn deinit(a: Analysis, gpa: std.mem.Allocator) void {
        a.arena.deinit();
        gpa.destroy(a.arena);
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
            try s.replyInitialize(id_val);
        } else if (std.mem.eql(u8, method, "shutdown")) {
            s.shutdown_requested = true;
            try s.replyNull(id_val);
        } else if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
            try s.replyDocumentSymbol(id_val, params);
        } else if (std.mem.eql(u8, method, "textDocument/hover")) {
            try s.replyHover(id_val, params);
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

fn replyInitialize(s: *Server, id: std.json.Value) error{WriteFailed}!void {
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
    try m.jw.endObject();
    try m.jw.objectField("serverInfo");
    try m.jw.beginObject();
    try m.jw.objectField("name");
    try m.jw.write("holyc-lsp");
    try m.jw.endObject();
    try m.jw.endObject();
    try s.send(&m);
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
    const result: ?hcc.frontend.Result = hcc.frontend.run(arena, &diags, s.io, src, .{
        .base_dir = base_dir,
        .target = hcc.target.Target.host(),
        .inject_prelude = true,
        .files_out = &files,
    }) catch |e| switch (e) {
        error.CompileFailed => null,
        error.OutOfMemory => return error.OutOfMemory,
    };

    try s.publishDiagnostics(uri, diags.list.items, files);

    if (result) |res| {
        if (doc.analysis) |old| old.deinit(s.gpa);
        doc.analysis = .{ .arena = arena_ptr, .src = src, .program = res.program };
        keep = true;
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
        // ones from includes or the prelude land at 0:0 with the origin file
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
        // The buffer's own items only: the prelude and includes are file != 0.
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
    const value = try std.fmt.allocPrint(scratch, "```holyc\n{s}\n```", .{text});

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
