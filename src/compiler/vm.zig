const std = @import("std");

const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Type = value_mod.Type;
const Instruction = @import("instruction.zig").Instruction;

/// A call frame: where to resume, and where the caller's slots begin.
const Frame = struct {
    return_pc: usize,
    slot_base: usize,
};

/// Backstop against runaway recursion.
const max_call_depth = 1024;

pub const Vm = struct {
    allocator: std.mem.Allocator,
    stack: std.ArrayList(Value),
    /// all live frames' variable slots, contiguously; the current frame
    /// starts at `slot_base`
    slots: std.ArrayList(Value),
    frames: std.ArrayList(Frame),
    slot_base: usize,
    writer: *std.Io.Writer,

    pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer) Vm {
        return .{
            .allocator = allocator,
            .stack = .empty,
            .slots = .empty,
            .frames = .empty,
            .slot_base = 0,
            .writer = writer,
        };
    }

    pub fn deinit(self: *Vm) void {
        self.stack.deinit(self.allocator);
        self.slots.deinit(self.allocator);
        self.frames.deinit(self.allocator);
    }

    pub fn run(self: *Vm, program: []const Instruction) !void {
        var pc: usize = 0;
        while (pc < program.len) {
            const inst = program[pc];
            pc += 1;
            switch (inst) {
                .push_const => |v| try self.stack.append(self.allocator, v),
                .load => |l| {
                    try self.stack.append(self.allocator, self.slots.items[self.slot_base + l.slot]);
                    if (l.type == .str) {
                        try self.stack.append(self.allocator, self.slots.items[self.slot_base + l.slot + 1]);
                    }
                },
                .store => |s| {
                    if (s.type == .str) {
                        const len = try self.pop();
                        const ptr = try self.pop();
                        if (len != .i64 or ptr != .ptr) return error.TypeMismatch;
                        self.slots.items[self.slot_base + s.slot] = ptr;
                        self.slots.items[self.slot_base + s.slot + 1] = len;
                    } else {
                        const v = try (try self.pop()).coerce(s.type);
                        self.slots.items[self.slot_base + s.slot] = v;
                    }
                },
                .push_str => |bytes| {
                    try self.stack.append(self.allocator, .{ .ptr = bytes.ptr });
                    try self.stack.append(self.allocator, .{ .i64 = @intCast(bytes.len) });
                },
                .str_len => {
                    const len = try self.pop();
                    const ptr = try self.pop();
                    if (len != .i64 or ptr != .ptr) return error.TypeMismatch;
                    try self.stack.append(self.allocator, len);
                },
                .str_index => {
                    const idx = try self.popInt();
                    const s = try self.popStr();
                    if (idx < 0 or idx >= s.len) return error.OutOfBounds;
                    try self.stack.append(self.allocator, .{ .i64 = s[@intCast(idx)] });
                },
                .str_slice => {
                    const high = try self.popInt();
                    const low = try self.popInt();
                    const s = try self.popStr();
                    if (low < 0 or low > high or high > s.len) return error.OutOfBounds;
                    try self.stack.append(self.allocator, .{ .ptr = s.ptr + @as(usize, @intCast(low)) });
                    try self.stack.append(self.allocator, .{ .i64 = high - low });
                },
                .str_eq, .str_ne => {
                    const rhs = try self.popStr();
                    const lhs = try self.popStr();
                    const equal = std.mem.eql(u8, lhs, rhs);
                    try self.stack.append(self.allocator, .{ .bool = if (inst == .str_eq) equal else !equal });
                },
                .enter => |n| try self.slots.appendNTimes(self.allocator, .{ .i64 = 0 }, n),
                .fn_prologue => {}, // frame setup is done by .call; native codegen uses this
                .call => |c| {
                    if (self.frames.items.len >= max_call_depth) return error.StackOverflow;
                    const new_base = self.slots.items.len;
                    try self.slots.appendNTimes(self.allocator, .{ .i64 = 0 }, c.num_slots);
                    // arguments were pushed left to right; pop them into
                    // the frame's leading slots in reverse
                    var i: u32 = c.num_params;
                    while (i > 0) {
                        i -= 1;
                        self.slots.items[new_base + i] = try self.pop();
                    }
                    try self.frames.append(self.allocator, .{ .return_pc = pc, .slot_base = self.slot_base });
                    self.slot_base = new_base;
                    pc = c.target;
                },
                .ret => {
                    const frame = self.frames.pop() orelse return error.ReturnOutsideFunction;
                    self.slots.shrinkRetainingCapacity(self.slot_base);
                    self.slot_base = frame.slot_base;
                    pc = frame.return_pc;
                },
                .trap => return error.MissingReturn,
                .pop => _ = try self.pop(),
                .convert => |t| {
                    const v = try (try self.pop()).coerce(t);
                    try self.stack.append(self.allocator, v);
                },
                .convert_under => |t| {
                    if (self.stack.items.len < 2) return error.StackUnderflow;
                    const index = self.stack.items.len - 2;
                    self.stack.items[index] = try self.stack.items[index].coerce(t);
                },
                inline .add, .sub, .mul, .div, .pow => |t, op| try self.binaryOp(@field(BinOp, @tagName(op)), t),
                inline .eq, .ne, .lt, .gt, .le, .ge => |t, op| try self.comparisonOp(@field(CmpOp, @tagName(op)), t),
                .jump => |target| pc = target,
                .jump_if_false => |target| {
                    const v = try self.pop();
                    if (v != .bool) return error.TypeMismatch;
                    if (!v.bool) pc = target;
                },
                .print => |t| {
                    if (t == .str) {
                        const s = try self.popStr();
                        try self.writer.writeAll(s);
                        try self.writer.writeByte('\n');
                    } else {
                        const v = try self.pop();
                        try v.write(self.writer);
                        try self.writer.writeByte('\n');
                    }
                },
            }
        }
    }

    fn pop(self: *Vm) !Value {
        return self.stack.pop() orelse error.StackUnderflow;
    }

    fn popInt(self: *Vm) !i64 {
        const v = try self.pop();
        if (v == .ptr or v == .bool or v == .f64) return error.TypeMismatch;
        return v.asI64();
    }

    /// Pop a str's two slots ([ptr][len], len on top).
    fn popStr(self: *Vm) ![]const u8 {
        const len = try self.pop();
        const ptr = try self.pop();
        if (len != .i64 or ptr != .ptr) return error.TypeMismatch;
        return ptr.ptr[0..@intCast(len.i64)];
    }

    const BinOp = enum { add, sub, mul, div, pow };
    const CmpOp = enum { eq, ne, lt, gt, le, ge };

    /// The result type `t` comes from the typed instruction (e.g. i32.add),
    /// resolved statically by the compiler's type checker.
    fn binaryOp(self: *Vm, comptime op: BinOp, t: Type) !void {
        const rhs = try self.pop();
        const lhs = try self.pop();

        // safety net: the static type of a slot can diverge from its
        // runtime value after a conditional redeclaration, so mismatched
        // operands are a runtime error rather than undefined behavior
        if (lhs == .bool or rhs == .bool or lhs == .ptr or rhs == .ptr) return error.TypeMismatch;
        if (t != .f64 and (lhs == .f64 or rhs == .f64)) return error.TypeMismatch;

        const result: Value = if (t == .f64) blk: {
            const a = lhs.asF64();
            const b = rhs.asF64();
            break :blk .{ .f64 = switch (op) {
                .add => a + b,
                .sub => a - b,
                .mul => a * b,
                .div => if (b == 0) return error.DivisionByZero else a / b,
                .pow => std.math.pow(f64, a, b),
            } };
        } else blk: {
            const a = lhs.asI64();
            const b = rhs.asI64();
            const wide: i64 = switch (op) {
                .add => a + b,
                .sub => a - b,
                .mul => a * b,
                .div => if (b == 0) return error.DivisionByZero else @divTrunc(a, b),
                .pow => try std.math.powi(i64, a, b),
            };
            // arithmetic runs in i64; narrow to the instruction's type checked
            break :blk try (Value{ .i64 = wide }).coerce(t);
        };

        try self.stack.append(self.allocator, result);
    }

    /// Comparisons are typed by their operand type and push a bool.
    fn comparisonOp(self: *Vm, comptime op: CmpOp, t: Type) !void {
        const rhs = try self.pop();
        const lhs = try self.pop();

        if (lhs == .bool or rhs == .bool or lhs == .ptr or rhs == .ptr) return error.TypeMismatch;
        if (t != .f64 and (lhs == .f64 or rhs == .f64)) return error.TypeMismatch;

        const result = if (t == .f64) blk: {
            const a = lhs.asF64();
            const b = rhs.asF64();
            break :blk switch (op) {
                .eq => a == b,
                .ne => a != b,
                .lt => a < b,
                .gt => a > b,
                .le => a <= b,
                .ge => a >= b,
            };
        } else blk: {
            const a = lhs.asI64();
            const b = rhs.asI64();
            break :blk switch (op) {
                .eq => a == b,
                .ne => a != b,
                .lt => a < b,
                .gt => a > b,
                .le => a <= b,
                .ge => a >= b,
            };
        };

        try self.stack.append(self.allocator, .{ .bool = result });
    }
};

