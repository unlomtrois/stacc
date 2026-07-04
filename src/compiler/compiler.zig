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
    defer compiler.pending_calls.deinit(allocator);
    defer {
        var it = compiler.fn_table.valueIterator();
        while (it.next()) |info| allocator.free(info.params);
        compiler.fn_table.deinit(allocator);
    }

    // instruction 0 reserves the top-level frame; its size is known
    // only at end of compilation, so backpatch it
    try compiler.emit(.{ .enter = 0 });
    try compiler.compileProgram();
    compiler.instructions.items[0] = .{ .enter = compiler.next_slot };

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
    /// compile-time function table: name -> signature + entry pc
    fn_table: std.StringHashMapUnmanaged(FnInfo) = .empty,
    /// call sites into the function currently being compiled (recursive
    /// calls); their num_slots is backpatched when the body finishes
    pending_calls: std.ArrayList(usize) = .empty,
    /// inside a function body right now?
    in_function: bool = false,
    /// return type of the function being compiled (null = void)
    current_return_type: ?value_mod.Type = null,
    /// nesting depth of { } blocks (fn declarations only allowed at 0)
    block_depth: u32 = 0,
    /// which token ended the last compileExpression (.comma or .r_paren
    /// matter, for argument lists)
    last_terminator: Token.Tag = .eof,

    const VarInfo = struct {
        slot: u32,
        type: value_mod.Type,
    };

    const FnInfo = struct {
        entry: usize,
        /// parameter types in order; owned by the compiler
        params: []value_mod.Type,
        /// null = void function
        return_type: ?value_mod.Type,
        /// full frame size (params + locals); valid once finalized
        num_slots: u32,
        /// false while the body is still being compiled
        finalized: bool,
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
        UndefinedFunction,
        ArgumentCountMismatch,
        DuplicateDefinition,
        ReturnOutsideFunction,
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
        self.block_depth += 1;
        defer self.block_depth -= 1;
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
            .keyword_fn => try self.compileFn(),
            .keyword_return => try self.compileReturn(),
            .identifier => {
                const name = token.getValue(self.src);
                const after = self.next();
                if (after.tag == .l_paren) {
                    if (std.mem.eql(u8, name, "print")) {
                        try self.compilePrint();
                    } else {
                        // call statement; a leftover return value is dropped
                        const return_type = try self.compileCall(name);
                        _ = try self.expect(.semicolon);
                        if (return_type != null) {
                            _ = self.type_stack.pop();
                            try self.emit(.pop);
                        }
                    }
                } else {
                    self.peeked = after;
                    try self.compileAssign(name);
                }
            },
            else => return error.UnexpectedToken,
        }
    }

    /// fn name(param:type, ...) [:type] { ... }
    ///
    /// The body is compiled inline where it appears; top-level control
    /// flow jumps over it. The signature is registered before the body so
    /// recursive calls resolve; only the frame size of those calls needs
    /// backpatching afterwards.
    fn compileFn(self: *Compiler) Error!void {
        if (self.in_function or self.block_depth > 0) return error.UnexpectedToken;

        const name_token = try self.expect(.identifier);
        const name = name_token.getValue(self.src);
        if (self.fn_table.contains(name)) return error.DuplicateDefinition;
        _ = try self.expect(.l_paren);

        // fresh frame scope: params take slots 0..n-1
        const saved_vars = self.var_types;
        const saved_next_slot = self.next_slot;
        self.var_types = .empty;
        self.next_slot = 0;
        var restored = false;
        errdefer if (!restored) {
            self.var_types.deinit(self.allocator);
            self.var_types = saved_vars;
            self.next_slot = saved_next_slot;
        };

        var params: std.ArrayList(value_mod.Type) = .empty;
        errdefer params.deinit(self.allocator);

        var token = self.next();
        if (token.tag != .r_paren) {
            self.peeked = token;
            while (true) {
                const param_name_token = try self.expect(.identifier);
                const param_name = param_name_token.getValue(self.src);
                _ = try self.expect(.colon);
                const type_token = try self.expect(.identifier);
                const param_type = value_mod.type_names.get(type_token.getValue(self.src)) orelse
                    return error.UnknownType;

                const gop = try self.var_types.getOrPut(self.allocator, param_name);
                if (gop.found_existing) return error.DuplicateDefinition;
                gop.value_ptr.* = .{ .slot = self.next_slot, .type = param_type };
                self.next_slot += 1;
                try params.append(self.allocator, param_type);

                const sep = self.next();
                if (sep.tag == .r_paren) break;
                if (sep.tag != .comma) return error.UnexpectedToken;
            }
        }

        var return_type: ?value_mod.Type = null;
        token = self.next();
        if (token.tag == .colon) {
            const type_token = try self.expect(.identifier);
            return_type = value_mod.type_names.get(type_token.getValue(self.src)) orelse
                return error.UnknownType;
            token = self.next();
        }
        if (token.tag != .l_brace) return error.UnexpectedToken;

        // top-level execution jumps over the body
        const skip = self.instructions.items.len;
        try self.emit(.{ .jump = instruction_mod.unresolved });

        const entry = self.instructions.items.len;
        try self.fn_table.put(self.allocator, name, .{
            .entry = entry,
            .params = try params.toOwnedSlice(self.allocator),
            .return_type = return_type,
            .num_slots = 0,
            .finalized = false,
        });
        if (self.trace) {
            std.debug.print("── fn {s} @{d} ──\n", .{ name, entry });
        }

        self.in_function = true;
        self.current_return_type = return_type;
        defer self.in_function = false;
        try self.compileBlock();

        // implicit end of body: void functions return, value-returning
        // ones trap (all successful paths must have hit a return)
        if (return_type == null) {
            try self.emit(.ret);
        } else {
            try self.emit(.trap);
        }

        // finalize the frame size; patch recursive call sites
        const info = self.fn_table.getPtr(name).?;
        info.num_slots = self.next_slot;
        info.finalized = true;
        for (self.pending_calls.items) |index| {
            self.instructions.items[index].call.num_slots = info.num_slots;
            if (self.trace) {
                std.debug.print("  (patch call @{d} slots -> {d})\n", .{ index, info.num_slots });
            }
        }
        self.pending_calls.clearRetainingCapacity();

        // restore the top-level scope
        self.var_types.deinit(self.allocator);
        self.var_types = saved_vars;
        self.next_slot = saved_next_slot;
        restored = true;

        self.patch(skip, self.instructions.items.len);
    }

    /// return ;  or  return expr ;
    fn compileReturn(self: *Compiler) Error!void {
        if (!self.in_function) return error.ReturnOutsideFunction;

        const token = self.next();
        if (token.tag == .semicolon) {
            if (self.current_return_type != null) return error.TypeMismatch; // must return a value
            try self.emit(.ret);
            return;
        }
        self.peeked = token;

        const return_type = self.current_return_type orelse
            return error.TypeMismatch; // void function returning a value
        const expr_type = try self.compileExpression(.semicolon);
        if (!value_mod.canCoerce(expr_type, return_type)) return error.TypeMismatch;
        if (expr_type != return_type) {
            _ = self.type_stack.pop();
            try self.type_stack.append(self.allocator, return_type);
            try self.emit(.{ .convert = return_type });
        }
        _ = self.type_stack.pop();
        try self.emit(.ret);
    }

    /// name(arg, ...) — the name and `(` are already consumed. Emits the
    /// argument expressions (with per-argument conversion to the param
    /// type) followed by the call. Returns the callee's return type; the
    /// type stack gains it for value-returning callees.
    fn compileCall(self: *Compiler, name: []const u8) Error!?value_mod.Type {
        const info = self.fn_table.getPtr(name) orelse return error.UndefinedFunction;

        var arg_count: usize = 0;
        const first = self.next();
        if (first.tag == .r_paren) {
            // no arguments
        } else {
            self.peeked = first;
            while (true) {
                const arg_type = try self.compileExpression(.comma);
                if (arg_count >= info.params.len) return error.ArgumentCountMismatch;
                const param_type = info.params[arg_count];
                if (!value_mod.canCoerce(arg_type, param_type)) return error.TypeMismatch;
                if (arg_type != param_type) {
                    _ = self.type_stack.pop();
                    try self.type_stack.append(self.allocator, param_type);
                    try self.emit(.{ .convert = param_type });
                }
                arg_count += 1;
                if (self.last_terminator == .r_paren) break;
            }
        }
        if (arg_count != info.params.len) return error.ArgumentCountMismatch;

        // the call consumes the arguments and produces the return value
        self.type_stack.shrinkRetainingCapacity(self.type_stack.items.len - arg_count);
        if (info.return_type) |t| {
            try self.type_stack.append(self.allocator, t);
        }
        const call_index = self.instructions.items.len;
        try self.emit(.{ .call = .{
            .name = name,
            .target = info.entry,
            .num_params = @intCast(info.params.len),
            .num_slots = info.num_slots,
        } });
        if (!info.finalized) {
            try self.pending_calls.append(self.allocator, call_index);
        }
        return info.return_type;
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
        _ = self.type_stack.pop(); // jump_if_false consumes the bool
    }

    /// name = expr ;  — assignment to an already-declared variable.
    /// The variable keeps its declared type; the expression must be
    /// statically coercible to it.
    fn compileAssign(self: *Compiler, name: []const u8) Error!void {
        const info = self.var_types.get(name) orelse return error.UndefinedVariable;
        _ = try self.expect(.equal);
        const expr_type = try self.compileExpression(.semicolon);
        if (!value_mod.canCoerce(expr_type, info.type)) return error.TypeMismatch;
        _ = self.type_stack.pop(); // the store consumes the expression value
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
        _ = self.type_stack.pop(); // the store consumes the expression value
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

    /// print ( expr ) ;  — "print" and `(` are already consumed
    fn compilePrint(self: *Compiler) Error!void {
        _ = try self.compileExpression(.r_paren);
        _ = try self.expect(.semicolon);
        _ = self.type_stack.pop(); // print consumes the expression value
        try self.emit(.print);
    }

    /// Shunting-yard over one expression, emitting instructions in RPN
    /// order and type-checking against the compile-time type stack.
    /// Consumes the terminator: `;`, the `)` that closes the expression
    /// (`terminator == .r_paren`), or — for argument lists
    /// (`terminator == .comma`) — either `,` or the closing `)`, with
    /// `last_terminator` recording which. Returns the expression's static
    /// type; the type stays on the type stack (mirroring the runtime
    /// value), so callers pop it when emitting the consuming instruction.
    ///
    /// Expressions nest (function call arguments), so everything is
    /// relative to the type stack depth at entry.
    fn compileExpression(self: *Compiler, terminator: Token.Tag) Error!value_mod.Type {
        var op_stack = std.ArrayList(Token.Tag).empty;
        defer op_stack.deinit(self.allocator);

        const base = self.type_stack.items.len;

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
                    const after = self.next();
                    if (after.tag == .l_paren) {
                        // function call as an expression operand
                        const return_type = try self.compileCall(name);
                        if (return_type == null) return error.TypeMismatch; // void call has no value
                    } else {
                        self.peeked = after;
                        const info = self.var_types.get(name) orelse return error.UndefinedVariable;
                        try self.type_stack.append(self.allocator, info.type);
                        try self.emit(.{ .load = .{ .name = name, .slot = info.slot, .type = info.type } });
                    }
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
                        if (terminator == .r_paren or terminator == .comma) {
                            if (!emitted_anything) return error.ExpectedExpression;
                            self.last_terminator = .r_paren;
                            return self.finishExpression(base);
                        }
                        return error.UnmatchedParenthesis;
                    }
                },
                .comma => {
                    if (terminator != .comma) return error.UnexpectedToken;
                    while (op_stack.pop()) |top| {
                        // a comma inside grouping parens is not valid
                        if (top == .l_paren) return error.UnexpectedToken;
                        try self.emitOperator(top);
                    }
                    if (!emitted_anything) return error.ExpectedExpression;
                    self.last_terminator = .comma;
                    return self.finishExpression(base);
                },
                .semicolon => {
                    if (terminator != .semicolon) return error.UnexpectedToken;
                    while (op_stack.pop()) |top| {
                        if (top == .l_paren) return error.UnmatchedParenthesis;
                        try self.emitOperator(top);
                    }
                    if (!emitted_anything) return error.ExpectedExpression;
                    self.last_terminator = .semicolon;
                    return self.finishExpression(base);
                },
                .eof => return error.UnexpectedEof,
                else => return error.UnsupportedOperator,
            }
        }
    }

    /// A well-formed expression leaves exactly one new value on the stack.
    fn finishExpression(self: *Compiler, base: usize) Error!value_mod.Type {
        if (self.type_stack.items.len != base + 1) return error.InvalidExpression;
        return self.type_stack.items[base];
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

    // program[0] is the top-level frame allocation
    try std.testing.expectEqual(Instruction{ .enter = 1 }, program[0]);
    try std.testing.expectEqual(@as(usize, 7), program.len);
    try std.testing.expectEqual(Value{ .i64 = 1 }, program[1].push_const);
    try std.testing.expectEqual(Value{ .i64 = 2 }, program[2].push_const);
    try std.testing.expectEqual(Value{ .i64 = 3 }, program[3].push_const);
    try std.testing.expectEqual(Instruction{ .mul = .i64 }, program[4]);
    try std.testing.expectEqual(Instruction{ .add = .i64 }, program[5]);
    try std.testing.expectEqualStrings("x", program[6].store.name);
    try std.testing.expectEqual(value_mod.Type.i64, program[6].store.type); // inferred
}

