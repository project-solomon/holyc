//! LSP base-protocol framing: every message is a block of RFC-822-style
//! headers terminated by an empty line, followed by a JSON body of exactly
//! `Content-Length` bytes:
//!
//!   Content-Length: N\r\n
//!   \r\n
//!   {...N bytes of JSON...}
//!
//! The transport is decoupled from the process: frames read from any
//! *std.Io.Reader and write to any *std.Io.Writer, so tests drive the server
//! with in-memory streams.

const std = @import("std");

pub const ReadError = error{
    /// The stream ended between frames (clean end of session) or mid-frame.
    EndOfStream,
    /// The header block ended without a parseable Content-Length.
    MissingContentLength,
    /// A single header line exceeded the reader's buffer capacity.
    StreamTooLong,
    ReadFailed,
    OutOfMemory,
};

/// Reads one framed message and returns its body, allocated with `gpa`
/// (caller frees). Unknown headers (Content-Type, ...) are ignored; header
/// names are case-insensitive; a lone "\n" line terminator is tolerated.
pub fn readFrame(r: *std.Io.Reader, gpa: std.mem.Allocator) ReadError![]u8 {
    var content_length: ?usize = null;
    while (true) {
        const raw = r.takeDelimiterInclusive('\n') catch |e| switch (e) {
            error.EndOfStream => return error.EndOfStream,
            error.ReadFailed => return error.ReadFailed,
            error.StreamTooLong => return error.StreamTooLong,
        };
        const line = std.mem.trimEnd(u8, raw, "\r\n");
        if (line.len == 0) break; // blank line: end of headers
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch null;
        }
    }
    const len = content_length orelse return error.MissingContentLength;
    return r.readAlloc(gpa, len) catch |e| switch (e) {
        error.EndOfStream => error.EndOfStream,
        error.ReadFailed => error.ReadFailed,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Writes one framed message and flushes, so the peer sees it immediately.
pub fn writeFrame(w: *std.Io.Writer, body: []const u8) std.Io.Writer.Error!void {
    try w.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try w.writeAll(body);
    try w.flush();
}

// ---- tests ----

/// A test reader that delivers at most `chunk` bytes per stream call, to
/// exercise frames arriving split across read boundaries.
const ChunkedReader = struct {
    data: []const u8,
    pos: usize = 0,
    chunk: usize,
    interface: std.Io.Reader,

    fn init(data: []const u8, chunk: usize, buffer: []u8) ChunkedReader {
        return .{
            .data = data,
            .chunk = chunk,
            .interface = .{
                .vtable = &.{ .stream = stream },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *ChunkedReader = @fieldParentPtr("interface", r);
        if (self.pos >= self.data.len) return error.EndOfStream;
        var n: usize = @min(self.chunk, self.data.len - self.pos);
        n = limit.minInt(n);
        try w.writeAll(self.data[self.pos..][0..n]);
        self.pos += n;
        return n;
    }
};

test "frame round-trip" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}";
    try writeFrame(&aw.writer, body);

    var r = std.Io.Reader.fixed(aw.written());
    const got = try readFrame(&r, gpa);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(body, got);
    try std.testing.expectError(error.EndOfStream, readFrame(&r, gpa));
}

test "two frames back-to-back" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeFrame(&aw.writer, "{\"a\":1}");
    try writeFrame(&aw.writer, "{\"b\":22}");

    var r = std.Io.Reader.fixed(aw.written());
    const first = try readFrame(&r, gpa);
    defer gpa.free(first);
    const second = try readFrame(&r, gpa);
    defer gpa.free(second);
    try std.testing.expectEqualStrings("{\"a\":1}", first);
    try std.testing.expectEqualStrings("{\"b\":22}", second);
}

test "frames split across read boundaries" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const body1 = "{\"method\":\"one\",\"params\":{\"x\":\"hello world\"}}";
    const body2 = "{\"method\":\"two\"}";
    try writeFrame(&aw.writer, body1);
    try writeFrame(&aw.writer, body2);

    // 3 bytes per read: headers and bodies both straddle boundaries.
    var buf: [256]u8 = undefined;
    var cr = ChunkedReader.init(aw.written(), 3, &buf);
    const first = try readFrame(&cr.interface, gpa);
    defer gpa.free(first);
    const second = try readFrame(&cr.interface, gpa);
    defer gpa.free(second);
    try std.testing.expectEqualStrings(body1, first);
    try std.testing.expectEqualStrings(body2, second);
    try std.testing.expectError(error.EndOfStream, readFrame(&cr.interface, gpa));
}

test "extra headers and case-insensitivity are tolerated" {
    const gpa = std.testing.allocator;
    const wire = "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n" ++
        "CONTENT-LENGTH: 2\r\n\r\n{}";
    var r = std.Io.Reader.fixed(wire);
    const got = try readFrame(&r, gpa);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("{}", got);
}

test "missing Content-Length is an error, not a crash" {
    const gpa = std.testing.allocator;
    var r = std.Io.Reader.fixed("Content-Type: text/plain\r\n\r\n{}");
    try std.testing.expectError(error.MissingContentLength, readFrame(&r, gpa));
}