fn runCapture(program: []const Instruction, expected_output: []const u8) !void {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    var vm = Vm.init(allocator, &aw.writer);
    defer vm.deinit();

    try vm.run(program);
    try std.testing.expectEqualStrings(expected_output, aw.writer.buffered());
}

test "arithmetic and print" {
    try runCapture(&.{
        .{ .push_const = .{ .i64 = 5 } },
        .{ .push_const = .{ .i64 = 2 } },
        .{ .add = .i64 },
        .{ .print = .i64 },
    }, "7\n");
}

test "store and load roundtrip with annotation" {
    try runCapture(&.{
        .{ .enter = 2 },
        .{ .push_const = .{ .i64 = 7 } },
        .{ .store = .{ .name = "x", .slot = 0, .type = .i8 } },
        .{ .load = .{ .name = "x", .slot = 0, .type = .i8 } },
        .{ .push_const = .{ .i64 = 3 } },
        .{ .add = .i64 },
        .{ .store = .{ .name = "y", .slot = 1, .type = .i64 } },
        .{ .load = .{ .name = "y", .slot = 1, .type = .i64 } },
        .{ .print = .i64 },
    }, "10\n");
}

test "overflow on typed store" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var vm = Vm.init(allocator, &aw.writer);
    defer vm.deinit();

    try std.testing.expectError(error.Overflow, vm.run(&.{
        .{ .enter = 1 },
        .{ .push_const = .{ .i64 = 300 } },
        .{ .store = .{ .name = "x", .slot = 0, .type = .i8 } },
    }));
}

