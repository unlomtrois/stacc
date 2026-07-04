const std = @import("std");
const Io = std.Io;
const stacc = @import("stacc");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(allocator);

    var verbose = false;
    var native = false;
    var out_name: ?[]const u8 = null;
    var file_path: ?[]const u8 = null;
    var arg_index: usize = 1;
    while (arg_index < args.len) : (arg_index += 1) {
        const arg = args[arg_index];
        if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--native")) {
            native = true;
        } else if (std.mem.eql(u8, arg, "-o")) {
            arg_index += 1;
            if (arg_index >= args.len) {
                std.debug.print("-o requires an output name\n", .{});
                return error.InvalidArgument;
            }
            out_name = args[arg_index];
        } else if (file_path == null) {
            file_path = arg;
        } else {
            std.debug.print("Unexpected argument: {s}\n", .{arg});
            return error.InvalidArgument;
        }
    }
    const path = file_path orelse {
        std.debug.print("Usage: {s} [--verbose] [--native [-o out]] <file.stacy>\n", .{args[0]});
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

    if (native) {
        try compileNative(allocator, io, program, out_name orelse stem(path));
        return;
    }

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const writer = &stdout_writer.interface;

    var vm = stacc.compiler.Vm.init(allocator, writer);
    defer vm.deinit();
    try vm.run(program);

    try writer.flush();
}

/// Basename without directory or extension: "examples/fib.stacy" -> "fib"
fn stem(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    return base[0..dot];
}

/// Lower the program to x86-64 assembly, write it and the C runtime
/// next to the output, and assemble+link with `zig cc`.
fn compileNative(allocator: std.mem.Allocator, io: Io, program: []const stacc.compiler.Instruction, out: []const u8) !void {
    const asm_path = try std.fmt.allocPrint(allocator, "{s}.s", .{out});
    const runtime_path = try std.fmt.allocPrint(allocator, "{s}.runtime.c", .{out});

    {
        const file = try Io.Dir.cwd().createFile(io, asm_path, .{});
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var file_writer: Io.File.Writer = .init(file, io, &buffer);
        try stacc.codegen_x86.emit(allocator, program, &file_writer.interface);
        try file_writer.interface.flush();
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = runtime_path, .data = stacc.codegen_x86.runtime_c });

    const argv = [_][]const u8{ "zig", "cc", asm_path, runtime_path, "-o", out, "-lm" };
    var child = try std.process.spawn(io, .{ .argv = &argv });
    const term = child.wait(io) catch |err| {
        std.debug.print("failed to run zig cc: {t}\n", .{err});
        return err;
    };
    if (!term.success()) {
        std.debug.print("zig cc failed: {f}\n", .{term});
        return error.AssemblerFailed;
    }
    std.debug.print("built ./{s} (assembly in {s})\n", .{ out, asm_path });
}
