const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const Type = value.Type;

/// Sentinel jump target used during compilation, before backpatching
/// resolves the real one. Never survives in a successfully compiled program.
pub const unresolved: usize = std.math.maxInt(usize);

/// Every instruction is fully typed at compile time by the type checker.
/// Variable names are slices into the source buffer, which must outlive
/// both compilation and execution.
pub const Instruction = union(enum) {
    push_const: Value,
    load: Load,
    store: Store,
    add: Type,
    sub: Type,
    mul: Type,
    div: Type,
    pow: Type,
    /// comparisons are typed by their operand type and push a bool
    eq: Type,
    ne: Type,
    lt: Type,
    gt: Type,
    le: Type,
    ge: Type,
    /// unconditional jump to an absolute instruction index
    jump: usize,
    /// pop a bool; jump to the absolute index when it is false
    jump_if_false: usize,
    print,

    pub const Load = struct {
        /// original variable name, kept only for disassembly
        name: []const u8,
        /// index into the VM's flat slot array
        slot: u32,
        /// static type of the variable being loaded
        type: Type,
    };

    pub const Store = struct {
        /// original variable name, kept only for disassembly
        name: []const u8,
        /// index into the VM's flat slot array
        slot: u32,
        /// resolved type: the declared annotation, or the inferred
        /// expression type. The VM coerces the stored value to it
        /// (range-checked when narrowing).
        type: Type,
    };

    /// `{f}` formatter, e.g. `i64.const 5`, `i32.add`, `i8.store x@0`
    pub fn format(self: Instruction, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .push_const => |v| {
                try writer.print("{s}.const ", .{@tagName(v.getType())});
                try v.write(writer);
            },
            .load => |l| try writer.print("{s}.load {s}@{d}", .{ @tagName(l.type), l.name, l.slot }),
            .store => |s| try writer.print("{s}.store {s}@{d}", .{ @tagName(s.type), s.name, s.slot }),
            .print => try writer.writeAll("print"),
            inline .jump, .jump_if_false => |target, op| {
                if (target == unresolved) {
                    try writer.print("{s} -> ?", .{@tagName(op)});
                } else {
                    try writer.print("{s} -> {d}", .{ @tagName(op), target });
                }
            },
            inline .add, .sub, .mul, .div, .pow, .eq, .ne, .lt, .gt, .le, .ge => |t, op| try writer.print("{s}.{s}", .{ @tagName(t), @tagName(op) }),
        }
    }
};
