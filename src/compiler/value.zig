const std = @import("std");

pub const Type = enum { i8, i32, i64, f64 };

pub const type_names = std.StaticStringMap(Type).initComptime(.{
    .{ "i8", .i8 },
    .{ "i32", .i32 },
    .{ "i64", .i64 },
    .{ "f64", .f64 },
});

pub const Value = union(Type) {
    i8: i8,
    i32: i32,
    i64: i64,
    f64: f64,

    pub fn getType(self: Value) Type {
        return std.meta.activeTag(self);
    }

    pub fn isFloat(self: Value) bool {
        return self == .f64;
    }

    /// Widen any integer variant to i64. Illegal on floats.
    pub fn asI64(self: Value) i64 {
        return switch (self) {
            .i8 => |v| v,
            .i32 => |v| v,
            .i64 => |v| v,
            .f64 => unreachable,
        };
    }

    pub fn asF64(self: Value) f64 {
        return switch (self) {
            .i8 => |v| @floatFromInt(v),
            .i32 => |v| @floatFromInt(v),
            .i64 => |v| @floatFromInt(v),
            .f64 => |v| v,
        };
    }

    /// Convert to `target`. Int widening/narrowing is range-checked,
    /// int -> f64 is allowed, f64 -> int is a type mismatch.
    pub fn coerce(self: Value, target: Type) !Value {
        if (self.getType() == target) return self;
        if (self == .f64) return error.TypeMismatch; // no implicit float -> int
        const int = self.asI64();
        return switch (target) {
            .i8 => .{ .i8 = std.math.cast(i8, int) orelse return error.Overflow },
            .i32 => .{ .i32 = std.math.cast(i32, int) orelse return error.Overflow },
            .i64 => .{ .i64 = int },
            .f64 => .{ .f64 = @floatFromInt(int) },
        };
    }

    pub fn write(self: Value, writer: *std.Io.Writer) !void {
        switch (self) {
            .f64 => |v| try writer.print("{d}", .{v}),
            inline else => |v| try writer.print("{d}", .{v}),
        }
    }
};

/// Result type of a binary operation: f64 if either side is float,
/// otherwise the wider of the two integer types.
pub fn unify(a: Type, b: Type) Type {
    if (a == .f64 or b == .f64) return .f64;
    return if (@intFromEnum(a) > @intFromEnum(b)) a else b;
}

test "coerce widening" {
    const v = Value{ .i8 = 7 };
    try std.testing.expectEqual(Value{ .i64 = 7 }, try v.coerce(.i64));
    try std.testing.expectEqual(Value{ .f64 = 7 }, try v.coerce(.f64));
}

test "coerce narrowing in range" {
    const v = Value{ .i64 = 7 };
    try std.testing.expectEqual(Value{ .i8 = 7 }, try v.coerce(.i8));
}

test "coerce narrowing out of range" {
    const v = Value{ .i64 = 300 };
    try std.testing.expectError(error.Overflow, v.coerce(.i8));
}

test "coerce float to int is rejected" {
    const v = Value{ .f64 = 1.5 };
    try std.testing.expectError(error.TypeMismatch, v.coerce(.i64));
}

test "unify types" {
    try std.testing.expectEqual(Type.i64, unify(.i8, .i64));
    try std.testing.expectEqual(Type.f64, unify(.i64, .f64));
    try std.testing.expectEqual(Type.i8, unify(.i8, .i8));
}

test "type names" {
    try std.testing.expectEqual(Type.i8, type_names.get("i8").?);
    try std.testing.expectEqual(@as(?Type, null), type_names.get("u7"));
}
