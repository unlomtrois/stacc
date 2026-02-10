const std = @import("std");
const Utf8View = std.unicode.Utf8View;
const Utf8Iterator = std.unicode.Utf8Iterator;

const Token = @import("token.zig").Token;

const keywords = std.StaticStringMap(Token.Tag).initComptime(.{
    .{ "let", .keyword_let },
});

const UTF8_BOM_SEQUENCE = "\xEF\xBB\xBF";
const MAX_ASCII = 0x7F; // useful ASCII range is 0-127

pub const Lexer = struct {
    src: []const u8,
    last_advance_len: usize,
    utf8_view: Utf8View,
    utf8_iter: Utf8Iterator,

    pub fn init(src: []const u8) !Lexer {
        const view = try Utf8View.init(src);
        return Lexer.initFromUtf8View(view);
    }

    pub fn initFromUtf8View(view: Utf8View) Lexer {
        const src = view.bytes;
        const bom_present = std.mem.startsWith(u8, src, UTF8_BOM_SEQUENCE);
        const offset: usize = if (bom_present) UTF8_BOM_SEQUENCE.len else 0;

        var iter = view.iterator();
        iter.i = offset;

        return Lexer{
            .src = src,
            .last_advance_len = 0,
            .utf8_view = view,
            .utf8_iter = iter,
        };
    }

    pub fn next(self: *Lexer) ?Token {
        self.skipWhitespace();
        if (self.isAtEnd()) {
            return Token{
                .start = self.utf8_iter.i,
                .end = self.utf8_iter.i,
                .tag = .eof,
            };
        }

        const start_pos = self.utf8_iter.i;
        const c = self.advance();

        const tag: Token.Tag = switch (c) {
            '0'...'9' => self.lexNumber(),
            'a'...'z', 'A'...'Z', '_' => self.lexIdentifier(),
            '"' => self.lexString(),

            // scope operators
            '.' => .dot,
            ';' => .semicolon,

            // operators
            '=' => if (self.match('=')) .equal_equal else .equal,
            '>' => if (self.match('=')) .greater_equal else .greater_than,
            '<' => if (self.match('=')) .less_equal else .less_than,
            '!' => if (self.match('=')) .not_equal else .invalid,
            '?' => if (self.match('=')) .question_equal else .invalid,

            // arithmetic operators
            '+' => .plus,
            '-' => .minus,
            '*' => .multiply,
            '/' => .divide,

            // blocks
            '{' => .l_brace,
            '}' => .r_brace,
            '[' => .l_bracket,
            ']' => .r_bracket,
            '(' => .l_paren,
            ')' => .r_paren,

            else => blk: {
                if (isIdentifierScalar(c)) break :blk self.lexIdentifier();
                break :blk .invalid;
            },
        };

        return Token{
            .tag = tag,
            .start = start_pos,
            .end = self.utf8_iter.i,
        };
    }

    fn lexIdentifier(self: *Lexer) Token.Tag {
        const start = self.utf8_iter.i - self.last_advance_len;
        while (self.peekScalar()) |scalar| {
            if (!isIdentifierScalar(scalar)) break;
            _ = self.advance();
        }
        const end = self.utf8_iter.i;

        const content = self.src[start..end];
        return keywords.get(content) orelse .identifier;
    }

    fn lexNumber(self: *Lexer) Token.Tag {
        while (self.peekAscii()) |ascii| {
            if (!std.ascii.isDigit(ascii)) break;
            _ = self.advance();
        }

        if (self.peekScalar()) |scalar| {
            if (isIdentifierScalar(scalar)) {
                while (self.peekScalar()) |cont| {
                    if (!isIdentifierScalar(cont)) break;
                    _ = self.advance();
                }
                return .identifier;
            }
        }

        return .literal_number;
    }

    fn lexString(self: *Lexer) Token.Tag {
        while (self.peekScalar()) |scalar| {
            if (scalar == '"') break;
            _ = self.advance();
        }
        if (self.isAtEnd()) {
            return .invalid; // unterminated string
        }
        _ = self.advance(); // consume closing quote

        return .literal_string;
    }

    fn lexEqual(self: *Lexer) Token.Tag {
        if (self.peekAscii()) |next_ascii| {
            if (next_ascii == '=') {
                _ = self.advance(); // consume the second '='
                return .equal_equal;
            }
        }

        return .equal; // just a single '='
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.peekScalar()) |scalar| {
            switch (scalar) {
                ' ', '\t', '\r', '\n' => {
                    _ = self.advance();
                },
                '#' => {
                    // Consume '#' and skip until end of line
                    _ = self.advance();
                    while (self.peekScalar()) |comment_scalar| {
                        if (comment_scalar == '\n') break;
                        _ = self.advance();
                    }
                },
                else => return,
            }
        }
    }

    /// Returns whether a Unicode scalar is valid as a continuing part of an identifier.
    /// Standard ASCII is restricted to alphanumeric, underscores, and single quotes.
    /// Non-ASCII Unicode scalars are unconditionally allowed to support international
    /// identifiers (e.g., UTF-8 variable names).
    inline fn isIdentifierScalar(c: u21) bool {
        // 0 is explicitly invalid
        if (c == 0) return false;
        // Standard ASCII range (0x01 - 0x7F)
        if (c <= MAX_ASCII) {
            const ascii: u8 = @intCast(c);
            if (std.ascii.isAlphanumeric(ascii)) return true;
            return switch (ascii) {
                '_' => true,
                else => false,
            };
        }
        // Allow all non-ASCII scalars (0x80 and above) for identifiers.
        return true;
    }

    inline fn isAtEnd(self: *Lexer) bool {
        return self.utf8_iter.i >= self.src.len;
    }

    inline fn peekScalar(self: *Lexer) ?u21 {
        if (self.isAtEnd()) return null;
        // Peek at codepoint without advancing - save position, get codepoint, restore
        const saved_i = self.utf8_iter.i;
        const codepoint = self.utf8_iter.nextCodepoint();
        self.utf8_iter.i = saved_i; // Restore position
        return codepoint;
    }

    inline fn peekAscii(self: *Lexer) ?u8 {
        if (self.isAtEnd()) return null;
        const byte = self.src[self.utf8_iter.i];
        if (byte & 0x80 != 0) return null;
        return byte;
    }

    fn advance(self: *Lexer) u21 {
        const start_pos = self.utf8_iter.i;
        const codepoint = self.utf8_iter.nextCodepoint() orelse unreachable;
        self.last_advance_len = self.utf8_iter.i - start_pos;
        return codepoint;
    }

    /// Checks if the next character matches 'expected_char'. If it does,
    /// the character is consumed and `true` is returned. Otherwise,
    /// `false` is returned and the position is unchanged.
    inline fn match(self: *Lexer, expected: u8) bool {
        if (self.isAtEnd()) return false;
        if (self.src[self.utf8_iter.i] != expected) return false;
        _ = self.advance();
        return true;
    }
};

