const std = @import("std");

const Lexer = @import("../lexer/lexer.zig").Lexer;
const Token = @import("../lexer/token.zig").Token;
const shunting_yard = @import("../parser/shunting_yard.zig");
const getPrecedence = shunting_yard.getPrecedence;
const isLeftAssoc = shunting_yard.isLeftAssoc;

const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Instruction = @import("instruction.zig").Instruction;
pub const Vm = @import("vm.zig").Vm;

/// Compile source into a flat instruction list. Variable names in the
/// returned instructions are slices into `src`.
pub fn compile(allocator: std.mem.Allocator, src: []const u8) ![]Instruction {
    return compileInner(allocator, src, false);
}

/// Like `compile`, but traces type checking to stderr as it emits.
pub fn compileVerbose(allocator: std.mem.Allocator, src: []const u8) ![]Instruction {
    return compileInner(allocator, src, true);
}

fn compileInner(allocator: std.mem.Allocator, src: []const u8, trace: bool) ![]Instruction {
    var compiler = Compiler{
        .allocator = allocator,
        .src = src,
        .lexer = try Lexer.init(src),
        .instructions = .empty,
        .trace = trace,
    };
    errdefer compiler.instructions.deinit(allocator);
    defer compiler.type_stack.deinit(allocator);
    defer compiler.var_types.deinit(allocator);

    try compiler.compileProgram();
    return compiler.instructions.toOwnedSlice(allocator);
}

/// Compile and immediately execute `src`, printing to `writer`.
pub fn interpret(allocator: std.mem.Allocator, src: []const u8, writer: *std.Io.Writer) !void {
    const program = try compile(allocator, src);
    defer allocator.free(program);

    var vm = Vm.init(allocator, writer);
    defer vm.deinit();
    try vm.run(program);
}

