//! Token definitions for the HolyC lexer.

const std = @import("std");
const source = @import("source.zig");

/// A HolyC keyword: a reserved word or built-in type name. The lexer recognises
/// keywords directly (`Keyword.fromString`), so the parser never
/// string-compares identifiers. Each tag's name is the keyword's exact source
/// spelling.
pub const Keyword = enum {
    // Built-in types. HolyC's default integer is I64 and there is no F32.
    U0,
    I0,
    I8,
    U8,
    I16,
    U16,
    I32,
    U32,
    I64,
    U64,
    F64,

    // Control flow.
    @"if",
    @"else",
    @"while",
    do,
    @"for",
    @"switch",
    sub_switch,
    case,
    default,
    @"break",
    @"return",
    goto,
    lock,

    // Aggregates / declarations.
    class,
    @"union",
    public,
    sizeof,
    offset,

    // Exceptions.
    @"try",
    @"catch",
    throw,

    // Switch-range markers (start: ... end: inside a switch [...]).
    start,
    end,

    // Storage classes: `reg`/`noreg` are the register-placement storage class
    // on a local (`I64 reg R15 i, noreg j;`).
    reg,
    noreg,

    // Inline assembly: `asm [arch] { … }`.
    @"asm",

    // Asm linkage: `_extern <LABEL> <sig>;` binds a HolyC name to an
    // asm-defined label; `_import` is accepted as an alias.
    _extern,
    _import,

    // Dynamic-library import: `extern <ret> <name>(<params>);` declares a
    // function provided by a shared library, bound at load time.
    @"extern",

    // Reserved HolyC keywords: lexed so they stay reserved words (using one as
    // an identifier is rejected, matching TempleOS), but the feature behind
    // each is not implemented. Neither is matched by the parser.
    lastclass,
    no_warn,

    const spellings = blk: {
        const fields = @typeInfo(Keyword).@"enum".fields;
        var entries: [fields.len]struct { []const u8, Keyword } = undefined;
        for (fields, 0..) |f, i| {
            entries[i] = .{ f.name, @field(Keyword, f.name) };
        }
        break :blk std.StaticStringMap(Keyword).initComptime(entries);
    };

    /// The keyword spelled `s`, or null if `s` is not a reserved word.
    /// Case-sensitive.
    pub fn fromString(s: []const u8) ?Keyword {
        return spellings.get(s);
    }

    /// The keyword's canonical source spelling (e.g. .@"if" -> "if").
    pub fn spelling(k: Keyword) []const u8 {
        return @tagName(k);
    }

    /// Whether the keyword names a built-in type. This lets the parser tell
    /// declarations from expression statements.
    pub fn isType(k: Keyword) bool {
        return switch (k) {
            .U0, .I0, .I8, .U8, .I16, .U16, .I32, .U32, .I64, .U64, .F64 => true,
            else => false,
        };
    }
};

