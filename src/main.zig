const std = @import("std");
const Io = std.Io;
const stacc = @import("stacc");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2) {
        std.debug.print("Usage: {s} <file.stacy>\n", .{args[0]});
        return error.NoInput;
    }

    const src = try Io.Dir.cwd().readFileAlloc(io, args[1], allocator, .limited(1 << 20));

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const writer = &stdout_writer.interface;

    try stacc.compiler.interpret(allocator, src, writer);

    try writer.flush();
}