const Compiler = struct {
    allocator: std.mem.Allocator,
    src: []const u8,
    lexer: Lexer,
    instructions: std.ArrayList(Instruction),
    /// one-token pushback buffer, filled by peeking past a literal
    peeked: ?Token = null,
    /// compile-time mirror of the runtime value stack: holds the static
    /// type of every value the compiled code will have pushed so far
    type_stack: std.ArrayList(value_mod.Type) = .empty,
    /// static types of declared variables
    var_types: std.StringHashMapUnmanaged(value_mod.Type) = .empty,
    /// print type-checking steps to stderr while compiling
    trace: bool = false,

    fn compileProgram(self: *Compiler) !void {
        while (true) {
            const token = self.next();
            switch (token.tag) {
                .eof => return,
                .keyword_let => try self.compileLet(),
                .identifier => {
                    if (std.mem.eql(u8, token.getValue(self.src), "print")) {
                        try self.compilePrint();
                    } else {
                        return error.UnexpectedToken;
                    }
                },
                else => return error.UnexpectedToken,
            }
        }
    }

    /// let name (: type)? = expr ;
    fn compileLet(self: *Compiler) !void {
        const name_token = try self.expect(.identifier);
        const name = name_token.getValue(self.src);

        var declared_type: ?value_mod.Type = null;
        var token = self.next();
        if (token.tag == .colon) {
            const type_token = try self.expect(.identifier);
            declared_type = value_mod.type_names.get(type_token.getValue(self.src)) orelse
                return error.UnknownType;
            token = self.next();
        }
        if (token.tag != .equal) return error.UnexpectedToken;

        const expr_type = try self.compileExpression(.semicolon);
        if (declared_type) |t| {
            // static check: float never fits an int annotation; int narrowing
            // stays a runtime range check on the actual value
            if (expr_type == .f64 and t != .f64) return error.TypeMismatch;
        }
        try self.var_types.put(self.allocator, name, declared_type orelse expr_type);
        try self.emit(.{ .store = .{ .name = name, .declared_type = declared_type } });
        if (self.trace) {
            if (declared_type) |t| {
                if (t == expr_type) {
                    std.debug.print("  => {s}: {s} (declared, expression matches)\n", .{ name, @tagName(t) });
                } else if (value_mod.unify(expr_type, t) == t) {
                    std.debug.print("  => {s}: {s} (declared, {s} expression widened)\n", .{ name, @tagName(t), @tagName(expr_type) });
                } else {
                    std.debug.print("  => {s}: {s} (declared, {s} expression narrowed at runtime, range-checked)\n", .{ name, @tagName(t), @tagName(expr_type) });
                }
            } else {
                std.debug.print("  => {s}: {s} (inferred)\n", .{ name, @tagName(expr_type) });
            }
        }
    }

    /// print ( expr ) ;  — the identifier "print" is already consumed
    fn compilePrint(self: *Compiler) !void {
        _ = try self.expect(.l_paren);
        _ = try self.compileExpression(.r_paren);
        _ = try self.expect(.semicolon);
        try self.emit(.print);
    }

    /// Shunting-yard over one expression, emitting instructions in RPN
    /// order and type-checking against the compile-time type stack.
    /// Consumes the terminator: either `;`, or the `)` that closes the
    /// expression when `terminator == .r_paren`. Returns the expression's
    /// static type.
    fn compileExpression(self: *Compiler, terminator: Token.Tag) !value_mod.Type {
        var op_stack = std.ArrayList(Token.Tag).empty;
        defer op_stack.deinit(self.allocator);

        std.debug.assert(self.type_stack.items.len == 0);
        defer self.type_stack.clearRetainingCapacity();

        var emitted_anything = false;

        while (true) {
            const token = self.next();
            switch (token.tag) {
                .literal_number => {
                    const text = token.getValue(self.src);
                    var v: Value = if (std.mem.indexOfScalar(u8, text, '.') != null)
                        .{ .f64 = try std.fmt.parseFloat(f64, text) }
                    else
                        .{ .i64 = try std.fmt.parseInt(i64, text, 10) };

                    // optional literal type annotation: 5:i8
                    const after = self.next();
                    if (after.tag == .colon) {
                        const type_token = try self.expect(.identifier);
                        const t = value_mod.type_names.get(type_token.getValue(self.src)) orelse
                            return error.UnknownType;
                        v = try v.coerce(t);
                    } else {
                        self.peeked = after;
                    }

                    try self.type_stack.append(self.allocator, v.getType());
                    try self.emit(.{ .push_const = v });
                    emitted_anything = true;
                },
                .identifier => {
                    const name = token.getValue(self.src);
                    const t = self.var_types.get(name) orelse return error.UndefinedVariable;
                    try self.type_stack.append(self.allocator, t);
                    try self.emit(.{ .load = name });
                    emitted_anything = true;
                },
                .plus, .minus, .multiply, .divide, .caret => {
                    const prec = getPrecedence(token.tag);
                    while (op_stack.items.len > 0) {
                        const top = op_stack.items[op_stack.items.len - 1];
                        if (top == .l_paren) break;
                        const top_prec = getPrecedence(top);
                        if (top_prec > prec or (top_prec == prec and isLeftAssoc(token.tag))) {
                            try self.emitOperator(op_stack.pop().?);
                        } else break;
                    }
                    try op_stack.append(self.allocator, token.tag);
                },
                .l_paren => try op_stack.append(self.allocator, .l_paren),
                .r_paren => {
                    // pop until the matching '('; if there is none, this ')'
                    // terminates a print(...) expression
                    while (op_stack.items.len > 0) {
                        const top = op_stack.pop().?;
                        if (top == .l_paren) break;
                        try self.emitOperator(top);
                    } else {
                        if (terminator == .r_paren) {
                            if (!emitted_anything) return error.ExpectedExpression;
                            return self.finishExpression();
                        }
                        return error.UnmatchedParenthesis;
                    }
                },
                .semicolon => {
                    if (terminator != .semicolon) return error.UnexpectedToken;
                    while (op_stack.pop()) |top| {
                        if (top == .l_paren) return error.UnmatchedParenthesis;
                        try self.emitOperator(top);
                    }
                    if (!emitted_anything) return error.ExpectedExpression;
                    return self.finishExpression();
                },
                .eof => return error.UnexpectedEof,
                else => return error.UnsupportedOperator,
            }
        }
    }

    /// A well-formed expression leaves exactly one value on the stack.
    fn finishExpression(self: *Compiler) !value_mod.Type {
        if (self.type_stack.items.len != 1) return error.InvalidExpression;
        return self.type_stack.items[0];
    }

    fn emitOperator(self: *Compiler, tag: Token.Tag) !void {
        // statically mirror the VM's binary op: pop two, push unified type
        const rhs = self.type_stack.pop() orelse return error.InvalidExpression;
        const lhs = self.type_stack.pop() orelse return error.InvalidExpression;
        try self.type_stack.append(self.allocator, value_mod.unify(lhs, rhs));

        try self.emit(switch (tag) {
            .plus => .add,
            .minus => .sub,
            .multiply => .mul,
            .divide => .div,
            .caret => .pow,
            else => return error.UnsupportedOperator,
        });
    }

    fn emit(self: *Compiler, inst: Instruction) !void {
        try self.instructions.append(self.allocator, inst);
        if (self.trace) {
            var buf: [128]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{f}", .{inst}) catch buf[0..];
            std.debug.print("  {s:<24} [", .{text});
            for (self.type_stack.items, 0..) |t, i| {
                if (i > 0) std.debug.print(" ", .{});
                std.debug.print("{s}", .{@tagName(t)});
            }
            std.debug.print("]\n", .{});
        }
    }

    fn next(self: *Compiler) Token {
        if (self.peeked) |token| {
            self.peeked = null;
            return token;
        }
        return self.lexer.next() orelse Token{
            .start = self.src.len,
            .end = self.src.len,
            .tag = .eof,
        };
    }

    fn expect(self: *Compiler, tag: Token.Tag) !Token {
        const token = self.next();
        if (token.tag != tag) return error.UnexpectedToken;
        return token;
    }
};

