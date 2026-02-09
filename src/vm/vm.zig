const std = @import("std");

pub const tokenize = @import("tokenizer.zig").tokenize;
pub const execute = @import("executor.zig").execute;

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
    const tokens = try tokenize("2 2 2 - /", allocator);
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
