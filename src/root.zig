//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const Value = union(enum) {
    number: u32,
    add: void,
    sub: void,
    mul: void,
    div: void,
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
                const number: u32 = try std.fmt.parseInt(u32, src[i .. i + len], 10);
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
            'p' => {
                try tokens.append(allocator, .print);
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
                try stack.append(allocator, .{ .number = res });
            },
            .sub => {
                std.debug.assert(stack.items.len >= 2);
                const a = stack.pop().?;
                std.debug.assert(a == .number);
                const b = stack.pop().?;
                std.debug.assert(b == .number);
                const res = a.number - b.number;
                try stack.append(allocator, .{ .number = res });
            },
            .mul => {
                std.debug.assert(stack.items.len >= 2);
                const a = stack.pop().?;
                std.debug.assert(a == .number);
                const b = stack.pop().?;
                std.debug.assert(b == .number);
                const res = a.number * b.number;
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
                const res = a.number / b.number;
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
        }
    }

    return stack.toOwnedSlice(allocator);
}

test "2 + 2 = 4" {
    const allocator = std.heap.page_allocator;
    const tokens = try tokenize("2 2 +", allocator);
    const result = try execute(tokens, allocator);
    try std.testing.expect(result[0].number == 4);
}

test "(2 + 2) / 2 = 2" {
    const allocator = std.heap.page_allocator;
    const tokens = try tokenize("2 2 2 + /", allocator);
    const result = try execute(tokens, allocator);
    try std.testing.expect(result[0].number == 2);
}

test "2 * 2 + 2 = 6" {
    const allocator = std.heap.page_allocator;
    const tokens = try tokenize("2 2 * 2 +", allocator);
    const result = try execute(tokens, allocator);
    try std.testing.expect(result[0].number == 6);
}

test "2 * (2 + 2) = 8" {
    const allocator = std.heap.page_allocator;
    const tokens = try tokenize("2 2 2 + *", allocator);
    const result = try execute(tokens, allocator);
    try std.testing.expect(result[0].number == 8);
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
    try std.testing.expect(tokens[0].number == 69);
}

test "69 + 420 = 489" {
    const allocator = std.heap.page_allocator;
    const tokens = try tokenize("69 420 +", allocator);
    const result = try execute(tokens, allocator);
    try std.testing.expectEqual(@as(u32, 489), result[0].number);
}