// ── tests ──────────────────────────────────────────────────────────

fn interpretCapture(src: []const u8, expected_output: []const u8) !void {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    try interpret(allocator, src, &aw.writer);
    try std.testing.expectEqualStrings(expected_output, aw.writer.buffered());
}

test "compile let with precedence" {
    const allocator = std.testing.allocator;
    const program = try compile(allocator, "let x = 1 + 2 * 3;");
    defer allocator.free(program);

    try std.testing.expectEqual(@as(usize, 6), program.len);
    try std.testing.expectEqual(Value{ .i64 = 1 }, program[0].push_const);
    try std.testing.expectEqual(Value{ .i64 = 2 }, program[1].push_const);
    try std.testing.expectEqual(Value{ .i64 = 3 }, program[2].push_const);
    try std.testing.expectEqual(Instruction.mul, program[3]);
    try std.testing.expectEqual(Instruction.add, program[4]);
    try std.testing.expectEqualStrings("x", program[5].store.name);
    try std.testing.expectEqual(@as(?value_mod.Type, null), program[5].store.declared_type);
}

test "compile typed let carries declared type" {
    const allocator = std.testing.allocator;
    const program = try compile(allocator, "let x:i8 = 5;");
    defer allocator.free(program);

    try std.testing.expectEqual(value_mod.Type.i8, program[1].store.declared_type.?);
}

test "end to end: target program" {
    try interpretCapture(
        "let x:i8 = 5 + 2; let y = x + 3;  print(y);",
        "10\n",
    );
}

test "end to end: parens and power" {
    try interpretCapture("print((1 - 5) ^ 2);", "16\n");
    try interpretCapture("print(3 + 4 * 2 / (1 - 5) ^ 2);", "3\n"); // integer division truncates
}

