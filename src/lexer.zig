const std = @import("std");
const Utf8View = std.unicode.Utf8View;
const Utf8Iterator = std.unicode.Utf8Iterator;

const Token = @import("token.zig").Token;

const keywords = std.StaticStringMap(Token.Tag).initComptime(.{
    // Boolean literals (special values, not identifiers)
    .{ "yes", .literal_boolean },
    .{ "no", .literal_boolean },
});

const UTF8_BOM_SEQUENCE = "\xEF\xBB\xBF";

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
            ':' => .colon,
            '@' => .at,
            '|' => .pipe,
            '$' => .dollar,

            // special
            '%' => .percent,

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

        // can be simded?
        const is_potential_keyword: bool = switch (self.src[start]) {
            'y', 'n' => blk: {
                const len = end - start;
                if (len > 3) break :blk false;
                break :blk true;
            },
            else => false,
        };

        if (is_potential_keyword) {
            const content = self.src[start..end];
            if (keywords.get(content)) |tag| {
                return tag;
            }
        }

        return .identifier;
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

    inline fn isIdentifierScalar(c: u21) bool {
        if (c == 0) return false;
        if (c <= 0x7f) {
            const ascii: u8 = @intCast(c);
            if (std.ascii.isAlphanumeric(ascii)) return true;
            return switch (ascii) {
                '_', '&', '\'' => true,
                else => false,
            };
        }
        // Allow all non-ASCII scalars for identifiers.
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

fn testTokenize(src: []const u8, expected: []const Token.Tag) !void {
    var lexer = try Lexer.init(src);

    for (expected) |expected_tag| {
        const token = lexer.next() orelse {
            return error.UnexpectedEOF;
        };
        try std.testing.expectEqual(expected_tag, token.tag);
    }

    try std.testing.expectEqual(Token.Tag.eof, lexer.next().?.tag);
}

test "identifier" {
    const src = "key1";

    var lex = try Lexer.init(src);
    const token = lex.next().?;

    try std.testing.expectEqualStrings("key1", token.getValue(src));
    try std.testing.expectEqual(Token.Tag.identifier, token.tag);
}

test "key = value" {
    const src = "key = value";

    try testTokenize(src, &[_]Token.Tag{ .identifier, .equal, .identifier });
}

test "numbers" {
    const src = "key = 108";

    try testTokenize(src, &[_]Token.Tag{ .identifier, .equal, .literal_number });
}

test "strings" {
    const src =
        \\ "test string"
    ;

    try testTokenize(src, &.{
        .literal_string,
    });
}

test "strings - not terminated" {
    const src =
        \\ "not terminated string
    ;

    try testTokenize(src, &.{
        .invalid,
    });
}

test "booleans" {
    const src =
        \\is_yes = yes
        \\is_no = no
    ;

    try testTokenize(src, &[_]Token.Tag{
        .identifier,
        .equal,
        .literal_boolean,
        .identifier,
        .equal,
        .literal_boolean,
    });
}

test "blocks" {
    const src =
        \\ limit = {
        \\     age > 18
        \\ }
    ;

    try testTokenize(src, &[_]Token.Tag{
        .identifier,
        .equal,
        .l_brace,
        .identifier,
        .greater_than,
        .literal_number,
        .r_brace,
    });
}

test "scope operators" {
    const src =
        \\ key1 = title:k_france.capital
        \\ key2 = @some_var
    ;

    try testTokenize(src, &[_]Token.Tag{
        // key1 = title:k_france.capital
        .identifier,
        .equal,
        .identifier,
        .colon,
        .identifier,
        .dot,
        .identifier,

        // key2 = @some_var
        .identifier,
        .equal,
        .at,
        .identifier,
    });
}

test "greater less equal operators" {
    const src =
        \\ age > 18
        \\ age < 18
        \\ age >= 18
        \\ age <= 18
    ;

    try testTokenize(src, &[_]Token.Tag{
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

    try testTokenize(src, &[_]Token.Tag{
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

    try testTokenize(src, &[_]Token.Tag{
        .identifier, .invalid,
        .identifier, .invalid,
    });
}

test "identifier can start from number" {
    const src = "8_something";

    try testTokenize(src, &[_]Token.Tag{.identifier});
}

test "UTF-8 BOM" {
    const src = UTF8_BOM_SEQUENCE ++ "key = value";

    try testTokenize(src, &.{
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
        \\ key = value # something commented
        \\ key = value
    ;

    try testTokenize(src, &[_]Token.Tag{ .identifier, .equal, .identifier, .identifier, .equal, .identifier });
}

test "& can be in identifiers" {
    const src = "ghw_region_finland_&_estonia = something";

    try testTokenize(src, &[_]Token.Tag{ .identifier, .equal, .identifier });
}
