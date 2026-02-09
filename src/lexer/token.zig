const std = @import("std");

pub const Position = struct {
    line: usize,
    column: usize,
};

pub const Token = struct {
    start: usize, // Start position in source
    end: usize, // End position in source
    tag: Tag,

    comptime {
        std.debug.assert(@sizeOf(Token) == 24); // 8 8 8
    }

    pub const Tag = enum(u8) {
        identifier,

        // Literals
        literal_number, // 108
        literal_string, // "something.dds"
        literal_boolean, // true / false

        // Delimiters
        l_brace, // {
        r_brace, // }
        l_bracket, // [
        r_bracket, // ]

        // Arithmetic operators
        plus, // +
        minus, // -
        multiply, // *
        divide, // /

        // Comparison operators
        greater_than, // >
        greater_equal, // >=
        less_than, // <
        less_equal, // <=

        // Assignment operators
        equal, // =

        // Equality operators
        equal_equal, // ==
        not_equal, // !=
        question_equal, // ?=

        // Scope resolution operators
        dot, // .

        semicolon,
        comment, // # Something
        invalid,
        eof,
    };

    pub fn getValue(self: Token, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }

    /// Get the line and column position of this token in the source
    pub fn getPosition(self: Token, source: []const u8) Position {
        var line: usize = 1;
        var column: usize = 1;

        // Iterate through source up to token start position
        for (source[0..self.start]) |char| {
            if (char == '\n') {
                line += 1;
                column = 1;
            } else {
                column += 1;
            }
        }

        return .{ .line = line, .column = column };
    }

    /// Format the token position as "path:line:column"
    pub fn formatPosition(self: Token, allocator: std.mem.Allocator, path: []const u8, source: []const u8) ![]const u8 {
        const pos = self.getPosition(source);
        return std.fmt.allocPrint(allocator, "{s}:{d}:{d}", .{ path, pos.line, pos.column });
    }
};

test "getValue with UTF-8 string" {
    const src = "flag:Linnéa";
    // "flag:" is 5 bytes, "Linnéa" starts at position 5
    // "Linn" = 4 bytes, "é" = 2 bytes (UTF-8), "a" = 1 byte
    // So "Linnéa" spans from position 5 to 12 (5 + 4 + 2 + 1)
    const token = Token{
        .start = 5,
        .end = 12,
        .tag = .identifier,
    };

    const value = token.getValue(src);
    try std.testing.expectEqualStrings("Linnéa", value);
    try std.testing.expectEqual(@as(usize, 7), value.len);
}

test "getValue with UTF-8 string containing multiple multi-byte characters" {
    const src = "name = José";
    // "name = " is 7 bytes, "José" starts at position 7
    // "Jos" = 3 bytes, "é" = 2 bytes (UTF-8)
    // So "José" spans from position 7 to 12 (7 + 3 + 2)
    const token = Token{
        .start = 7,
        .end = 12,
        .tag = .identifier,
    };

    const value = token.getValue(src);
    try std.testing.expectEqualStrings("José", value);
    try std.testing.expectEqual(@as(usize, 5), value.len);
}
