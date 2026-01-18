//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const Value = union(enum) {
    number: f64,
    add: void,
    sub: void,
    mul: void,
    div: void,
    pov: void,
    dup: void,
    print: void,
};

fn tokenizeNumber(src: []const u8) usize {
    var i: usize = 0;
    while (i < src.len) {
        const char: u8 = src[i];
        if (char < '0' or char > '9') {
            break;
        }
        i += 1;
    }
    return i;
}

pub fn tokenize(src: []const u8, allocator: std.mem.Allocator) ![]Value {
    var tokens = std.ArrayList(Value).empty;
    errdefer tokens.deinit(allocator);

    var i: usize = 0;
    while (i < src.len) {
        defer i += 1;
        const char: u8 = src[i];
        switch (char) {
            '0'...'9' => {
                const len: usize = tokenizeNumber(src[i..]);
                const number: f64 = try std.fmt.parseFloat(f64, src[i .. i + len]);
                i += len;
                try tokens.append(allocator, .{ .number = number });
            },
            '+' => {
                try tokens.append(allocator, .add);
            },
            '-' => {
                try tokens.append(allocator, .sub);
            },
            '*' => {
                try tokens.append(allocator, .mul);
            },
            '/' => {
                try tokens.append(allocator, .div);
            },
            '^' => {
                try tokens.append(allocator, .pov);
            },
            'p' => {
                try tokens.append(allocator, .print);
            },
            'd' => {
                try tokens.append(allocator, .dup);
            },
            ' ' => {
                continue;
            },
            else => {
                return error.InvalidCharacter;
            },
        }
    }
    return tokens.toOwnedSlice(allocator);
}

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
                std.debug.print("add: {d} + {d} = {d}\n", .{ a.number, b.number, res });
                try stack.append(allocator, .{ .number = res });
            },
            .sub => {
                std.debug.assert(stack.items.len >= 2);
                const a = stack.pop().?;
                std.debug.assert(a == .number);
                const b = stack.pop().?;
                std.debug.assert(b == .number);
                const res = b.number - a.number;
                std.debug.print("sub: {d} - {d} = {d}\n", .{ a.number, b.number, res });
                try stack.append(allocator, .{ .number = res });
            },
            .mul => {
                std.debug.assert(stack.items.len >= 2);
                const a = stack.pop().?;
                std.debug.assert(a == .number);
                const b = stack.pop().?;
                std.debug.assert(b == .number);
                const res = a.number * b.number;
                std.debug.print("mul: {d} * {d} = {d}\n", .{ a.number, b.number, res });
                try stack.append(allocator, .{ .number = res });
            },
            .div => {
                std.debug.assert(stack.items.len >= 2);
                const a = stack.pop().?;
                std.debug.assert(a == .number);
                const b = stack.pop().?;
                std.debug.assert(b == .number);
                if (b.number == 0) {
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

test "2 + 2 = 4" {
    const allocator = std.heap.page_allocator;
    const tokens = try tokenize("2 2 +", allocator);
    const result = try execute(tokens, allocator);
    try std.testing.expectEqual(@as(f64, 4), result[0].number);
}

test "(2 + 2) / 2 = 2" {
    const allocator = std.heap.page_allocator;
    const tokens = try tokenize("2 2 + 2 /", allocator);
    const result = try execute(tokens, allocator);
    try std.testing.expectEqual(@as(f64, 2), result[0].number);
}

test "16 / 8 = 2" {
    const allocator = std.heap.page_allocator;
    const tokens = try tokenize("16 8 /", allocator);
    const result = try execute(tokens, allocator);
    try std.testing.expectEqual(@as(f64, 2), result[0].number);
}

test "8 / 16 = 0.5" {
    const allocator = std.heap.page_allocator;
    const tokens = try tokenize("8 16 /", allocator);
    const result = try execute(tokens, allocator);
    try std.testing.expectEqual(@as(f64, 0.5), result[0].number);
}

test "2 * 2 + 2 = 6" {
    const allocator = std.heap.page_allocator;
    const tokens = try tokenize("2 2 * 2 +", allocator);
    const result = try execute(tokens, allocator);
    try std.testing.expectEqual(@as(f64, 6), result[0].number);
}

test "2 * (2 + 2) = 8" {
    const allocator = std.heap.page_allocator;
    const tokens = try tokenize("2 2 2 + *", allocator);
    const result = try execute(tokens, allocator);
    try std.testing.expectEqual(@as(f64, 8), result[0].number);
}

test "division by zero" {
    const allocator = std.heap.page_allocator;
    const tokens = try tokenize("2 2 - 2 /", allocator);
    const result = execute(tokens, allocator);
    try std.testing.expectError(error.DivisionByZero, result);
}

test "tokenize number with multiple digits" {
    const allocator = std.heap.page_allocator;
    const tokens = try tokenize("69", allocator);
    try std.testing.expectEqual(@as(f64, 69), tokens[0].number);
}

test "69 + 420 = 489" {
    const allocator = std.heap.page_allocator;
    const tokens = try tokenize("69 420 +", allocator);
    const result = try execute(tokens, allocator);
    try std.testing.expectEqual(@as(f64, 489), result[0].number);
}

test "power of" {
    const allocator = std.heap.page_allocator;
    const tokens = try tokenize("2 3 ^", allocator);
    const result = try execute(tokens, allocator);
    try std.testing.expectEqual(@as(f64, 8), result[0].number);
}

test "1 - 5 = -4" {
    const allocator = std.heap.page_allocator;
    const tokens = try tokenize("1 5 -", allocator);
    const result = try execute(tokens, allocator);
    try std.testing.expectEqual(@as(f64, -4), result[0].number);
}

test "duplicate" {
    const allocator = std.heap.page_allocator;
    const tokens = try tokenize("2 d +", allocator);
    const result = try execute(tokens, allocator);
    try std.testing.expectEqual(@as(f64, 4), result[0].number);
}

test "(1 - 5) ^ 2" {
    const allocator = std.heap.page_allocator;
    const tokens = try tokenize("1 5 - 2 ^", allocator);
    const result = try execute(tokens, allocator);
    try std.testing.expectEqual(@as(f64, 16), result[0].number);
}

test "3 + 4 * 2 ÷ ( 1 - 5 ) ^ 2 = 3.5" {
    const allocator = std.heap.page_allocator;
    const tokens = try tokenize("3 4 2 * 1 5 - 2 ^ / +", allocator);
    const result = try execute(tokens, allocator);
    try std.testing.expectEqual(@as(f64, 3.5), result[0].number);
}