test "compile typed let carries declared type" {
    const allocator = std.testing.allocator;
    const program = try compile(allocator, "let x:i8 = 5;");
    defer allocator.free(program);

    try std.testing.expectEqual(value_mod.Type.i8, program[2].store.type);
}

test "operators are typed by unification" {
    const allocator = std.testing.allocator;
    const program = try compile(allocator, "let x:i8 = 1; let y = x + 0.5;");
    defer allocator.free(program);

    try std.testing.expectEqual(Instruction{ .add = .f64 }, program[5]);
    try std.testing.expectEqual(value_mod.Type.i8, program[3].load.type);
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
    try std.testing.expectEqual(Value{ .i8 = 5 }, program[1].push_const);

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

    // 0 enter, 1..3 cond, 4 jif -> else, 5..6 then, 7 jump -> end, 8..9 else, 10.. after
    try std.testing.expectEqual(Instruction{ .lt = .i64 }, program[3]);
    try std.testing.expectEqual(Instruction{ .jump_if_false = 8 }, program[4]);
    try std.testing.expectEqual(Instruction{ .jump = 10 }, program[7]);
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

    // 0 enter, 1..2 let, 3..5 cond, 6 jif -> 12 (exit), 7..10 body, 11 jump -> 3 (cond)
    try std.testing.expectEqual(Instruction{ .jump_if_false = 12 }, program[6]);
    try std.testing.expectEqual(Instruction{ .jump = 3 }, program[11]);
    try std.testing.expectEqual(@as(usize, 12), program.len);
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

    try std.testing.expectEqual(Instruction{ .lt = .f64 }, program[3]);
    try std.testing.expectEqual(value_mod.Type.bool, program[4].store.type);
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

// ── functions ──────────────────────────────────────────────────────

test "function call and return" {
    const src =
        \\fn add(a:i64, b:i64):i64 {
        \\    return a + b;
        \\}
        \\print(add(1, 2));
    ;
    try interpretCapture(src, "3\n");
}

test "calls inside expressions and nested call arguments" {
    const src =
        \\fn add(a:i64, b:i64):i64 { return a + b; }
        \\print(add(1, 2) * add(3, 4));
        \\print(add(add(1, 2), add(3, 4)));
        \\print(1 + add(2, 3) * 2);
    ;
    try interpretCapture(src, "21\n10\n11\n");
}

test "argument and return coercion" {
    const src =
        \\fn half(x:f64):f64 { return x / 2; }
        \\fn one():f64 { return 1; }
        \\print(half(7));
        \\print(one());
    ;
    try interpretCapture(src, "3.5\n1\n");
}

test "void function called as statement" {
    const src =
        \\fn shout(x:i64) {
        \\    print(x * 10);
        \\}
        \\shout(4);
    ;
    try interpretCapture(src, "40\n");
}

test "early return from void function" {
    const src =
        \\fn f(x:i64) {
        \\    if (x > 0) {
        \\        return;
        \\    }
        \\    print(x);
        \\}
        \\f(1);
        \\f(0 - 5);
    ;
    try interpretCapture(src, "-5\n");
}

test "value-returning call as statement discards the result" {
    const src =
        \\fn five():i64 { return 5; }
        \\five();
        \\print(1);
    ;
    try interpretCapture(src, "1\n");
}

test "recursion: factorial" {
    const src =
        \\fn fact(n:i64):i64 {
        \\    if (n < 2) {
        \\        return 1;
        \\    }
        \\    return n * fact(n - 1);
        \\}
        \\print(fact(10));
    ;
    try interpretCapture(src, "3628800\n");
}

test "recursion: fibonacci" {
    const src =
        \\fn fib(n:i64):i64 {
        \\    if (n < 2) {
        \\        return n;
        \\    }
        \\    return fib(n - 1) + fib(n - 2);
        \\}
        \\print(fib(10));
    ;
    try interpretCapture(src, "55\n");
}

test "function locals are frame-isolated from globals" {
    const src =
        \\let x = 100;
        \\fn f():i64 {
        \\    let x = 1;
        \\    return x + 1;
        \\}
        \\print(f());
        \\print(x);
    ;
    try interpretCapture(src, "2\n100\n");
}

test "function bodies are jumped over at top level" {
    // the body's print must not run without a call
    try interpretCapture("fn f() { print(1); } print(2);", "2\n");
}

test "static error: undefined function" {
    try std.testing.expectError(error.UndefinedFunction, compile(std.testing.allocator, "f(1);"));
    try std.testing.expectError(error.UndefinedFunction, compile(std.testing.allocator, "let x = f(1);"));
}

test "static error: argument count mismatch" {
    try std.testing.expectError(error.ArgumentCountMismatch, compile(std.testing.allocator, "fn f(a:i64):i64 { return a; } let x = f();"));
    try std.testing.expectError(error.ArgumentCountMismatch, compile(std.testing.allocator, "fn f(a:i64):i64 { return a; } let x = f(1, 2);"));
}

test "static error: argument type mismatch" {
    try std.testing.expectError(error.TypeMismatch, compile(std.testing.allocator, "fn f(a:i64):i64 { return a; } let x = f(1.5);"));
    try std.testing.expectError(error.TypeMismatch, compile(std.testing.allocator, "fn f(a:i64):i64 { return a; } let x = f(1 < 2);"));
}

test "static error: void call in expression" {
    try std.testing.expectError(error.TypeMismatch, compile(std.testing.allocator, "fn g() { } let x = g();"));
}

test "static error: return outside a function" {
    try std.testing.expectError(error.ReturnOutsideFunction, compile(std.testing.allocator, "return 1;"));
}

test "static error: return value from void function" {
    try std.testing.expectError(error.TypeMismatch, compile(std.testing.allocator, "fn g() { return 1; }"));
}

test "static error: bare return in value-returning function" {
    try std.testing.expectError(error.TypeMismatch, compile(std.testing.allocator, "fn f():i64 { return; }"));
}

test "static error: return type mismatch" {
    try std.testing.expectError(error.TypeMismatch, compile(std.testing.allocator, "fn f():i8 { return 1.5; }"));
}

test "static error: nested function declarations" {
    try std.testing.expectError(error.UnexpectedToken, compile(std.testing.allocator, "fn f() { fn g() { } }"));
    try std.testing.expectError(error.UnexpectedToken, compile(std.testing.allocator, "if (1 < 2) { fn g() { } }"));
}

test "static error: duplicate function or parameter" {
    try std.testing.expectError(error.DuplicateDefinition, compile(std.testing.allocator, "fn f() { } fn f() { }"));
    try std.testing.expectError(error.DuplicateDefinition, compile(std.testing.allocator, "fn f(a:i64, a:i64):i64 { return a; }"));
}

test "static error: functions cannot see globals" {
    try std.testing.expectError(error.UndefinedVariable, compile(std.testing.allocator, "let g = 1; fn f():i64 { return g; }"));
}

test "static error: unknown parameter or return type" {
    try std.testing.expectError(error.UnknownType, compile(std.testing.allocator, "fn f(a:u7) { }"));
    try std.testing.expectError(error.UnknownType, compile(std.testing.allocator, "fn f():u7 { return 1; }"));
}

test "runtime error: missing return" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const src = "fn f(x:i64):i64 { if (x > 0) { return 1; } } let y = f(0 - 1);";
    try std.testing.expectError(error.MissingReturn, interpret(allocator, src, &aw.writer));
}

test "runtime error: infinite recursion overflows the call stack" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const src = "fn f():i64 { return f(); } let x = f();";
    try std.testing.expectError(error.StackOverflow, interpret(allocator, src, &aw.writer));
}

test "runtime error: argument narrowing overflow" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const src = "fn f(x:i8):i8 { return x; } print(f(300));";
    try std.testing.expectError(error.Overflow, interpret(allocator, src, &aw.writer));
}

test "runtime error: overflow on typed let" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try std.testing.expectError(error.Overflow, interpret(allocator, "let x:i8 = 300;", &aw.writer));
}
