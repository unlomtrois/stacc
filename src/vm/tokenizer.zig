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

fn helper(src: []const u8, expected: []const Value) !void {
    const allocator = std.heap.page_allocator;
    const tokens: []Value = try tokenize(src, allocator);
    defer allocator.free(tokens);

    for (tokens, 0..) |token, i| {
        try std.testing.expectEqual(expected[i], token);
    }
}

test "2 + 2 = 4" {
    try helper("2 2 +", &[_]Value{
        Value{ .number = 2 },
        Value{ .number = 2 },
        Value.add,
    });
}
