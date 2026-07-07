//! End-to-end protocol tests: a scripted client session over in-memory
//! streams, asserting on the server's framed JSON replies.

const std = @import("std");
const Server = @import("Server.zig");
const framing = @import("framing.zig");

// ---- dynamic-value helpers ----

fn get(v: std.json.Value, key: []const u8) std.json.Value {
    if (v != .object) return .null;
    return v.object.get(key) orelse .null;
}

fn getStr(v: std.json.Value, key: []const u8) []const u8 {
    const f = get(v, key);
    return if (f == .string) f.string else "";
}

fn getInt(v: std.json.Value, key: []const u8) i64 {
    const f = get(v, key);
    return if (f == .integer) f.integer else -1;
}

fn items(v: std.json.Value) []std.json.Value {
    return if (v == .array) v.array.items else &.{};
}

/// Runs a scripted session: frames every body into the server's stdin,
/// runs the loop to completion, and returns the parsed replies (arena-owned)
/// plus the exit code.
fn runSession(
    arena: std.mem.Allocator,
    bodies: []const []const u8,
) !struct { msgs: []std.json.Value, code: u8 } {
    const gpa = std.testing.allocator;

    var input: std.Io.Writer.Allocating = .init(gpa);
    defer input.deinit();
    for (bodies) |b| try framing.writeFrame(&input.writer, b);

    var in_r = std.Io.Reader.fixed(input.written());
    var out_w: std.Io.Writer.Allocating = .init(gpa);
    defer out_w.deinit();

    var server = Server.init(gpa, std.testing.io, &in_r, &out_w.writer);
    defer server.deinit();
    const code = try server.run();

    var msgs: std.ArrayList(std.json.Value) = .empty;
    var out_r = std.Io.Reader.fixed(out_w.written());
    while (true) {
        const body = framing.readFrame(&out_r, arena) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        try msgs.append(arena, try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}));
    }
    return .{ .msgs = msgs.items, .code = code };
}

