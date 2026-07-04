const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const Type = value.Type;

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
    print,

    pub const Load = struct {
        name: []const u8,
        /// static type of the variable being loaded
        type: Type,
    };

    pub const Store = struct {
        name: []const u8,
        /// resolved type: the declared annotation, or the inferred
        /// expression type. The VM coerces the stored value to it
        /// (range-checked when narrowing).
        type: Type,
    };

    /// `{f}` formatter, e.g. `i64.const 5`, `i32.add`, `i8.store x`
    pub fn format(self: Instruction, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .push_const => |v| {
                try writer.print("{s}.const ", .{@tagName(v.getType())});
                try v.write(writer);
            },
            .load => |l| try writer.print("{s}.load {s}", .{ @tagName(l.type), l.name }),
            .store => |s| try writer.print("{s}.store {s}", .{ @tagName(s.type), s.name }),
            .print => try writer.writeAll("print"),
            inline .add, .sub, .mul, .div, .pow => |t, op| try writer.print("{s}.{s}", .{ @tagName(t), @tagName(op) }),
        }
    }
};
