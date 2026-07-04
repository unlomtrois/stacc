const std = @import("std");

const Lexer = @import("../lexer/lexer.zig").Lexer;
const Token = @import("../lexer/token.zig").Token;
const shunting_yard = @import("../parser/shunting_yard.zig");
const getPrecedence = shunting_yard.getPrecedence;
const isLeftAssoc = shunting_yard.isLeftAssoc;

const value_mod = @import("value.zig");
const Value = value_mod.Value;
const instruction_mod = @import("instruction.zig");
const Instruction = instruction_mod.Instruction;
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
    /// compile-time symbol table: variable name -> slot index + static type.
    /// Names never reach the VM; compiled code addresses flat slots.
    var_types: std.StringHashMapUnmanaged(VarInfo) = .empty,
    next_slot: u32 = 0,
    /// print type-checking steps to stderr while compiling
    trace: bool = false,

    const VarInfo = struct {
        slot: u32,
        type: value_mod.Type,
    };

    /// The statement <-> block recursion (if/while bodies contain
    /// statements) needs an explicit error set; Zig cannot infer one
    /// across a recursive cycle.
    const Error = error{
        OutOfMemory,
        Overflow,
        InvalidCharacter,
        UnexpectedToken,
        UnexpectedEof,
        UndefinedVariable,
        UnknownType,
        TypeMismatch,
        InvalidExpression,
        ExpectedExpression,
        UnmatchedParenthesis,
        UnsupportedOperator,
    };

    fn compileProgram(self: *Compiler) Error!void {
        while (true) {
            const token = self.next();
            if (token.tag == .eof) return;
            try self.compileStatement(token);
        }
    }

    /// Statements between `{` (already consumed) and the matching `}`.
    fn compileBlock(self: *Compiler) Error!void {
        while (true) {
            const token = self.next();
            switch (token.tag) {
                .r_brace => return,
                .eof => return error.UnexpectedEof,
                else => try self.compileStatement(token),
            }
        }
    }

    fn compileStatement(self: *Compiler, token: Token) Error!void {
        switch (token.tag) {
            .keyword_let => try self.compileLet(),
            .keyword_if => try self.compileIf(),
            .keyword_while => try self.compileWhile(),
            .identifier => {
                const name = token.getValue(self.src);
                if (std.mem.eql(u8, name, "print")) {
                    try self.compilePrint();
                } else {
                    try self.compileAssign(name);
                }
            },
            else => return error.UnexpectedToken,
        }
    }

    /// if ( cond ) { ... } [ else { ... } | else if ... ]
    ///
    /// Single-pass backpatching, no AST:
    ///   <cond>  jump_if_false ELSE  <then>  [jump END]  ELSE: [<else>]  END:
    fn compileIf(self: *Compiler) Error!void {
        try self.compileCondition();
        const jif = self.instructions.items.len;
        try self.emit(.{ .jump_if_false = instruction_mod.unresolved });

        _ = try self.expect(.l_brace);
        try self.compileBlock();

        const after = self.next();
        if (after.tag == .keyword_else) {
            const jmp = self.instructions.items.len;
            try self.emit(.{ .jump = instruction_mod.unresolved });
            self.patch(jif, self.instructions.items.len);

            const branch = self.next();
            switch (branch.tag) {
                .l_brace => try self.compileBlock(),
                .keyword_if => try self.compileIf(), // else if chain
                else => return error.UnexpectedToken,
            }
            self.patch(jmp, self.instructions.items.len);
        } else {
            self.peeked = after; // not ours; push it back
            self.patch(jif, self.instructions.items.len);
        }
    }

    /// while ( cond ) { ... }
    ///
    ///   START: <cond>  jump_if_false END  <body>  jump START  END:
    fn compileWhile(self: *Compiler) Error!void {
        const loop_start = self.instructions.items.len;
        try self.compileCondition();
        const jif = self.instructions.items.len;
        try self.emit(.{ .jump_if_false = instruction_mod.unresolved });

        _ = try self.expect(.l_brace);
        try self.compileBlock();

        try self.emit(.{ .jump = loop_start });
        self.patch(jif, self.instructions.items.len);
    }

    /// ( expr ) — the condition must be statically bool.
    fn compileCondition(self: *Compiler) Error!void {
        _ = try self.expect(.l_paren);
        const cond_type = try self.compileExpression(.r_paren);
        if (cond_type != .bool) return error.TypeMismatch;
    }

    /// name = expr ;  — assignment to an already-declared variable.
    /// The variable keeps its declared type; the expression must be
    /// statically coercible to it.
    fn compileAssign(self: *Compiler, name: []const u8) Error!void {
        const info = self.var_types.get(name) orelse return error.UndefinedVariable;
        _ = try self.expect(.equal);
        const expr_type = try self.compileExpression(.semicolon);
        if (!value_mod.canCoerce(expr_type, info.type)) return error.TypeMismatch;
        try self.emit(.{ .store = .{ .name = name, .slot = info.slot, .type = info.type } });
        self.traceStore(name, info.type, expr_type, "assigned");
    }

    /// Resolve a placeholder jump target to `target`.
    fn patch(self: *Compiler, index: usize, target: usize) void {
        switch (self.instructions.items[index]) {
            .jump, .jump_if_false => |*t| t.* = target,
            else => unreachable,
        }
        if (self.trace) {
            std.debug.print("  (patch @{d} -> {d})\n", .{ index, target });
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
            if (!value_mod.canCoerce(expr_type, t)) return error.TypeMismatch;
        }
        const var_type = declared_type orelse expr_type;
        // redeclaration reuses the slot and just updates the static type
        const gop = try self.var_types.getOrPut(self.allocator, name);
        if (!gop.found_existing) {
            gop.value_ptr.slot = self.next_slot;
            self.next_slot += 1;
        }
        gop.value_ptr.type = var_type;
        try self.emit(.{ .store = .{ .name = name, .slot = gop.value_ptr.slot, .type = var_type } });
        if (declared_type != null) {
            self.traceStore(name, var_type, expr_type, "declared");
        } else if (self.trace) {
            std.debug.print("  => {s}: {s} (inferred)\n", .{ name, @tagName(expr_type) });
        }
    }

    /// Trace verdict for a store into a variable of known type.
    fn traceStore(self: *Compiler, name: []const u8, var_type: value_mod.Type, expr_type: value_mod.Type, comptime origin: []const u8) void {
        if (!self.trace) return;
        if (var_type == expr_type) {
            std.debug.print("  => {s}: {s} (" ++ origin ++ ", expression matches)\n", .{ name, @tagName(var_type) });
        } else if (value_mod.unify(expr_type, var_type) == var_type) {
            std.debug.print("  => {s}: {s} (" ++ origin ++ ", {s} expression widened)\n", .{ name, @tagName(var_type), @tagName(expr_type) });
        } else {
            std.debug.print("  => {s}: {s} (" ++ origin ++ ", {s} expression narrowed at runtime, range-checked)\n", .{ name, @tagName(var_type), @tagName(expr_type) });
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
                    const info = self.var_types.get(name) orelse return error.UndefinedVariable;
                    try self.type_stack.append(self.allocator, info.type);
                    try self.emit(.{ .load = .{ .name = name, .slot = info.slot, .type = info.type } });
                    emitted_anything = true;
                },
                .plus,
                .minus,
                .multiply,
                .divide,
                .caret,
                .equal_equal,
                .not_equal,
                .less_than,
                .greater_than,
                .less_equal,
                .greater_equal,
                => {
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
        // statically mirror the VM's binary op: pop two operand types,
        // push the result type
        const rhs = self.type_stack.pop() orelse return error.InvalidExpression;
        const lhs = self.type_stack.pop() orelse return error.InvalidExpression;
        // no arithmetic or ordering on bools (rules out chained comparisons
        // like `1 < 2 < 3` as well)
        if (lhs == .bool or rhs == .bool) return error.TypeMismatch;
        const t = value_mod.unify(lhs, rhs);

        const inst: Instruction = switch (tag) {
            .plus => .{ .add = t },
            .minus => .{ .sub = t },
            .multiply => .{ .mul = t },
            .divide => .{ .div = t },
            .caret => .{ .pow = t },
            .equal_equal => .{ .eq = t },
            .not_equal => .{ .ne = t },
            .less_than => .{ .lt = t },
            .greater_than => .{ .gt = t },
            .less_equal => .{ .le = t },
            .greater_equal => .{ .ge = t },
            else => return error.UnsupportedOperator,
        };
        const result_type: value_mod.Type = switch (tag) {
            .equal_equal, .not_equal, .less_than, .greater_than, .less_equal, .greater_equal => .bool,
            else => t,
        };
        try self.type_stack.append(self.allocator, result_type);
        try self.emit(inst);
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
    try std.testing.expectEqual(Instruction{ .mul = .i64 }, program[3]);
    try std.testing.expectEqual(Instruction{ .add = .i64 }, program[4]);
    try std.testing.expectEqualStrings("x", program[5].store.name);
    try std.testing.expectEqual(value_mod.Type.i64, program[5].store.type); // inferred
}

test "compile typed let carries declared type" {
    const allocator = std.testing.allocator;
    const program = try compile(allocator, "let x:i8 = 5;");
    defer allocator.free(program);

    try std.testing.expectEqual(value_mod.Type.i8, program[1].store.type);
}

test "operators are typed by unification" {
    const allocator = std.testing.allocator;
    const program = try compile(allocator, "let x:i8 = 1; let y = x + 0.5;");
    defer allocator.free(program);

    try std.testing.expectEqual(Instruction{ .add = .f64 }, program[4]);
    try std.testing.expectEqual(value_mod.Type.i8, program[2].load.type);
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

// ── control flow ───────────────────────────────────────────────────

test "if executes the taken branch only" {
    try interpretCapture("if (1 < 2) { print(1); }", "1\n");
    try interpretCapture("if (2 < 1) { print(1); }", "");
    try interpretCapture("if (1 < 2) { print(1); } else { print(2); }", "1\n");
    try interpretCapture("if (2 < 1) { print(1); } else { print(2); }", "2\n");
}

test "else if chain" {
    const src =
        \\let score = 42;
        \\if (score > 50) { print(1); }
        \\else if (score > 40) { print(2); }
        \\else { print(3); }
    ;
    try interpretCapture(src, "2\n");
}

test "if/else bytecode shape and jump targets" {
    const allocator = std.testing.allocator;
    const program = try compile(allocator, "if (1 < 2) { print(3); } else { print(4); } print(5);");
    defer allocator.free(program);

    // 0..2 cond, 3 jif -> else, 4..5 then, 6 jump -> end, 7..8 else, 9.. after
    try std.testing.expectEqual(Instruction{ .lt = .i64 }, program[2]);
    try std.testing.expectEqual(Instruction{ .jump_if_false = 7 }, program[3]);
    try std.testing.expectEqual(Instruction{ .jump = 9 }, program[6]);
}

test "while counts up" {
    const src =
        \\let i = 0;
        \\while (i < 3) {
        \\    print(i);
        \\    i = i + 1;
        \\}
        \\print(100);
    ;
    try interpretCapture(src, "0\n1\n2\n100\n");
}

test "while bytecode shape: back-edge and exit target" {
    const allocator = std.testing.allocator;
    const program = try compile(allocator, "let i = 0; while (i < 2) { i = i + 1; }");
    defer allocator.free(program);

    // 0..1 let, 2..4 cond, 5 jif -> 11 (exit), 6..9 body, 10 jump -> 2 (cond)
    try std.testing.expectEqual(Instruction{ .jump_if_false = 11 }, program[5]);
    try std.testing.expectEqual(Instruction{ .jump = 2 }, program[10]);
    try std.testing.expectEqual(@as(usize, 11), program.len);
}

test "while that never runs" {
    try interpretCapture("while (1 > 2) { print(1); } print(2);", "2\n");
}

test "nested control flow" {
    const src =
        \\let i = 0;
        \\while (i < 4) {
        \\    if (i == 2) { print(i); } else { print(0 - i); }
        \\    i = i + 1;
        \\}
    ;
    try interpretCapture(src, "0\n-1\n2\n-3\n");
}

test "fibonacci" {
    const src =
        \\let n = 10;
        \\let a = 0;
        \\let b = 1;
        \\let i = 0;
        \\while (i < n) {
        \\    let t = a + b;
        \\    a = b;
        \\    b = t;
        \\    i = i + 1;
        \\}
        \\print(a);
    ;
    try interpretCapture(src, "55\n");
}

// ── booleans and comparisons ───────────────────────────────────────

test "print comparison result" {
    try interpretCapture("print(1 < 2);", "true\n");
    try interpretCapture("print(1 == 2);", "false\n");
    try interpretCapture("print(1.5 >= 1.5);", "true\n");
    try interpretCapture("print(1 != 2);", "true\n");
}

test "comparison unifies operand types" {
    const allocator = std.testing.allocator;
    const program = try compile(allocator, "let b = 1:i8 < 2.5;");
    defer allocator.free(program);

    try std.testing.expectEqual(Instruction{ .lt = .f64 }, program[2]);
    try std.testing.expectEqual(value_mod.Type.bool, program[3].store.type);
}

test "bool variables and annotation" {
    try interpretCapture("let b:bool = 1 < 2; if (b) { print(1); }", "1\n");
    try interpretCapture("let b = 2 < 1; if (b) { print(1); } else { print(2); }", "2\n");
}

test "comparisons have lower precedence than arithmetic" {
    try interpretCapture("print(1 + 2 < 4);", "true\n");
    try interpretCapture("print(2 * 3 == 6);", "true\n");
}

// ── assignment ─────────────────────────────────────────────────────

test "assignment keeps the declared type" {
    // i8 variable assigned an i64 expression: coerced (checked) at runtime
    try interpretCapture("let x:i8 = 0; x = 100 + 1; print(x);", "101\n");
}

test "assignment narrows at runtime: overflow" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try std.testing.expectError(error.Overflow, interpret(allocator, "let x:i8 = 0; x = 300;", &aw.writer));
}

test "static error: assignment to undeclared variable" {
    try std.testing.expectError(error.UndefinedVariable, compile(std.testing.allocator, "x = 5;"));
}

test "static error: float assigned to int variable" {
    try std.testing.expectError(error.TypeMismatch, compile(std.testing.allocator, "let x = 1; x = 1.5;"));
}

// ── static control-flow errors ─────────────────────────────────────

test "static error: non-bool condition" {
    try std.testing.expectError(error.TypeMismatch, compile(std.testing.allocator, "if (1) { }"));
    try std.testing.expectError(error.TypeMismatch, compile(std.testing.allocator, "while (1 + 1) { }"));
    try std.testing.expectError(error.TypeMismatch, compile(std.testing.allocator, "let x = 1; if (x) { }"));
}

test "static error: arithmetic on bool" {
    try std.testing.expectError(error.TypeMismatch, compile(std.testing.allocator, "let x = (1 < 2) + 1;"));
}

test "static error: chained comparison" {
    try std.testing.expectError(error.TypeMismatch, compile(std.testing.allocator, "let x = 1 < 2 < 3;"));
}

test "static error: bool into numeric annotation and vice versa" {
    try std.testing.expectError(error.TypeMismatch, compile(std.testing.allocator, "let x:i64 = 1 < 2;"));
    try std.testing.expectError(error.TypeMismatch, compile(std.testing.allocator, "let b:bool = 1;"));
}

test "static error: malformed control flow" {
    // missing braces
    try std.testing.expectError(error.UnexpectedToken, compile(std.testing.allocator, "if (1 < 2) print(1);"));
    // missing parens
    try std.testing.expectError(error.UnexpectedToken, compile(std.testing.allocator, "while 1 < 2 { }"));
    // unclosed block
    try std.testing.expectError(error.UnexpectedEof, compile(std.testing.allocator, "if (1 < 2) { print(1);"));
    // stray else
    try std.testing.expectError(error.UnexpectedToken, compile(std.testing.allocator, "else { }"));
    // else without a branch
    try std.testing.expectError(error.UnexpectedToken, compile(std.testing.allocator, "if (1 < 2) { } else print(1);"));
}

test "runtime error: overflow on typed let" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try std.testing.expectError(error.Overflow, interpret(allocator, "let x:i8 = 300;", &aw.writer));
}