test "end-to-end session: lifecycle, diagnostics, symbols, hover" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The URI's percent-encoded space exercises base_dir decoding. The dirty
    // text has an undeclared `x` (error at 0:24) and an unused `y` (warning
    // at 0:14); the didChange text is clean.
    const session = try runSession(arena, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tmp/lsp%20e2e/test.HC","languageId":"holyc","version":1,"text":"I64 F() { I64 y; return x; }"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///tmp/lsp%20e2e/test.HC","version":2},"contentChanges":[{"text":"class Pt { I64 x; I64 y; };\nI64 g;\nI64 G(I64 n) { return n + g; }"}]}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///tmp/lsp%20e2e/test.HC"}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///tmp/lsp%20e2e/test.HC"},"position":{"line":2,"character":22}}}
        ,
        \\{"jsonrpc":"2.0","id":9,"method":"workspace/executeCommand","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///tmp/lsp%20e2e/test.HC"}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    try std.testing.expectEqual(0, session.code);
    const msgs = session.msgs;
    try std.testing.expectEqual(8, msgs.len);

    // initialize response: capabilities and server identity.
    {
        const m = msgs[0];
        try std.testing.expectEqual(1, getInt(m, "id"));
        const caps = get(get(m, "result"), "capabilities");
        try std.testing.expectEqual(1, getInt(caps, "textDocumentSync"));
        try std.testing.expect(get(caps, "documentSymbolProvider") == .bool);
        try std.testing.expect(get(caps, "hoverProvider").bool);
        try std.testing.expectEqualStrings("holyc-lsp", getStr(get(get(m, "result"), "serverInfo"), "name"));
    }

    // didOpen → publishDiagnostics with the error and the warning, 0-based.
    {
        const m = msgs[1];
        try std.testing.expectEqualStrings("textDocument/publishDiagnostics", getStr(m, "method"));
        try std.testing.expectEqualStrings("file:///tmp/lsp%20e2e/test.HC", getStr(get(m, "params"), "uri"));
        const diags = items(get(get(m, "params"), "diagnostics"));
        try std.testing.expectEqual(2, diags.len);
        var saw_error = false;
        var saw_warning = false;
        for (diags) |d| {
            try std.testing.expectEqualStrings("hcc", getStr(d, "source"));
            const start = get(get(d, "range"), "start");
            switch (getInt(d, "severity")) {
                1 => {
                    saw_error = true;
                    try std.testing.expectEqual(0, getInt(start, "line"));
                    try std.testing.expectEqual(24, getInt(start, "character"));
                    try std.testing.expect(std.mem.indexOf(u8, getStr(d, "message"), "undeclared identifier") != null);
                },
                2 => {
                    saw_warning = true;
                    try std.testing.expectEqual(0, getInt(start, "line"));
                    try std.testing.expectEqual(14, getInt(start, "character"));
                    try std.testing.expect(std.mem.indexOf(u8, getStr(d, "message"), "unused") != null);
                },
                else => return error.UnexpectedSeverity,
            }
        }
        try std.testing.expect(saw_error and saw_warning);
    }

    // didChange to clean text → empty diagnostics.
    {
        const m = msgs[2];
        try std.testing.expectEqualStrings("textDocument/publishDiagnostics", getStr(m, "method"));
        try std.testing.expectEqual(0, items(get(get(m, "params"), "diagnostics")).len);
    }

    // documentSymbol: class with field children, global var, function.
    {
        const m = msgs[3];
        try std.testing.expectEqual(2, getInt(m, "id"));
        const syms = items(get(m, "result"));
        try std.testing.expectEqual(3, syms.len);

        try std.testing.expectEqualStrings("Pt", getStr(syms[0], "name"));
        try std.testing.expectEqual(5, getInt(syms[0], "kind"));
        const fields = items(get(syms[0], "children"));
        try std.testing.expectEqual(2, fields.len);
        try std.testing.expectEqualStrings("x", getStr(fields[0], "name"));
        try std.testing.expectEqual(8, getInt(fields[0], "kind"));
        try std.testing.expectEqualStrings("I64", getStr(fields[0], "detail"));

        try std.testing.expectEqualStrings("g", getStr(syms[1], "name"));
        try std.testing.expectEqual(13, getInt(syms[1], "kind"));
        try std.testing.expectEqualStrings("I64", getStr(syms[1], "detail"));

        try std.testing.expectEqualStrings("G", getStr(syms[2], "name"));
        try std.testing.expectEqual(12, getInt(syms[2], "kind"));
        try std.testing.expectEqualStrings("I64 (I64 n)", getStr(syms[2], "detail"));
        const g_start = get(get(get(syms[2], "range"), "start"), "line");
        try std.testing.expectEqual(2, g_start.integer);
        // selectionRange must be contained in range; here they are equal.
        const sel_start = get(get(get(syms[2], "selectionRange"), "start"), "line");
        try std.testing.expectEqual(2, sel_start.integer);
    }

    // hover over `n` in `return n + g` → identifier and inferred type.
    {
        const m = msgs[4];
        try std.testing.expectEqual(3, getInt(m, "id"));
        const contents = get(get(m, "result"), "contents");
        try std.testing.expectEqualStrings("markdown", getStr(contents, "kind"));
        try std.testing.expect(std.mem.indexOf(u8, getStr(contents, "value"), "n: I64") != null);
    }

    // Unknown request → MethodNotFound.
    {
        const m = msgs[5];
        try std.testing.expectEqual(9, getInt(m, "id"));
        try std.testing.expectEqual(-32601, getInt(get(m, "error"), "code"));
    }

    // didClose → empty diagnostics for the closed document.
    {
        const m = msgs[6];
        try std.testing.expectEqualStrings("textDocument/publishDiagnostics", getStr(m, "method"));
        try std.testing.expectEqual(0, items(get(get(m, "params"), "diagnostics")).len);
    }

    // shutdown → null result.
    {
        const m = msgs[7];
        try std.testing.expectEqual(4, getInt(m, "id"));
        try std.testing.expect(get(m, "result") == .null);
    }
}

fn byId(msgs: []std.json.Value, want: i64) std.json.Value {
    for (msgs) |m| {
        if (getInt(m, "id") == want) return m;
    }
    return .null;
}

