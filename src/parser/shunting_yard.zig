const std = @import("std");

const Lexer = @import("../lexer/lexer.zig").Lexer;
const Token = @import("../lexer/token.zig").Token;

pub const Precedence = enum(u8) {
    none = 0,
    assignment = 1, // =
    comparison = 2, // ==, !=, <, >, <=, >=
    term = 3, // +, -
    factor = 4, // *, /
    exponent = 5, // ^
    call = 6, // . (dot), (), []
};

pub fn getPrecedence(tag: Token.Tag) u8 {
    return switch (tag) {
        .equal => @intFromEnum(Precedence.assignment),
        .equal_equal, .not_equal, .question_equal, .greater_than, .greater_equal, .less_than, .less_equal => @intFromEnum(Precedence.comparison),
        .plus, .minus => @intFromEnum(Precedence.term),
        .multiply, .divide => @intFromEnum(Precedence.factor),
        .caret => @intFromEnum(Precedence.exponent),
        .dot => @intFromEnum(Precedence.call),
        else => @intFromEnum(Precedence.none),
    };
}

fn isLeftAssoc(tag: Token.Tag) bool {
    return tag != .caret; // ^ is right-associative, everything else left
    // return tag != .equal; // assignment is right-associative
}

/// Lazy ShuntingYard
pub const ShuntingYard = struct {
    lexer: *Lexer,
    op_stack: std.ArrayList(Token),
    state: State,
    allocator: std.mem.Allocator,

    /// Every point in the algorithm where we would enqueue output becomes a
    /// yield (return).  The state tells `next()` where to resume.
    const State = union(enum) {
        /// Ready to consume the next input token from the lexer.
        read_input,
        /// An operator was read; pop higher-precedence ops, then push it.
        pushing_op: Token,
        /// A ')' was read; pop operators until the matching '('.
        closing_paren,
        /// A ';' was read; drain the stack, then yield the semicolon.
        flushing_statement: Token,
        /// Input exhausted; pop all remaining operators off the stack.
        draining,
        /// Terminal state – iterator is spent.
        done,
    };

    pub fn init(allocator: std.mem.Allocator, lexer: *Lexer) ShuntingYard {
        return .{
            .lexer = lexer,
            .op_stack = std.ArrayList(Token).empty,
            .state = .read_input,
            .allocator = allocator,
        };
    }

    pub fn next(self: *ShuntingYard) !?Token {
        while (true) {
            switch (self.state) {
                // ── Ready for the next input token ──────────────
                .read_input => {
                    if (self.lexer.next()) |token| {
                        switch (token.tag) {
                            // Operands pass straight through.
                            .literal_number, .identifier => return token,

                            // Operators enter the precedence-popping state.
                            .plus,
                            .minus,
                            .multiply,
                            .divide,
                            .equal,
                            .equal_equal,
                            .not_equal,
                            .question_equal,
                            .greater_than,
                            .greater_equal,
                            .less_than,
                            .less_equal,
                            .dot,
                            => self.state = .{ .pushing_op = token },

                            .caret => self.state = .{ .pushing_op = token },

                            // '(' is pushed onto the stack; produces no output.
                            .l_paren => try self.op_stack.append(self.allocator, token),

                            // ')' triggers the paren-unwinding state.
                            .r_paren => self.state = .closing_paren,

                            // ';' drains the stack for this statement.
                            .semicolon => self.state = .{ .flushing_statement = token },

                            .eof => self.state = .draining,

                            // Everything else (keywords, braces, …) passes through.
                            else => return token,
                        }
                    } else {
                        self.state = .draining;
                    }
                },

                // ── Pop higher-precedence ops, then push ours ──
                .pushing_op => |op| {
                    if (self.op_stack.items.len > 0) {
                        const top = self.op_stack.items[self.op_stack.items.len - 1];
                        if (top.tag != .l_paren) {
                            const top_prec = getPrecedence(top.tag);
                            const op_prec = getPrecedence(op.tag);
                            if (top_prec > op_prec or
                                (top_prec == op_prec and isLeftAssoc(op.tag)))
                            {
                                // Yield one operator; stay in pushing_op.
                                return self.op_stack.pop();
                            }
                        }
                    }
                    // Nothing left to pop – push our operator, resume reading.
                    try self.op_stack.append(self.allocator, op);
                    self.state = .read_input;
                },

                // ── Unwind until we find the matching '(' ──────
                .closing_paren => {
                    if (self.op_stack.items.len > 0) {
                        const top = self.op_stack.items[self.op_stack.items.len - 1];
                        if (top.tag == .l_paren) {
                            _ = self.op_stack.pop(); // discard the '('
                            self.state = .read_input;
                            // No output; loop.
                        } else {
                            return self.op_stack.pop();
                        }
                    } else {
                        self.state = .done;
                        return error.UnmatchedParenthesis;
                    }
                },

                // ── Drain the stack for a statement boundary ───
                .flushing_statement => |semicolon| {
                    if (self.op_stack.items.len > 0) {
                        const top = self.op_stack.items[self.op_stack.items.len - 1];
                        if (top.tag == .l_paren) {
                            _ = self.op_stack.pop(); // discard stale '('
                            continue;
                        }
                        return self.op_stack.pop();
                    } else {
                        // Stack drained – yield the ';' so the emitter sees it.
                        self.state = .read_input;
                        return semicolon;
                    }
                },

                // ── Input exhausted, pop remaining operators ───
                .draining => {
                    if (self.op_stack.items.len > 0) {
                        const top = self.op_stack.pop();
                        if (top.?.tag == .l_paren) continue; // discard unmatched '('
                        return top;
                    }
                    self.state = .done;
                    return null;
                },

                .done => return null,
            }
        }
    }
};

/// Verifies that an infix expression is correctly converted to Reverse Polish Notation (RPN).
fn helper(infix_src: []const u8, expected_rpn: []const u8) !void {
    const allocator = std.heap.page_allocator;

    var rpn_lexer = try Lexer.init(expected_rpn);
    var infix_lexer = try Lexer.init(infix_src);
    var yard = ShuntingYard.init(allocator, &infix_lexer);

    while (try yard.next()) |token| {
        const expected_token = rpn_lexer.next() orelse return error.TooManyTokensInOutput;
        try std.testing.expectEqual(expected_token.tag, token.tag);
    }

    // Ensure the expected RPN string is fully consumed
    const final_token = rpn_lexer.next() orelse return error.MissingEofInExpected;
    try std.testing.expectEqual(Token.Tag.eof, final_token.tag);
}

test "shunting yard: basic arithmetic" {
    try helper("2 + 2", "2 2 +");
    try helper("2 ^ 3", "2 3 ^");
}

test "shunting yard: complex expressions" {
    try helper("(1 - 5) ^ 2", "1 5 - 2 ^");
    try helper("3 + 4 * 2 / (1 - 5) ^ 2", "3 4 2 * 1 5 - 2 ^ / +");
}

test "shunting yard: associativity and nesting" {
    try helper("2 ^ 3 ^ 2", "2 3 2 ^ ^"); // Right-associative
    try helper("10 - 2 * (3 + 4) ^ 2", "10 2 3 4 + 2 ^ * -");
    try helper("((1 + 2) * (3 - 4)) ^ 5", "1 2 + 3 4 - * 5 ^");
}
