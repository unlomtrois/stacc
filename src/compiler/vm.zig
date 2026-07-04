const std = @import("std");

const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Type = value_mod.Type;
const Instruction = @import("instruction.zig").Instruction;

pub const Vm = struct {
    allocator: std.mem.Allocator,
    stack: std.ArrayList(Value),
    vars: std.StringHashMapUnmanaged(Value),
    writer: *std.Io.Writer,

    pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer) Vm {
        return .{
            .allocator = allocator,
            .stack = .empty,
            .vars = .empty,
            .writer = writer,
        };
    }

    pub fn deinit(self: *Vm) void {
        self.stack.deinit(self.allocator);
        self.vars.deinit(self.allocator);
    }

    pub fn run(self: *Vm, program: []const Instruction) !void {
        for (program) |inst| {
            switch (inst) {
                .push_const => |v| try self.stack.append(self.allocator, v),
                .load => |l| {
                    const v = self.vars.get(l.name) orelse return error.UndefinedVariable;
                    try self.stack.append(self.allocator, v);
                },
                .store => |s| {
                    const v = try (try self.pop()).coerce(s.type);
                    try self.vars.put(self.allocator, s.name, v);
                },
                inline .add, .sub, .mul, .div, .pow => |t, op| try self.binaryOp(@field(BinOp, @tagName(op)), t),
                .print => {
                    const v = try self.pop();
                    try v.write(self.writer);
                    try self.writer.writeByte('\n');
                },
            }
        }
    }

    fn pop(self: *Vm) !Value {
        return self.stack.pop() orelse error.StackUnderflow;
    }

    const BinOp = enum { add, sub, mul, div, pow };

    /// The result type `t` comes from the typed instruction (e.g. i32.add),
    /// resolved statically by the compiler's type checker.
    fn binaryOp(self: *Vm, comptime op: BinOp, t: Type) !void {
        const rhs = try self.pop();
        const lhs = try self.pop();

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
        .print,
    }, "7\n");
}

test "store and load roundtrip with annotation" {
    try runCapture(&.{
        .{ .push_const = .{ .i64 = 7 } },
        .{ .store = .{ .name = "x", .type = .i8 } },
        .{ .load = .{ .name = "x", .type = .i8 } },
        .{ .push_const = .{ .i64 = 3 } },
        .{ .add = .i64 },
        .{ .store = .{ .name = "y", .type = .i64 } },
        .{ .load = .{ .name = "y", .type = .i64 } },
        .print,
    }, "10\n");
}

test "undefined variable" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var vm = Vm.init(allocator, &aw.writer);
    defer vm.deinit();

    try std.testing.expectError(error.UndefinedVariable, vm.run(&.{.{ .load = .{ .name = "nope", .type = .i64 } }}));
}

test "overflow on typed store" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var vm = Vm.init(allocator, &aw.writer);
    defer vm.deinit();

    try std.testing.expectError(error.Overflow, vm.run(&.{
        .{ .push_const = .{ .i64 = 300 } },
        .{ .store = .{ .name = "x", .type = .i8 } },
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

test "float arithmetic" {
    try runCapture(&.{
        .{ .push_const = .{ .f64 = 1.5 } },
        .{ .push_const = .{ .i64 = 2 } },
        .{ .mul = .f64 },
        .print,
    }, "3\n");
}