test "division by zero" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var vm = Vm.init(allocator, &aw.writer);
    defer vm.deinit();

    try std.testing.expectError(error.DivisionByZero, vm.run(&.{
        .{ .push_const = .{ .i64 = 1 } },
        .{ .push_const = .{ .i64 = 0 } },
        .{ .div = .i64 },
    }));
}

test "comparison pushes bool" {
    try runCapture(&.{
        .{ .push_const = .{ .i64 = 1 } },
        .{ .push_const = .{ .i64 = 2 } },
        .{ .lt = .i64 },
        .{ .print = .bool },
    }, "true\n");
}

test "jump skips instructions" {
    try runCapture(&.{
        .{ .jump = 3 },
        .{ .push_const = .{ .i64 = 1 } }, // skipped
        .{ .print = .i64 }, // skipped
        .{ .push_const = .{ .i64 = 2 } },
        .{ .print = .i64 },
    }, "2\n");
}

test "jump_if_false branches on the popped bool" {
    try runCapture(&.{
        .{ .push_const = .{ .bool = false } },
        .{ .jump_if_false = 4 },
        .{ .push_const = .{ .i64 = 1 } }, // skipped
        .{ .print = .i64 }, // skipped
        .{ .push_const = .{ .i64 = 2 } },
        .{ .print = .i64 },
        .{ .push_const = .{ .bool = true } },
        .{ .jump_if_false = 11 }, // not taken
        .{ .push_const = .{ .i64 = 3 } },
        .{ .print = .i64 },
    }, "2\n3\n");
}

