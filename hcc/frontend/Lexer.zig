//! The HolyC lexer: turns source text into a stream of Tokens.
//!
//! The lexer walks an in-memory buffer (source files are read whole by the
//! driver and preprocessor). All syntactically meaningful HolyC characters are
//! ASCII; non-ASCII bytes may appear only inside string/char literals and
//! comments, where they pass through untouched.
//!
//! Identifiers are slices into the source buffer; string literals (which need
//! escape resolution) are allocated from the front-end arena given to `init`.
//! Errors are reported through the shared diagnostics list with stage `.lex`.

const std = @import("std");
const source = @import("source.zig");
const diag = @import("diag.zig");
const token = @import("token.zig");
const Token = token.Token;
const Keyword = token.Keyword;

const Lexer = @This();

pub const Error = diag.Error;

src: []const u8,
arena: std.mem.Allocator,
diags: *diag.Diagnostics,
/// The file-table id stamped onto this lexer's diagnostics; the preprocessor
/// sets it for #include frames (the root source is file 0).
file: u32 = 0,
idx: usize = 0,
line: u32 = 1,
col: u32 = 1,

pub fn init(arena: std.mem.Allocator, diags: *diag.Diagnostics, src: []const u8) Lexer {
    return .{ .src = src, .arena = arena, .diags = diags };
}

/// Produces the next token. Once the input is exhausted this returns an .eof
/// token and keeps returning it, so calling past the end is safe. On
/// `error.CompileFailed` the diagnostics list holds the message and position.
pub fn next(l: *Lexer) Error!Token {
    try l.skipTrivia();

    const start = l.idx;
    const p = l.pos();

    const c = l.peek() orelse return l.tok(.eof, start, p);
    if (isIdentStart(c)) return l.lexIdent(start, p);
    if (isDigit(c)) return l.lexNumber(start, p);
    return switch (c) {
        '"' => l.lexString(start, p),
        '\'' => l.lexChar(start, p),
        else => l.lexOperator(start, p),
    };
}

// ---- cursor ----

fn peek(l: *Lexer) ?u8 {
    return l.peekAt(0);
}

fn peekAt(l: *Lexer, off: usize) ?u8 {
    if (l.idx + off < l.src.len) return l.src[l.idx + off];
    return null;
}

/// Consumes one byte, updating position tracking.
fn bump(l: *Lexer) ?u8 {
    if (l.idx >= l.src.len) return null;
    const b = l.src[l.idx];
    l.idx += 1;
    if (b == '\n') {
        l.line += 1;
        l.col = 1;
    } else {
        l.col += 1;
    }
    return b;
}

fn pos(l: *Lexer) source.Pos {
    return .{ .line = l.line, .col = l.col };
}

fn span(l: *Lexer, start: usize, p: source.Pos) source.Span {
    return .{ .start = start, .end = l.idx, .pos = p };
}

fn tok(l: *Lexer, kind: Token.Kind, start: usize, p: source.Pos) Token {
    return .{ .kind = kind, .span = l.span(start, p) };
}

fn fail(l: *Lexer, p: source.Pos, comptime fmt: []const u8, args: anytype) Error {
    return l.diags.fail(.lex, l.file, p, fmt, args);
}

// ---- trivia: whitespace and comments ----

fn skipTrivia(l: *Lexer) Error!void {
    while (l.peek()) |c| {
        switch (c) {
            ' ', '\t', '\r', '\n' => _ = l.bump(),
            '/' => switch (l.peekAt(1) orelse 0) {
                '/' => {
                    // Line comment: consume to (but not past) end of line.
                    while (l.peek()) |c2| {
                        if (c2 == '\n') break;
                        _ = l.bump();
                    }
                },
                '*' => {
                    const p = l.pos();
                    _ = l.bump(); // /
                    _ = l.bump(); // *
                    while (true) {
                        const c2 = l.peek() orelse
                            return l.fail(p, "unterminated block comment", .{});
                        if (c2 == '*' and (l.peekAt(1) orelse 0) == '/') {
                            _ = l.bump(); // *
                            _ = l.bump(); // /
                            break;
                        }
                        _ = l.bump();
                    }
                },
                else => return,
            },
            else => return,
        }
    }
}