/// Little helper for tests
fn helper(src: []const u8, expected: []const Token.Tag) !void {
    var lexer = try Lexer.init(src);

    for (expected) |expected_tag| {
        const token = lexer.next() orelse {
            return error.UnexpectedEOF;
        };
        try std.testing.expectEqual(expected_tag, token.tag);
    }

    try std.testing.expectEqual(Token.Tag.eof, lexer.next().?.tag);
}

test "2 + 2 = 4" {
    const src = "2 + 2 = 4";
    try helper(src, &[_]Token.Tag{ .literal_number, .plus, .literal_number, .equal, .literal_number });
}

test "parens: (2 + 2) * 2 = 8" {
    const src = "(2 + 2) * 2 = 8";
    try helper(src, &[_]Token.Tag{ .l_paren, .literal_number, .plus, .literal_number, .r_paren, .multiply, .literal_number, .equal, .literal_number });
}

test "identifiers" {
    const src = "let key = 5";
    try helper(src, &[_]Token.Tag{ .keyword_let, .identifier, .equal, .literal_number });
}

test "strings" {
    const src = "let x = \"test string\"";
    try helper(src, &.{ .keyword_let, .identifier, .equal, .literal_string });
}

test "strings - not terminated" {
    const src = "\"not terminated string";
    try helper(src, &.{.invalid});
}

test "greater less equal operators" {
    const src =
        \\ age > 18
        \\ age < 18
        \\ age >= 18
        \\ age <= 18
    ;

    try helper(src, &[_]Token.Tag{
        .identifier, .greater_than,  .literal_number,
        .identifier, .less_than,     .literal_number,
        .identifier, .greater_equal, .literal_number,
        .identifier, .less_equal,    .literal_number,
    });
}

test "different equal operators" {
    const src =
        \\ capital = c_france
        \\ age == 18
        \\ age != 18
        \\ this ?= c_france
    ;

    try helper(src, &[_]Token.Tag{
        .identifier, .equal,          .identifier,
        .identifier, .equal_equal,    .literal_number,
        .identifier, .not_equal,      .literal_number,
        .identifier, .question_equal, .identifier,
    });
}

test "invalid tokens" {
    const src =
        \\ something!
        \\ something?
    ;

    try helper(src, &[_]Token.Tag{
        .identifier, .invalid,
        .identifier, .invalid,
    });
}

test "identifier can start from number" {
    const src = "8_something";
    try helper(src, &[_]Token.Tag{.identifier});
}

test "UTF-8 BOM" {
    const src = UTF8_BOM_SEQUENCE ++ "key = value";
    try helper(src, &.{
        .identifier, .equal, .identifier,
    });
}

test "skipping BOM does not break token.getValue" {
    const src = UTF8_BOM_SEQUENCE ++ "key";

    var lexer = try Lexer.init(src);
    const token = lexer.next().?;
    const value = token.getValue(src);

    try std.testing.expectEqual(3, token.start); // BOM - 3 bytes offset
    try std.testing.expectEqual(6, token.end);
    try std.testing.expectEqualStrings("key", value);
}

test "UTF-8 works" {
    const src = UTF8_BOM_SEQUENCE ++ "flag:Linnéa José";
    var lexer = try Lexer.init(src);

    _ = lexer.next().?; // flag
    _ = lexer.next().?; // :

    const linnea = lexer.next().?;
    try std.testing.expectEqual(Token.Tag.identifier, linnea.tag);
    try std.testing.expectEqualStrings("Linnéa", linnea.getValue(src));

    const jose = lexer.next().?;
    try std.testing.expectEqual(Token.Tag.identifier, jose.tag);
    try std.testing.expectEqualStrings("José", jose.getValue(src));

    try std.testing.expectEqual(Token.Tag.eof, lexer.next().?.tag);
}

test "UTF-8 strings" {
    const src = UTF8_BOM_SEQUENCE ++ "flag = \"Linnéa José\"";
    var lexer = try Lexer.init(src);

    _ = lexer.next().?; // flag
    _ = lexer.next().?; // :

    const t = lexer.next().?;
    try std.testing.expectEqual(Token.Tag.literal_string, t.tag);
    try std.testing.expectEqualStrings("\"Linnéa José\"", t.getValue(src));

    try std.testing.expectEqual(Token.Tag.eof, lexer.next().?.tag);
}

test "skip comments" {
    const src =
        \\ 42 # something
        \\ 27
    ;

    try helper(src, &[_]Token.Tag{ .literal_number, .literal_number });
}
