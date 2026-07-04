const std = @import("std");
const Io = std.Io;
const stacc = @import("stacc");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(allocator);

    var verbose = false;
    var file_path: ?[]const u8 = null;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (file_path == null) {
            file_path = arg;
        } else {
            std.debug.print("Unexpected argument: {s}\n", .{arg});
            return error.InvalidArgument;
        }
    }
    const path = file_path orelse {
        std.debug.print("Usage: {s} [--verbose] <file.stacy>\n", .{args[0]});
        return error.NoInput;
    };

    const src = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20));

    const program = if (verbose) blk: {
        std.debug.print("── typecheck ──\n", .{});
        break :blk try stacc.compiler.compileVerbose(allocator, src);
    } else try stacc.compiler.compile(allocator, src);

    if (verbose) {
        std.debug.print("── compiled {d} instructions ──\n", .{program.len});
        for (program, 0..) |inst, i| {
            std.debug.print("{d:>4}: {f}\n", .{ i, inst });
        }
        std.debug.print("── output ──\n", .{});
    }

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const writer = &stdout_writer.interface;

    var vm = stacc.compiler.Vm.init(allocator, writer);
    defer vm.deinit();
    try vm.run(program);

    try writer.flush();
}
