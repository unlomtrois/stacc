const std = @import("std");
const Io = std.Io;
const stacc = @import("stacc");
const Lexer = stacc.lexer.Lexer;

const usage_text =
    \\stacc - the Stacy compiler
    \\
    \\Usage:
    \\  stacc run <file.stacy>                compile and run a program
    \\  stacc compile <file.stacy> [-o out]   compile to a native executable
    \\
    \\Options:
    \\  --interpret  run on the bytecode VM instead of compiling (run only)
    \\  --verbose    trace type checking and show the compiled bytecode
    \\  --emit-asm   keep the generated .s and .runtime.c (compile only)
    \\
;

fn usageAndExit() noreturn {
    std.debug.print("{s}", .{usage_text});
    std.process.exit(1);
}

const Command = enum { run, compile };

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2) usageAndExit();

    const command = std.meta.stringToEnum(Command, args[1]) orelse {
        std.debug.print("unknown command: {s}\n\n", .{args[1]});
        usageAndExit();
    };

    var verbose = false;
    var emit_asm = false;
    var interpret = false;
    var out_name: ?[]const u8 = null;
    var file_path: ?[]const u8 = null;
    var arg_index: usize = 2;
    while (arg_index < args.len) : (arg_index += 1) {
        const arg = args[arg_index];
        if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--interpret") and command == .run) {
            interpret = true;
        } else if (std.mem.eql(u8, arg, "--emit-asm") and command == .compile) {
            emit_asm = true;
        } else if (std.mem.eql(u8, arg, "-o") and command == .compile) {
            arg_index += 1;
            if (arg_index >= args.len) {
                std.debug.print("-o requires an output name\n\n", .{});
                usageAndExit();
            }
            out_name = args[arg_index];
        } else if (file_path == null and !std.mem.startsWith(u8, arg, "-")) {
            file_path = arg;
        } else {
            std.debug.print("unexpected argument: {s}\n\n", .{arg});
            usageAndExit();
        }
    }
    const path = file_path orelse usageAndExit();

    const src = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20));

    // project-local modules: `use foo;` for a non-builtin name loads
    // modules/foo.stacy (transitively)
    var local_modules: std.ArrayList(stacc.compiler.ModuleSource) = .empty;
    try collectLocalModules(allocator, io, src, &local_modules);

    if (verbose) std.debug.print("── typecheck ──\n", .{});
    const program = try stacc.compiler.compileWithModules(allocator, src, local_modules.items, verbose);

    if (verbose) {
        std.debug.print("── compiled {d} instructions ──\n", .{program.len});
        for (program, 0..) |inst, i| {
            std.debug.print("{d:>4}: {f}\n", .{ i, inst });
        }
        if (command == .run) std.debug.print("── output ──\n", .{});
    }

    switch (command) {
        .run => if (interpret) {
            try runInterpreted(allocator, io, program);
        } else {
            try runNative(allocator, io, program, stem(path));
        },
        .compile => try compileNative(allocator, io, program, out_name orelse stem(path), emit_asm),
    }
}

/// go-run style: compile to a temporary executable, execute it, clean
/// up, and propagate the program's exit code.
fn runNative(allocator: std.mem.Allocator, io: Io, program: []const stacc.compiler.Instruction, name: []const u8) !void {
    const out = try std.fmt.allocPrint(allocator, "/tmp/stacc-run-{d}-{s}", .{ std.os.linux.getpid(), name });
    try compileNative(allocator, io, program, out, false);

    const argv = [_][]const u8{out};
    var child = try std.process.spawn(io, .{ .argv = &argv });
    const term = child.wait(io);
    Io.Dir.deleteFileAbsolute(io, out) catch {};

    switch (try term) {
        .exited => |code| if (code != 0) std.process.exit(code),
        else => std.process.exit(1),
    }
}

fn runInterpreted(allocator: std.mem.Allocator, io: Io, program: []const stacc.compiler.Instruction) !void {
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

/// Lower the program to x86-64 assembly and assemble+link it with
/// `zig cc`. Silent on success; intermediates are removed unless
/// `keep_asm` is set.
fn compileNative(allocator: std.mem.Allocator, io: Io, program: []const stacc.compiler.Instruction, out: []const u8, keep_asm: bool) !void {
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

    // hybrid modules contribute their extern implementations to the link
    var extra_c_paths: std.ArrayList([]const u8) = .empty;
    {
        var seen: std.ArrayList([]const u8) = .empty;
        for (program) |inst| {
            switch (inst) {
                .call_extern => |e| {
                    const impl = stacc.modules.nativeImplForSymbol(e.symbol) orelse continue;
                    var already = false;
                    for (seen.items) |ptr| {
                        if (ptr.ptr == impl.ptr) already = true;
                    }
                    if (already) continue;
                    try seen.append(allocator, impl);
                    const impl_path = try std.fmt.allocPrint(allocator, "{s}.mod{d}.c", .{ out, extra_c_paths.items.len });
                    try Io.Dir.cwd().writeFile(io, .{ .sub_path = impl_path, .data = impl });
                    try extra_c_paths.append(allocator, impl_path);
                },
                else => {},
            }
        }
    }
    defer if (!keep_asm) {
        Io.Dir.cwd().deleteFile(io, asm_path) catch {};
        Io.Dir.cwd().deleteFile(io, runtime_path) catch {};
        for (extra_c_paths.items) |impl_path| {
            Io.Dir.cwd().deleteFile(io, impl_path) catch {};
        }
    };

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(allocator, &.{ "zig", "cc", asm_path, runtime_path });
    try argv.appendSlice(allocator, extra_c_paths.items);
    try argv.appendSlice(allocator, &.{ "-o", out, "-lm" });
    var child = try std.process.spawn(io, .{ .argv = argv.items });
    const term = child.wait(io) catch |err| {
        std.debug.print("failed to run zig cc: {t}\n", .{err});
        return err;
    };
    if (!term.success()) {
        std.debug.print("zig cc failed: {f}\n", .{term});
        return error.AssemblerFailed;
    }
}

/// Lex-scan a source for `use <name>;` and load modules/<name>.stacy
/// for names the builtin registry does not know, recursively. Missing
/// files are left for the compiler to report as UnknownModule.
fn collectLocalModules(allocator: std.mem.Allocator, io: Io, src: []const u8, out: *std.ArrayList(stacc.compiler.ModuleSource)) !void {
    var lexer = Lexer.init(src) catch return;
    var previous_was_use = false;
    while (lexer.next()) |token| {
        if (token.tag == .eof) break;
        defer previous_was_use = token.tag == .keyword_use;
        if (!previous_was_use or token.tag != .identifier) continue;
        const name = token.getValue(src);
        if (stacc.modules.find(name) != null) continue;
        var known = false;
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing.name, name)) known = true;
        }
        if (known) continue;
        const module_path = try std.fmt.allocPrint(allocator, "modules/{s}.stacy", .{name});
        const module_src = Io.Dir.cwd().readFileAlloc(io, module_path, allocator, .limited(1 << 20)) catch continue;
        try out.append(allocator, .{ .name = name, .src = module_src });
        try collectLocalModules(allocator, io, module_src, out);
    }
}