test "jump_if_false rejects non-bool at runtime" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var vm = Vm.init(allocator, &aw.writer);
    defer vm.deinit();

    try std.testing.expectError(error.TypeMismatch, vm.run(&.{
        .{ .push_const = .{ .i64 = 1 } },
        .{ .jump_if_false = 0 },
    }));
}

test "arithmetic rejects mismatched runtime operand types" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var vm = Vm.init(allocator, &aw.writer);
    defer vm.deinit();

    // an i64.add whose operand is really f64 (possible after conditional
    // redeclaration) must error, not hit unreachable
    try std.testing.expectError(error.TypeMismatch, vm.run(&.{
        .{ .push_const = .{ .f64 = 1.5 } },
        .{ .push_const = .{ .i64 = 1 } },
        .{ .add = .i64 },
    }));
}

test "call passes args into frame slots and ret resumes" {
    // fn double(x) { return x + x; }  at pc 1..4; main: call double(21), print
    try runCapture(&.{
        .{ .jump = 5 }, // skip over the body
        .{ .load = .{ .name = "x", .slot = 0, .type = .i64 } }, // 1: body
        .{ .load = .{ .name = "x", .slot = 0, .type = .i64 } },
        .{ .add = .i64 },
        .{ .ret = true },
        .{ .push_const = .{ .i64 = 21 } }, // 5: main
        .{ .call = .{ .name = "double", .target = 1, .num_params = 1, .num_slots = 1, .returns_value = true } },
        .{ .print = .i64 },
    }, "42\n");
}

test "frames isolate slots across calls" {
    // main slot 0 = 7; callee writes its own slot 0; main's is untouched
    try runCapture(&.{
        .{ .enter = 1 },
        .{ .jump = 5 },
        .{ .push_const = .{ .i64 = 99 } }, // 2: body
        .{ .store = .{ .name = "y", .slot = 0, .type = .i64 } },
        .{ .ret = false },
        .{ .push_const = .{ .i64 = 7 } }, // 5: main
        .{ .store = .{ .name = "x", .slot = 0, .type = .i64 } },
        .{ .call = .{ .name = "f", .target = 2, .num_params = 0, .num_slots = 1, .returns_value = false } },
        .{ .load = .{ .name = "x", .slot = 0, .type = .i64 } },
        .{ .print = .i64 },
    }, "7\n");
}

test "trap reports a missing return" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var vm = Vm.init(allocator, &aw.writer);
    defer vm.deinit();

    try std.testing.expectError(error.MissingReturn, vm.run(&.{.trap}));
}

test "pop discards and convert coerces" {
    try runCapture(&.{
        .{ .push_const = .{ .i64 = 1 } },
        .pop,
        .{ .push_const = .{ .i64 = 7 } },
        .{ .convert = .f64 },
        .{ .print = .f64 },
    }, "7\n");
}

test "convert range-checks at runtime" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var vm = Vm.init(allocator, &aw.writer);
    defer vm.deinit();

    try std.testing.expectError(error.Overflow, vm.run(&.{
        .{ .push_const = .{ .i64 = 300 } },
        .{ .convert = .i8 },
    }));
}

test "call depth is bounded" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var vm = Vm.init(allocator, &aw.writer);
    defer vm.deinit();

    // fn f() { f(); }  — infinite recursion
    try std.testing.expectError(error.StackOverflow, vm.run(&.{
        .{ .jump = 3 },
        .{ .call = .{ .name = "f", .target = 1, .num_params = 0, .num_slots = 0, .returns_value = false } }, // 1: body
        .{ .ret = false },
        .{ .call = .{ .name = "f", .target = 1, .num_params = 0, .num_slots = 0, .returns_value = false } }, // 3: main
    }));
}

test "float arithmetic" {
    try runCapture(&.{
        .{ .push_const = .{ .f64 = 1.5 } },
        .{ .push_const = .{ .i64 = 2 } },
        .{ .mul = .f64 },
        .{ .print = .f64 },
    }, "3\n");
}
