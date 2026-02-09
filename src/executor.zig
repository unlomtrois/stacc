const std = @import("std");
const Value = @import("tokenizer.zig").Value;

pub fn execute(tokens: []Value, allocator: std.mem.Allocator) ![]Value {
    var stack = std.ArrayList(Value).empty;
    defer stack.deinit(allocator);

    for (tokens) |item| {
        switch (item) {
            .number => {
                try stack.append(allocator, item);
            },
            .add => {
                std.debug.assert(stack.items.len >= 2);
                const a = stack.pop().?;
                std.debug.assert(a == .number);
                const b = stack.pop().?;
                std.debug.assert(b == .number);
                const res = a.number + b.number;
                std.debug.print("add: {d} + {d} = {d}\n", .{ b.number, a.number, res });
                try stack.append(allocator, .{ .number = res });
            },
            .sub => {
                std.debug.assert(stack.items.len >= 2);
                const a = stack.pop().?;
                std.debug.assert(a == .number);
                const b = stack.pop().?;
                std.debug.assert(b == .number);
                const res = b.number - a.number;
                std.debug.print("sub: {d} - {d} = {d}\n", .{ b.number, a.number, res });
                try stack.append(allocator, .{ .number = res });
            },
            .mul => {
                std.debug.assert(stack.items.len >= 2);
                const a = stack.pop().?;
                std.debug.assert(a == .number);
                const b = stack.pop().?;
                std.debug.assert(b == .number);
                const res = a.number * b.number;
                std.debug.print("mul: {d} * {d} = {d}\n", .{ b.number, a.number, res });
                try stack.append(allocator, .{ .number = res });
            },
            .div => {
                std.debug.assert(stack.items.len >= 2);
                const a = stack.pop().?;
                std.debug.assert(a == .number);
                const b = stack.pop().?;
                std.debug.assert(b == .number);
                if (a.number == 0) {
                    std.debug.print("Division by zero: {d} / {d}\n", .{ b.number, a.number });
                    return error.DivisionByZero;
                }
                const res = b.number / a.number;
                std.debug.print("div: {d} / {d} = {d}\n", .{ b.number, a.number, res });
                try stack.append(allocator, .{ .number = res });
            },
            .print => {
                std.debug.assert(stack.items.len >= 1);
                const value = stack.pop().?;
                switch (value) {
                    .number => |n| {
                        std.debug.print("{d}\n", .{n});
                    },
                    else => {
                        std.debug.print("Unknown value: {any}\n", .{value});
                    },
                }
            },
            .dup => {
                std.debug.assert(stack.items.len >= 1);
                const value = stack.pop().?;
                try stack.append(allocator, value);
                try stack.append(allocator, value);
            },
            .pov => {
                std.debug.assert(stack.items.len >= 1);
                const a = stack.pop().?;
                std.debug.assert(a == .number);
                const b = stack.pop().?;
                std.debug.assert(b == .number);
                const res = std.math.pow(f64, b.number, a.number);
                std.debug.print("pov: {d} ^ {d} = {d}\n", .{ b.number, a.number, res });
                try stack.append(allocator, .{ .number = res });
            },
        }
    }

    return stack.toOwnedSlice(allocator);
}
