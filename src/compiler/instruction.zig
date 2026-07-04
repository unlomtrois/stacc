const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const Type = value.Type;

/// Variable names are slices into the source buffer, which must outlive
/// both compilation and execution.
pub const Instruction = union(enum) {
    push_const: Value,
    load: []const u8,
    store: Store,
    add,
    sub,
    mul,
    div,
    pow,
    print,

    pub const Store = struct {
        name: []const u8,
        /// Type from a `let name:type = ...` annotation; null means infer.
        declared_type: ?Type,
    };

    /// `{f}` formatter, e.g. `push_const 5:i64`, `store x:i8`, `add`
    pub fn format(self: Instruction, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .push_const => |v| try writer.print("push_const {f}", .{v}),
            .load => |name| try writer.print("load {s}", .{name}),
            .store => |s| {
                try writer.print("store {s}", .{s.name});
                if (s.declared_type) |t| try writer.print(":{s}", .{@tagName(t)});
            },
            else => try writer.writeAll(@tagName(self)),
        }
    }
};