// ---- identifiers & keywords ----

fn lexIdent(l: *Lexer, start: usize, p: source.Pos) Token {
    while (l.peek()) |c| {
        if (!isIdentContinue(c)) break;
        _ = l.bump();
    }
    const text = l.src[start..l.idx];
    if (Keyword.fromString(text)) |kw| {
        return l.tok(.{ .keyword = kw }, start, p);
    }
    return l.tok(.{ .ident = text }, start, p);
}

// ---- numbers ----

fn lexNumber(l: *Lexer, start: usize, p: source.Pos) Error!Token {
    // Radix-prefixed integers: 0x.. (hex). HolyC has no binary (0b) literals.
    if (l.peek() == '0') {
        switch (l.peekAt(1) orelse 0) {
            'x', 'X' => {
                _ = l.bump(); // 0
                _ = l.bump(); // x
                return l.lexRadixInt(start, p, 16);
            },
            else => {},
        }
    }

    // Decimal integer or float. Scan the integer part first.
    while (isDigit(l.peek() orelse 0)) _ = l.bump();

    var is_float = false;

    // Fractional part: a '.' followed by a digit, so `1.foo` and `1..2` are
    // not mis-lexed as floats.
    if (l.peek() == '.' and isDigit(l.peekAt(1) orelse 0)) {
        is_float = true;
        _ = l.bump(); // .
        while (isDigit(l.peek() orelse 0)) _ = l.bump();
    }

    // Exponent: e/E with optional sign and at least one digit.
    if (l.peek()) |c| {
        if (c == 'e' or c == 'E') {
            var k: usize = 1;
            if (l.peekAt(1)) |c2| {
                if (c2 == '+' or c2 == '-') k = 2;
            }
            if (isDigit(l.peekAt(k) orelse 0)) {
                is_float = true;
                _ = l.bump(); // e
                if (k == 2) _ = l.bump(); // sign
                while (isDigit(l.peek() orelse 0)) _ = l.bump();
            }
        }
    }

    const text = l.src[start..l.idx];
    if (is_float) {
        const v = std.fmt.parseFloat(f64, text) catch
            return l.fail(p, "invalid float literal `{s}`", .{text});
        return l.tok(.{ .float = v }, start, p);
    }
    if (text.len > 1 and text[0] == '0') {
        // A leading `0` on a multi-digit integer means octal, as in C.
        const v = parseIntStr(text, 8) orelse
            return l.fail(p, "invalid octal literal `{s}` (digits must be 0-7)", .{text});
        return l.tok(.{ .int = v }, start, p);
    }
    const v = parseIntStr(text, 10) orelse
        return l.fail(p, "integer literal `{s}` out of range", .{text});
    return l.tok(.{ .int = v }, start, p);
}

fn lexRadixInt(l: *Lexer, start: usize, p: source.Pos, radix: u8) Error!Token {
    const digits_start = l.idx; // past the "0x" already consumed
    while (isHexDigit(l.peek() orelse 0)) _ = l.bump();
    if (l.idx == digits_start) {
        return l.fail(p, "missing digits after radix prefix", .{});
    }
    const v = parseIntStr(l.src[digits_start..l.idx], radix) orelse
        return l.fail(p, "integer literal out of range", .{});
    return l.tok(.{ .int = v }, start, p);
}

// ---- string literals ----