/// A lexed token: its kind (with the decoded payload for literal kinds) and
/// where it came from. Comparing against a payload-free kind is just
/// `tok.kind == .plus`; payload kinds are matched with a switch capture.
pub const Token = struct {
    kind: Kind,
    span: source.Span = .{},

    pub const Kind = union(enum) {
        // ---- Literals & names ----

        /// An integer literal (decimal, 0x hex, or 0-prefixed octal), already
        /// parsed.
        int: i64,
        /// A floating-point literal (HolyC only has F64).
        float: f64,
        /// A string literal with escapes already resolved.
        str: []const u8,
        /// A character constant. HolyC packs up to 8 chars little-endian into
        /// an I64, e.g. 'AB' == 0x4241.
        char: i64,
        /// An identifier (not a keyword).
        ident: []const u8,
        /// A reserved word or built-in type name.
        keyword: Keyword,

        // ---- Arithmetic ----
        plus, // +
        minus, // -
        star, // *
        slash, // /
        percent, // %

        // ---- Assignment (compound and simple) ----
        eq, // =
        plus_eq, // +=
        minus_eq, // -=
        star_eq, // *=
        slash_eq, // /=
        percent_eq, // %=
        amp_eq, // &=
        pipe_eq, // |=
        caret_eq, // ^=
        shl_eq, // <<=
        shr_eq, // >>=

        // ---- Increment / decrement ----
        plus_plus, // ++
        minus_minus, // --

        // ---- Comparison ----
        eq_eq, // ==
        ne, // !=
        lt, // <
        gt, // >
        le, // <=
        ge, // >=

        // ---- Logical ----
        and_and, // &&
        or_or, // ||
        caret_caret, // ^^   (logical XOR)
        not, // !

        // ---- Bitwise ----
        amp, // &
        pipe, // |
        caret, // ^
        tilde, // ~
        shl, // <<
        shr, // >>

        // ---- Punctuation ----
        l_paren, // (
        r_paren, // )
        l_brace, // {
        r_brace, // }
        l_bracket, // [
        r_bracket, // ]
        comma, // ,
        semicolon, // ;
        dot, // .
        arrow, // ->
        colon, // :
        dot_dot_dot, // ...   (varargs / case ranges)
        hash, // #     (preprocessor directives)
        backtick, // `     (power operator)

        /// End of input. Always the last token.
        eof,

        pub const Tag = std.meta.Tag(Kind);

        /// A readable spelling of the token kind for diagnostics: a
        /// descriptive name for the literal/name kinds, and the source symbol
        /// for operators and punctuation.
        pub fn describe(t: Tag) []const u8 {
            return switch (t) {
                .int => "integer",
                .float => "float",
                .str => "string",
                .char => "char",
                .ident => "identifier",
                .keyword => "keyword",
                .plus => "+",
                .minus => "-",
                .star => "*",
                .slash => "/",
                .percent => "%",
                .eq => "=",
                .plus_eq => "+=",
                .minus_eq => "-=",
                .star_eq => "*=",
                .slash_eq => "/=",
                .percent_eq => "%=",
                .amp_eq => "&=",
                .pipe_eq => "|=",
                .caret_eq => "^=",
                .shl_eq => "<<=",
                .shr_eq => ">>=",
                .plus_plus => "++",
                .minus_minus => "--",
                .eq_eq => "==",
                .ne => "!=",
                .lt => "<",
                .gt => ">",
                .le => "<=",
                .ge => ">=",
                .and_and => "&&",
                .or_or => "||",
                .caret_caret => "^^",
                .not => "!",
                .amp => "&",
                .pipe => "|",
                .caret => "^",
                .tilde => "~",
                .shl => "<<",
                .shr => ">>",
                .l_paren => "(",
                .r_paren => ")",
                .l_brace => "{",
                .r_brace => "}",
                .l_bracket => "[",
                .r_bracket => "]",
                .comma => ",",
                .semicolon => ";",
                .dot => ".",
                .arrow => "->",
                .colon => ":",
                .dot_dot_dot => "...",
                .hash => "#",
                .backtick => "`",
                .eof => "EOF",
            };
        }
    };

    /// The active kind tag, for matching without caring about payloads.
    pub fn tag(t: Token) Kind.Tag {
        return t.kind;
    }

    /// Renders a token with its decoded payload, for debugging.
    pub fn format(t: Token, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (t.kind) {
            .int => |v| try w.print("Int({d})", .{v}),
            .float => |v| try w.print("Float({d})", .{v}),
            .str => |s| try w.print("Str(\"{s}\")", .{s}),
            .char => |v| try w.print("Char({d})", .{v}),
            .ident => |s| try w.print("Ident(\"{s}\")", .{s}),
            .keyword => |k| try w.print("Keyword({s})", .{k.spelling()}),
            else => try w.writeAll(Kind.describe(t.kind)),
        }
    }
};

test "keyword lookup round-trips every spelling" {
    inline for (@typeInfo(Keyword).@"enum".fields) |f| {
        const k = @field(Keyword, f.name);
        try std.testing.expectEqual(k, Keyword.fromString(k.spelling()).?);
    }
    try std.testing.expectEqual(@as(?Keyword, null), Keyword.fromString("notakeyword"));
    try std.testing.expectEqual(@as(?Keyword, null), Keyword.fromString("If")); // case-sensitive
}

test "type keywords" {
    try std.testing.expect(Keyword.I64.isType());
    try std.testing.expect(Keyword.F64.isType());
    try std.testing.expect(!Keyword.@"if".isType());
    try std.testing.expect(!Keyword.lastclass.isType());
}

test "kind tag comparison" {
    const t: Token = .{ .kind = .{ .int = 42 } };
    try std.testing.expect(t.kind == .int);
    try std.testing.expect(t.kind != .plus);
}
