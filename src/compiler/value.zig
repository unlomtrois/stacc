const std = @import("std");

/// Integer types are declared in widening order; `unify` relies on it.
/// `bool` never participates in unification or arithmetic.
pub const Type = enum { bool, i8, i32, i64, f64 };

pub const type_names = std.StaticStringMap(Type).initComptime(.{
    .{ "bool", .bool },
    .{ "i8", .i8 },
    .{ "i32", .i32 },
    .{ "i64", .i64 },
    .{ "f64", .f64 },
});

pub const Value = union(Type) {
    bool: bool,
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

    /// Widen any integer variant to i64. Illegal on floats and bools.
    pub fn asI64(self: Value) i64 {
        return switch (self) {
            .i8 => |v| v,
            .i32 => |v| v,
            .i64 => |v| v,
            .bool, .f64 => unreachable,
        };
    }

    pub fn asF64(self: Value) f64 {
        return switch (self) {
            .i8 => |v| @floatFromInt(v),
            .i32 => |v| @floatFromInt(v),
            .i64 => |v| @floatFromInt(v),
            .f64 => |v| v,
            .bool => unreachable,
        };
    }

    /// Convert to `target`. Int widening/narrowing is range-checked,
    /// int -> f64 is allowed, f64 -> int is a type mismatch, and bool
    /// converts to and from nothing.
    pub fn coerce(self: Value, target: Type) !Value {
        if (self.getType() == target) return self;
        if (self == .bool or target == .bool) return error.TypeMismatch;
        if (self == .f64) return error.TypeMismatch; // no implicit float -> int
        const int = self.asI64();
        return switch (target) {
            .bool => unreachable,
            .i8 => .{ .i8 = std.math.cast(i8, int) orelse return error.Overflow },
            .i32 => .{ .i32 = std.math.cast(i32, int) orelse return error.Overflow },
            .i64 => .{ .i64 = int },
            .f64 => .{ .f64 = @floatFromInt(int) },
        };
    }

    pub fn write(self: Value, writer: *std.Io.Writer) !void {
        switch (self) {
            .bool => |v| try writer.writeAll(if (v) "true" else "false"),
            .f64 => |v| try writer.print("{d}", .{v}),
            inline else => |v| try writer.print("{d}", .{v}),
        }
    }

    /// `{f}` formatter: value with its type, e.g. `5:i8`
    pub fn format(self: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.write(writer);
        try writer.print(":{s}", .{@tagName(self.getType())});
    }
};

/// Result type of a binary operation: f64 if either side is float,
/// otherwise the wider of the two integer types. Callers must reject
/// bool operands before unifying.
pub fn unify(a: Type, b: Type) Type {
    std.debug.assert(a != .bool and b != .bool);
    if (a == .f64 or b == .f64) return .f64;
    return if (@intFromEnum(a) > @intFromEnum(b)) a else b;
}

/// Static coercibility check: mirrors `Value.coerce` at the type level.
/// Narrowing int conversions are allowed here (the VM range-checks the
/// actual value); float -> int and anything involving bool are not.
pub fn canCoerce(from: Type, to: Type) bool {
    if (from == to) return true;
    if (from == .bool or to == .bool) return false;
    if (from == .f64) return false;
    return true;
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
    try std.testing.expectEqual(Type.bool, type_names.get("bool").?);
    try std.testing.expectEqual(@as(?Type, null), type_names.get("u7"));
}

test "bool converts to and from nothing" {
    const b = Value{ .bool = true };
    try std.testing.expectEqual(b, try b.coerce(.bool));
    try std.testing.expectError(error.TypeMismatch, b.coerce(.i64));
    try std.testing.expectError(error.TypeMismatch, (Value{ .i64 = 1 }).coerce(.bool));
    try std.testing.expectError(error.TypeMismatch, (Value{ .f64 = 1 }).coerce(.bool));
}

test "canCoerce mirrors coerce statically" {
    try std.testing.expect(canCoerce(.i8, .i64)); // widening
    try std.testing.expect(canCoerce(.i64, .i8)); // narrowing, runtime-checked
    try std.testing.expect(canCoerce(.i64, .f64)); // int -> float
    try std.testing.expect(canCoerce(.bool, .bool));
    try std.testing.expect(!canCoerce(.f64, .i64)); // no implicit float -> int
    try std.testing.expect(!canCoerce(.bool, .i64));
    try std.testing.expect(!canCoerce(.i64, .bool));
}