fn lexString(l: *Lexer, start: usize, p: source.Pos) Error!Token {
    _ = l.bump(); // opening "
    var sb: std.ArrayList(u8) = .empty;
    while (true) {
        const c = l.peek() orelse
            return l.fail(p, "unterminated string literal", .{});
        switch (c) {
            '\n' => return l.fail(p, "unterminated string literal", .{}),
            '"' => {
                _ = l.bump();
                return l.tok(.{ .str = sb.items }, start, p);
            },
            '\\' => {
                _ = l.bump();
                const ch = try l.lexEscape(p);
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(ch, &buf) catch unreachable;
                try sb.appendSlice(l.arena, buf[0..n]);
            },
            else => {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(l.bumpChar(), &buf) catch unreachable;
                try sb.appendSlice(l.arena, buf[0..n]);
            },
        }
    }
}

// ---- character constants ----

/// Lexes a HolyC character constant, which may hold several characters packed
/// little-endian into an I64. So 'A' == 0x41 and 'AB' == 0x4241.
fn lexChar(l: *Lexer, start: usize, p: source.Pos) Error!Token {
    _ = l.bump(); // opening '
    var value: i64 = 0;
    var count: u32 = 0;
    while (true) {
        const c = l.peek() orelse
            return l.fail(p, "unterminated character constant", .{});
        switch (c) {
            '\n' => return l.fail(p, "unterminated character constant", .{}),
            '\'' => {
                _ = l.bump();
                if (count == 0) {
                    return l.fail(p, "empty character constant", .{});
                }
                return l.tok(.{ .char = value }, start, p);
            },
            '\\' => {
                _ = l.bump();
                const ch = try l.lexEscape(p);
                try l.packChar(&value, &count, ch, p);
            },
            else => try l.packChar(&value, &count, l.bumpChar(), p),
        }
    }
}

fn packChar(l: *Lexer, value: *i64, count: *u32, ch: u21, p: source.Pos) Error!void {
    if (count.* >= 8) {
        return l.fail(p, "character constant too long (max 8 bytes)", .{});
    }
    if (ch > 0xFF) {
        return l.fail(p, "character constant byte out of range", .{});
    }
    value.* |= @as(i64, ch) << @intCast(8 * count.*);
    count.* += 1;
}

/// Consumes one escape sequence body and returns the resulting character. The
/// backslash has already been eaten.
fn lexEscape(l: *Lexer, p: source.Pos) Error!u21 {
    const c = l.bump() orelse
        return l.fail(p, "unterminated escape sequence", .{});
    return switch (c) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        '0' => 0,
        '\\' => '\\',
        '\'' => '\'',
        '"' => '"',
        '`' => '`',
        'a' => 0x07, // bell
        'b' => 0x08, // backspace
        'f' => 0x0C, // form feed
        'v' => 0x0B, // vertical tab
        'x' => {
            // \xHH: one or two hex digits.
            var val: u21 = 0;
            var n: usize = 0;
            while (n < 2 and isHexDigit(l.peek() orelse 0)) : (n += 1) {
                val = val * 16 + hexVal(l.bump().?);
            }
            if (n == 0) {
                return l.fail(p, "expected hex digits after `\\x`", .{});
            }
            return val;
        },
        else => l.fail(p, "unknown escape sequence `\\{c}`", .{c}),
    };
}

/// Consumes one UTF-8 encoded character at the cursor and returns it. Assumes
/// a byte is available; invalid UTF-8 yields the replacement character.
fn bumpChar(l: *Lexer) u21 {
    const first = l.src[l.idx];
    const len = std.unicode.utf8ByteSequenceLength(first) catch {
        _ = l.bump();
        return std.unicode.replacement_character;
    };
    if (l.idx + len > l.src.len) {
        _ = l.bump();
        return std.unicode.replacement_character;
    }
    const r = std.unicode.utf8Decode(l.src[l.idx..][0..len]) catch {
        _ = l.bump();
        return std.unicode.replacement_character;
    };
    for (0..len) |_| _ = l.bump();
    return r;
}

// ---- operators & punctuation ----