test "definition jumps to the declaration; on the declaration it yields null (references fallback)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Decoded text (Sum declared on line 0 cols 3..6, called on lines 2 and 4):
    //   U0 Sum()
    //   {
    //     Sum();
    //   }
    //   Sum();
    const session = try runSession(arena, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///t.HC","languageId":"holyc","version":1,"text":"U0 Sum()\n{\n  Sum();\n}\nSum();"}}}
        ,
        // definition on the call (line 4) → jumps to the declaration.
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///t.HC"},"position":{"line":4,"character":1}}}
        ,
        // definition on the declaration name (line 0) → null.
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///t.HC"},"position":{"line":0,"character":4}}}
        ,
        // references on the call, including the declaration.
        \\{"jsonrpc":"2.0","id":4,"method":"textDocument/references","params":{"textDocument":{"uri":"file:///t.HC"},"position":{"line":4,"character":1},"context":{"includeDeclaration":true}}}
        ,
        \\{"jsonrpc":"2.0","id":9,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    try std.testing.expectEqual(0, session.code);
    const msgs = session.msgs;

    // Capabilities advertise the new providers.
    const caps = get(get(byId(msgs, 1), "result"), "capabilities");
    try std.testing.expect(get(caps, "definitionProvider").bool);
    try std.testing.expect(get(caps, "referencesProvider").bool);

    // Definition on the call → Location on the declaration name (line 0, 3..6).
    {
        const loc = get(byId(msgs, 2), "result");
        try std.testing.expectEqualStrings("file:///t.HC", getStr(loc, "uri"));
        const start = get(get(loc, "range"), "start");
        try std.testing.expectEqual(0, getInt(start, "line"));
        try std.testing.expectEqual(3, getInt(start, "character"));
        try std.testing.expectEqual(6, getInt(get(get(loc, "range"), "end"), "character"));
    }

    // Definition on the declaration itself → null (so the editor shows references).
    try std.testing.expect(get(byId(msgs, 3), "result") == .null);

    // References (with declaration) → the decl on line 0 plus the two calls.
    {
        const refs = items(get(byId(msgs, 4), "result"));
        try std.testing.expectEqual(3, refs.len);
        var saw = [_]bool{ false, false, false }; // lines 0, 2, 4
        for (refs) |r| {
            const line = getInt(get(get(r, "range"), "start"), "line");
            switch (line) {
                0 => saw[0] = true,
                2 => saw[1] = true,
                4 => saw[2] = true,
                else => return error.UnexpectedReferenceLine,
            }
        }
        try std.testing.expect(saw[0] and saw[1] and saw[2]);
    }
}

test "definition on a prelude symbol jumps into the extracted core cache" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const cache_dir = "/tmp/holyc-lsp-test-core";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, cache_dir) catch {};
    defer cwd.deleteTree(io, cache_dir) catch {};

    // FltToBits (declared in the prelude's StrPrint.HC) starts at column 17 of
    // the body below; the cursor at column 20 sits inside it.
    const bodies = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///t.HC","languageId":"holyc","version":1,"text":"U0 M() { I64 x = FltToBits(1.0); }"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///t.HC"},"position":{"line":0,"character":20}}}
        ,
        \\{"jsonrpc":"2.0","id":9,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };

    var input: std.Io.Writer.Allocating = .init(gpa);
    defer input.deinit();
    for (bodies) |b| try framing.writeFrame(&input.writer, b);
    var in_r = std.Io.Reader.fixed(input.written());
    var out_w: std.Io.Writer.Allocating = .init(gpa);
    defer out_w.deinit();

    var server = Server.init(gpa, io, &in_r, &out_w.writer);
    server.core_cache_dir = try gpa.dupe(u8, cache_dir); // freed by server.deinit
    defer server.deinit();
    try std.testing.expectEqual(0, try server.run());

    var msgs: std.ArrayList(std.json.Value) = .empty;
    var out_r = std.Io.Reader.fixed(out_w.written());
    while (true) {
        const body = framing.readFrame(&out_r, arena) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        try msgs.append(arena, try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}));
    }

    // The jump lands in the extracted core file, and that file really exists.
    const loc = get(byId(msgs.items, 2), "result");
    try std.testing.expectEqualStrings("file:///tmp/holyc-lsp-test-core/StrPrint.HC", getStr(loc, "uri"));
    const extracted = try cwd.readFileAlloc(io, cache_dir ++ "/StrPrint.HC", arena, .limited(1 << 20));
    try std.testing.expect(std.mem.indexOf(u8, extracted, "FltToBits") != null);
}

test "malformed JSON body gets a ParseError response and the loop survives" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const session = try runSession(arena, &.{
        "{this is not json",
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    try std.testing.expectEqual(0, session.code);
    try std.testing.expectEqual(3, session.msgs.len);
    try std.testing.expectEqual(-32700, getInt(get(session.msgs[0], "error"), "code"));
    try std.testing.expect(get(session.msgs[0], "id") == .null);
    try std.testing.expectEqual(1, getInt(session.msgs[1], "id"));
}

test "exit without shutdown exits 1; end of stream exits 1" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const abrupt = try runSession(arena, &.{
        \\{"jsonrpc":"2.0","method":"exit"}
    });
    try std.testing.expectEqual(1, abrupt.code);
    try std.testing.expectEqual(0, abrupt.msgs.len);

    const eof = try runSession(arena, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    });
    try std.testing.expectEqual(1, eof.code);
    try std.testing.expectEqual(1, eof.msgs.len);
}
