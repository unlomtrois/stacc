const std = @import("std");
const stacc = @import("stacc");

const tokenize = stacc.tokenize;
const execute = stacc.execute;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <input>\n", .{args[0]});
        return error.NoInput;
    }

    const input = args[1];
    const tokens = try tokenize(input, allocator);
    const result = try execute(tokens, allocator);

    _ = result;
}