fn lexOperator(l: *Lexer, start: usize, p: source.Pos) Error!Token {
    const b = l.peek().?;
    const b2 = l.peekAt(1) orelse 0;
    const b3 = l.peekAt(2) orelse 0;

    // Maximal munch: try the longest operators first.
    const kind: Token.Kind = switch (b) {
        '+' => switch (b2) {
            '+' => l.eat(2, .plus_plus),
            '=' => l.eat(2, .plus_eq),
            else => l.eat(1, .plus),
        },
        '-' => switch (b2) {
            '-' => l.eat(2, .minus_minus),
            '=' => l.eat(2, .minus_eq),
            '>' => l.eat(2, .arrow),
            else => l.eat(1, .minus),
        },
        '*' => if (b2 == '=') l.eat(2, .star_eq) else l.eat(1, .star),
        '/' => if (b2 == '=') l.eat(2, .slash_eq) else l.eat(1, .slash),
        '%' => if (b2 == '=') l.eat(2, .percent_eq) else l.eat(1, .percent),
        '=' => if (b2 == '=') l.eat(2, .eq_eq) else l.eat(1, .eq),
        '!' => if (b2 == '=') l.eat(2, .ne) else l.eat(1, .not),
        '<' => if (b2 == '<' and b3 == '=')
            l.eat(3, .shl_eq)
        else if (b2 == '<')
            l.eat(2, .shl)
        else if (b2 == '=')
            l.eat(2, .le)
        else
            l.eat(1, .lt),
        '>' => if (b2 == '>' and b3 == '=')
            l.eat(3, .shr_eq)
        else if (b2 == '>')
            l.eat(2, .shr)
        else if (b2 == '=')
            l.eat(2, .ge)
        else
            l.eat(1, .gt),
        '&' => switch (b2) {
            '&' => l.eat(2, .and_and),
            '=' => l.eat(2, .amp_eq),
            else => l.eat(1, .amp),
        },
        '|' => switch (b2) {
            '|' => l.eat(2, .or_or),
            '=' => l.eat(2, .pipe_eq),
            else => l.eat(1, .pipe),
        },
        '^' => switch (b2) {
            '=' => l.eat(2, .caret_eq),
            '^' => l.eat(2, .caret_caret),
            else => l.eat(1, .caret),
        },
        '~' => l.eat(1, .tilde),
        '.' => if (b2 == '.' and b3 == '.')
            l.eat(3, .dot_dot_dot)
        else
            l.eat(1, .dot),
        ':' => l.eat(1, .colon),
        '(' => l.eat(1, .l_paren),
        ')' => l.eat(1, .r_paren),
        '{' => l.eat(1, .l_brace),
        '}' => l.eat(1, .r_brace),
        '[' => l.eat(1, .l_bracket),
        ']' => l.eat(1, .r_bracket),
        ',' => l.eat(1, .comma),
        ';' => l.eat(1, .semicolon),
        '#' => l.eat(1, .hash),
        '`' => l.eat(1, .backtick),
        else => return l.fail(p, "unexpected character `{c}`", .{b}),
    };
    return l.tok(kind, start, p);
}

fn eat(l: *Lexer, n: usize, kind: Token.Kind) Token.Kind {
    for (0..n) |_| _ = l.bump();
    return kind;
}

// ---- byte classification ----

fn isIdentStart(c: u8) bool {
    return c == '_' or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn hexVal(c: u8) u21 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => 0,
    };
}

/// Parses an integer in the given radix into an i64. HolyC integers are
/// 64-bit, so any 64-bit pattern is accepted: 0xFFFFFFFFFFFFFFFF wraps to -1,
/// matching C-like signed/unsigned reinterpretation.
fn parseIntStr(s: []const u8, radix: u8) ?i64 {
    if (std.fmt.parseInt(i64, s, radix)) |v| return v else |_| {}
    if (std.fmt.parseInt(u64, s, radix)) |v| return @bitCast(v) else |_| {}
    return null;
}

// ---- tests ----

const testing = std.testing;

fn lexAll(arena: std.mem.Allocator, src: []const u8, out: *std.ArrayList(Token)) !void {
    var diags = diag.Diagnostics.init(arena);
    var l = Lexer.init(arena, &diags, src);
    while (true) {
        const t = try l.next();
        try out.append(arena, t);
        if (t.kind == .eof) return;
    }
}