test "end to end: floats" {
    try interpretCapture("let z = 1.5 + 2.5; print(z);", "4\n");
}

test "end to end: print inner parens" {
    try interpretCapture("print((2 + 2) * 2);", "8\n");
}

test "typed literals" {
    const allocator = std.testing.allocator;
    const program = try compile(allocator, "let x = 5:i8;");
    defer allocator.free(program);
    try std.testing.expectEqual(Value{ .i8 = 5 }, program[0].push_const);

    try interpretCapture("let x = 5:i8 + 2; print(x);", "7\n");
    try interpretCapture("print(2:f64 / 8);", "0.25\n"); // typed literal forces float division
    try interpretCapture("print((1 + 2:i8) * 3:i32);", "9\n");
}

test "error: annotation only allowed on literals" {
    try std.testing.expectError(error.UnsupportedOperator, compile(std.testing.allocator, "let x = (1 + 2):i8;"));
}

test "error: typed literal out of range" {
    try std.testing.expectError(error.Overflow, compile(std.testing.allocator, "let x = 300:i8;"));
}

test "error: float literal typed as int" {
    try std.testing.expectError(error.TypeMismatch, compile(std.testing.allocator, "let x = 5.5:i32;"));
}

test "error: unknown literal type" {
    try std.testing.expectError(error.UnknownType, compile(std.testing.allocator, "let x = 5:u7;"));
}

test "error: unknown type" {
    try std.testing.expectError(error.UnknownType, compile(std.testing.allocator, "let x:u7 = 5;"));
}

test "error: missing equal" {
    try std.testing.expectError(error.UnexpectedToken, compile(std.testing.allocator, "let x 5;"));
}

test "error: empty expression" {
    try std.testing.expectError(error.ExpectedExpression, compile(std.testing.allocator, "let x = ;"));
}

test "error: missing semicolon" {
    try std.testing.expectError(error.UnexpectedEof, compile(std.testing.allocator, "let x = 5"));
}

test "error: unmatched parenthesis" {
    try std.testing.expectError(error.UnmatchedParenthesis, compile(std.testing.allocator, "let x = (5;"));
}

test "error: bad statement start" {
    try std.testing.expectError(error.UnexpectedToken, compile(std.testing.allocator, "5 + 5;"));
}

test "static error: undefined variable is caught at compile time" {
    try std.testing.expectError(error.UndefinedVariable, compile(std.testing.allocator, "print(nope);"));
    try std.testing.expectError(error.UndefinedVariable, compile(std.testing.allocator, "let x = y + 1;"));
}

test "static error: float expression into int annotation" {
    try std.testing.expectError(error.TypeMismatch, compile(std.testing.allocator, "let x:i32 = 1.5 + 1;"));
    try std.testing.expectError(error.TypeMismatch, compile(std.testing.allocator, "let f = 1.5; let x:i8 = f;"));
}

test "static ok: int expression into float annotation" {
    try interpretCapture("let x:f64 = 1 + 2; print(x);", "3\n");
}

test "static error: expression leaving more than one value" {
    try std.testing.expectError(error.InvalidExpression, compile(std.testing.allocator, "let x = 1 2;"));
}

test "static error: operator missing an operand" {
    try std.testing.expectError(error.InvalidExpression, compile(std.testing.allocator, "let x = 1 +;"));
}

test "static inference tracks variables across statements" {
    // x is i8, so x + 1.5 is f64 and must not fit an i64 annotation
    try std.testing.expectError(error.TypeMismatch, compile(std.testing.allocator, "let x:i8 = 1; let y:i64 = x + 1.5;"));
    // redeclaration updates the static type
    try interpretCapture("let x = 1; let x = 1.5; let y:f64 = x; print(y);", "1.5\n");
}

test "runtime error: overflow on typed let" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try std.testing.expectError(error.Overflow, interpret(allocator, "let x:i8 = 300;", &aw.writer));
}