test "keywords, idents, and operators" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var toks: std.ArrayList(Token) = .empty;
    try lexAll(arena, "I64 x = a+++b <<= 1; // note\nx->y ^^ z", &toks);

    const tags = [_]Token.Kind.Tag{
        .keyword, .ident, .eq,        .ident, .plus_plus, .plus,  .ident,
        .shl_eq,  .int,   .semicolon, .ident, .arrow,     .ident, .caret_caret,
        .ident,   .eof,
    };
    try testing.expectEqual(tags.len, toks.items.len);
    for (tags, toks.items) |want, got| {
        try testing.expectEqual(want, @as(Token.Kind.Tag, got.kind));
    }
    try testing.expectEqual(Keyword.I64, toks.items[0].kind.keyword);
    try testing.expectEqualStrings("x", toks.items[1].kind.ident);
}

test "numbers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var toks: std.ArrayList(Token) = .empty;
    try lexAll(arena, "42 0x2A 052 1.5 1e3 2.5e-1 0xFFFFFFFFFFFFFFFF", &toks);

    try testing.expectEqual(@as(i64, 42), toks.items[0].kind.int);
    try testing.expectEqual(@as(i64, 42), toks.items[1].kind.int);
    try testing.expectEqual(@as(i64, 42), toks.items[2].kind.int);
    try testing.expectEqual(@as(f64, 1.5), toks.items[3].kind.float);
    try testing.expectEqual(@as(f64, 1e3), toks.items[4].kind.float);
    try testing.expectEqual(@as(f64, 2.5e-1), toks.items[5].kind.float);
    try testing.expectEqual(@as(i64, -1), toks.items[6].kind.int);
}

test "dots: floats vs ranges vs varargs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var toks: std.ArrayList(Token) = .empty;
    try lexAll(arena, "1...3 1.5 x.y", &toks);
    try testing.expectEqual(@as(i64, 1), toks.items[0].kind.int);
    try testing.expect(toks.items[1].kind == .dot_dot_dot);
    try testing.expectEqual(@as(i64, 3), toks.items[2].kind.int);
    try testing.expectEqual(@as(f64, 1.5), toks.items[3].kind.float);
    try testing.expect(toks.items[5].kind == .dot);
}

test "strings and escapes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var toks: std.ArrayList(Token) = .empty;
    try lexAll(arena, "\"a\\tb\\x41\\n\"", &toks);
    try testing.expectEqualStrings("a\tbA\n", toks.items[0].kind.str);
}

test "char packing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var toks: std.ArrayList(Token) = .empty;
    try lexAll(arena, "'A' 'AB' '\\n'", &toks);
    try testing.expectEqual(@as(i64, 0x41), toks.items[0].kind.char);
    try testing.expectEqual(@as(i64, 0x4241), toks.items[1].kind.char);
    try testing.expectEqual(@as(i64, '\n'), toks.items[2].kind.char);
}

test "lex errors carry positions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var diags = diag.Diagnostics.init(arena);
    var l = Lexer.init(arena, &diags, "\n  @");
    try testing.expectError(error.CompileFailed, l.next());
    const d = diags.firstError().?;
    try testing.expectEqual(diag.Stage.lex, d.stage);
    try testing.expectEqual(@as(u32, 2), d.pos.line);
    try testing.expectEqual(@as(u32, 3), d.pos.col);
}

test "positions and spans" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var diags = diag.Diagnostics.init(arena);
    var l = Lexer.init(arena, &diags, "ab\n  cd");
    const t1 = try l.next();
    try testing.expectEqual(@as(usize, 0), t1.span.start);
    try testing.expectEqual(@as(usize, 2), t1.span.end);
    const t2 = try l.next();
    try testing.expectEqual(@as(u32, 2), t2.span.pos.line);
    try testing.expectEqual(@as(u32, 3), t2.span.pos.col);
}
