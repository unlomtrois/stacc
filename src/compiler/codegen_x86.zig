//! x86-64 (System V, AT&T syntax) code generation from the typed bytecode.
//!
//! Register allocation without graphs, in two linear passes:
//!
//! 1. A prescan walks the flat bytecode once and computes, per frame,
//!    the live interval [first access, last access] of every variable
//!    slot, clamped to enclosing loop brackets (a variable touched
//!    inside a loop is live for the whole loop — liveness as bracket
//!    matching, not dataflow). Because Stacy declares before use and
//!    has structured control flow only, these intervals ARE the
//!    interference structure: the graph is an interval graph, and
//!    greedy assignment in declaration order (with furthest-end
//!    eviction when registers run out) is an optimal coloring. No
//!    interference graph is ever materialized.
//!
//! 2. Emission maps expression temporaries to a fixed register pool by
//!    virtual stack depth — stack discipline means depth is itself an
//!    optimal coloring — and variables to callee-saved registers per
//!    the prescan's plan. Frames whose expressions are deeper than the
//!    pool fall back to hardware-stack push/pop for temporaries.
//!
//! Runtime conventions (unchanged from the stack backend):
//! - Every value is one 8-byte quad: integers sign-extended, f64 as
//!   its bit pattern, bool as 0/1.
//! - Memory-resident slots live at rbp-relative offsets below the
//!   saved callee-saved registers; each frame keeps one hidden scratch
//!   quad to save/realign %rsp around calls into the C runtime.
//! - Calls pass arguments on the hardware stack (the register pool is
//!   flushed around calls; variable registers are callee-saved and
//!   survive for free). The callee copies args into its slots; the
//!   caller pops them and pushes %rax if a value returns.

const std = @import("std");

const value_mod = @import("value.zig");
const Type = value_mod.Type;
const Value = value_mod.Value;
const instruction_mod = @import("instruction.zig");
const Instruction = instruction_mod.Instruction;

/// The C runtime source, written next to the generated assembly and
/// compiled together with it.
pub const runtime_c = @embedFile("../runtime/stacc_runtime.c");

/// Expression temporaries: caller-saved, by virtual stack depth.
const pool_regs = [_][]const u8{ "%rsi", "%rdi", "%r8", "%r9", "%r10" };
const max_pool_depth = pool_regs.len;

/// Variables: callee-saved, assigned by interval allocation.
const var_regs = [_][]const u8{ "%rbx", "%r12", "%r13", "%r14", "%r15" };
const var_regs_32 = [_][]const u8{ "%ebx", "%r12d", "%r13d", "%r14d", "%r15d" };

const Mode = enum { register, stack };

const Home = union(enum) {
    reg: u8, // index into var_regs
    mem: u32, // rank among memory-resident slots
};

const Interval = struct {
    first: usize,
    last: usize,
};

const RegionPlan = struct {
    mode: Mode,
    num_slots: u32,
    homes: []Home,
    /// how many var_regs this frame saves (indices 0..used_regs-1)
    used_regs: u8,
    mem_count: u32,

    fn deinit(self: *RegionPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.homes);
    }

    /// rbp-relative location of a slot, as text.
    fn slotLocation(self: *const RegionPlan, buf: []u8, slot: u32) []const u8 {
        return switch (self.homes[slot]) {
            .reg => |r| var_regs[r],
            .mem => |rank| std.fmt.bufPrint(buf, "{d}(%rbp)", .{memOffset(self, rank)}) catch unreachable,
        };
    }

    fn memOffset(self: *const RegionPlan, rank: u32) i64 {
        return -8 * (@as(i64, self.used_regs) + rank + 1);
    }

    /// hidden scratch quad for %rsp save/realign around C helper calls
    fn scratchOffset(self: *const RegionPlan) i64 {
        return -8 * (@as(i64, self.num_slots) + 1);
    }

    /// bytes to subtract in the prologue: memory slots + scratch
    fn frameBytes(self: *const RegionPlan) i64 {
        return 8 * (@as(i64, self.mem_count) + 1);
    }
};

const Plan = struct {
    labels: std.AutoHashMapUnmanaged(usize, void),
    /// keyed by region start: 0 for main, fn_prologue index for functions
    regions: std.AutoHashMapUnmanaged(usize, RegionPlan),

    fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        self.labels.deinit(allocator);
        var it = self.regions.valueIterator();
        while (it.next()) |region| region.deinit(allocator);
        self.regions.deinit(allocator);
    }
};

const RegionBuilder = struct {
    start: usize,
    num_slots: u32,
    max_depth: usize = 0,
    intervals: []?Interval,
    back_edges: std.ArrayList([2]usize) = .empty,

    fn init(allocator: std.mem.Allocator, start: usize, num_slots: u32) !RegionBuilder {
        const intervals = try allocator.alloc(?Interval, num_slots);
        @memset(intervals, null);
        return .{ .start = start, .num_slots = num_slots, .intervals = intervals };
    }

    fn deinit(self: *RegionBuilder, allocator: std.mem.Allocator) void {
        allocator.free(self.intervals);
        self.back_edges.deinit(allocator);
    }

    fn access(self: *RegionBuilder, slot: u32, index: usize) void {
        if (self.intervals[slot]) |*interval| {
            interval.last = index;
        } else {
            self.intervals[slot] = .{ .first = index, .last = index };
        }
    }
};

// ── pass 1: analysis ───────────────────────────────────────────────

fn analyze(allocator: std.mem.Allocator, program: []const Instruction) !Plan {
    var plan = Plan{ .labels = .empty, .regions = .empty };
    errdefer plan.deinit(allocator);

    for (program) |inst| {
        switch (inst) {
            .jump, .jump_if_false => |target| try plan.labels.put(allocator, target, {}),
            else => {},
        }
    }

    var main_builder: ?RegionBuilder = null;
    defer if (main_builder) |*b| b.deinit(allocator);
    var fn_builder: ?RegionBuilder = null;
    defer if (fn_builder) |*b| b.deinit(allocator);
    var fn_end: ?usize = null;
    var depth: usize = 0;

    for (program, 0..) |inst, index| {
        if (fn_end) |end| {
            if (index == end) {
                var b = fn_builder.?;
                try plan.regions.put(allocator, b.start, try finalizeRegion(allocator, &b));
                b.deinit(allocator);
                fn_builder = null;
                fn_end = null;
                depth = 0;
            }
        }
        switch (inst) {
            .enter => |n| {
                main_builder = try RegionBuilder.init(allocator, 0, n);
            },
            .fn_prologue => |f| {
                fn_builder = try RegionBuilder.init(allocator, index, f.num_slots);
                fn_end = program[index - 1].jump; // the jump-over before every body
                depth = 0;
                // parameters are defined by the prologue's arg copies,
                // so their live ranges start here, not at first load
                var param: u32 = 0;
                while (param < f.num_params) : (param += 1) {
                    fn_builder.?.access(param, index);
                }
            },
            else => {},
        }

        const builder: *RegionBuilder = if (fn_builder) |*b| b else &(main_builder.?);
        switch (inst) {
            .load => |l| {
                builder.access(l.slot, index);
                depth += 1;
            },
            .store => |s| {
                builder.access(s.slot, index);
                depth -= 1;
            },
            .push_const => depth += 1,
            .add, .sub, .mul, .div, .pow, .eq, .ne, .lt, .gt, .le, .ge => depth -= 1,
            .pop, .print, .jump_if_false => depth -= 1,
            .call => |c| {
                depth -= c.num_params;
                if (c.returns_value) depth += 1;
            },
            .jump => |target| {
                if (target < index) try builder.back_edges.append(allocator, .{ target, index });
                depth = 0; // whatever follows is only reachable via a label
            },
            .ret => depth = 0,
            .trap => depth = 0,
            .enter, .fn_prologue, .convert, .convert_under => {},
        }
        builder.max_depth = @max(builder.max_depth, depth);
    }

    if (fn_builder) |*b| { // function body ending exactly at program end
        try plan.regions.put(allocator, b.start, try finalizeRegion(allocator, b));
        b.deinit(allocator);
        fn_builder = null;
    }
    var mb = main_builder.?;
    try plan.regions.put(allocator, 0, try finalizeRegion(allocator, &mb));
    mb.deinit(allocator);
    main_builder = null;

    return plan;
}

/// Clamp intervals to loop brackets, then color them greedily. The
/// intervals arrive sorted by start (slots are numbered in declaration
/// order), which is the perfect elimination order of the interval
/// graph, so the greedy scan is an optimal coloring. When more than
/// var_regs.len intervals overlap, the one ending furthest is demoted
/// to memory (Belady's rule applied to whole intervals).
fn finalizeRegion(allocator: std.mem.Allocator, builder: *RegionBuilder) !RegionPlan {
    const num_slots = builder.num_slots;
    const homes = try allocator.alloc(Home, num_slots);
    errdefer allocator.free(homes);

    if (builder.max_depth > max_pool_depth) {
        // deep expressions: hardware-stack mode, all variables in memory
        for (homes, 0..) |*home, k| home.* = .{ .mem = @intCast(k) };
        return .{
            .mode = .stack,
            .num_slots = num_slots,
            .homes = homes,
            .used_regs = 0,
            .mem_count = num_slots,
        };
    }

    // liveness as bracket matching: anything alive inside a loop is
    // alive for the whole loop
    for (builder.back_edges.items) |edge| {
        const head, const tail = .{ edge[0], edge[1] };
        for (builder.intervals) |*maybe| {
            const interval = &(maybe.* orelse continue);
            if (interval.first <= tail and interval.last >= head) {
                interval.first = @min(interval.first, head);
                interval.last = @max(interval.last, tail);
            }
        }
    }

    // greedy interval coloring with furthest-end eviction
    const Active = struct { slot: u32, last: usize };
    var active: [var_regs.len]?Active = @splat(null);
    var used_regs: u8 = 0;
    for (builder.intervals, 0..) |maybe, k| {
        const slot: u32 = @intCast(k);
        const interval = maybe orelse {
            homes[slot] = .{ .mem = 0 }; // never accessed; rank fixed below
            continue;
        };
        var free_reg: ?u8 = null;
        var furthest: ?u8 = null;
        for (&active, 0..) |*entry, r| {
            if (entry.*) |a| {
                if (a.last < interval.first) {
                    entry.* = null; // expired
                    if (free_reg == null) free_reg = @intCast(r);
                } else if (furthest == null or a.last > active[furthest.?].?.last) {
                    furthest = @intCast(r);
                }
            } else if (free_reg == null) {
                free_reg = @intCast(r);
            }
        }
        if (free_reg) |r| {
            active[r] = .{ .slot = slot, .last = interval.last };
            homes[slot] = .{ .reg = r };
            used_regs = @max(used_regs, r + 1);
        } else if (active[furthest.?].?.last > interval.last) {
            // evict the interval ending furthest, take its register
            const r = furthest.?;
            homes[active[r].?.slot] = .{ .mem = 0 };
            active[r] = .{ .slot = slot, .last = interval.last };
            homes[slot] = .{ .reg = r };
        } else {
            homes[slot] = .{ .mem = 0 };
        }
    }

    // assign memory ranks in slot order
    var mem_count: u32 = 0;
    for (homes) |*home| {
        if (home.* == .mem) {
            home.* = .{ .mem = mem_count };
            mem_count += 1;
        }
    }

    return .{
        .mode = .register,
        .num_slots = num_slots,
        .homes = homes,
        .used_regs = used_regs,
        .mem_count = mem_count,
    };
}

// ── pass 2: emission ───────────────────────────────────────────────

pub fn emit(allocator: std.mem.Allocator, program: []const Instruction, writer: *std.Io.Writer) !void {
    var plan = try analyze(allocator, program);
    defer plan.deinit(allocator);

    var emitter = Emitter{
        .writer = writer,
        .program = program,
        .plan = &plan,
        .region = plan.regions.getPtr(0).?,
    };
    try emitter.run();
}

const Emitter = struct {
    writer: *std.Io.Writer,
    program: []const Instruction,
    plan: *Plan,
    region: *const RegionPlan,
    depth: usize = 0,
    fn_end: ?usize = null,

    fn run(self: *Emitter) !void {
        try self.writer.writeAll(
            \\# generated by stacc (register allocator: interval coloring)
            \\.text
            \\.globl main
            \\
        );

        var skip_next = false;
        for (self.program, 0..) |inst, index| {
            if (self.fn_end) |end| {
                if (index == end) {
                    self.region = self.plan.regions.getPtr(0).?;
                    self.fn_end = null;
                    self.depth = 0;
                }
            }
            if (self.plan.labels.contains(index)) {
                if (self.region.mode == .register) std.debug.assert(self.depth == 0);
                try self.writer.print(".L{d}:\n", .{index});
            }
            if (skip_next) {
                skip_next = false;
                continue;
            }
            skip_next = try self.emitInstruction(inst, index);
        }

        // control flow at the end of the program targets main's epilogue
        if (self.plan.labels.contains(self.program.len)) {
            try self.writer.print(".L{d}:\n", .{self.program.len});
        }
        try self.emitRestores(self.plan.regions.getPtr(0).?);
        try self.writer.writeAll(
            \\    xorl %eax, %eax
            \\    leave
            \\    ret
            \\.Lstacc_div0:
            \\    andq $-16, %rsp
            \\    call stacc_rt_div0
            \\.Lstacc_overflow:
            \\    andq $-16, %rsp
            \\    call stacc_rt_overflow
            \\.Lstacc_missing_return:
            \\    andq $-16, %rsp
            \\    call stacc_rt_missing_return
            \\
        );
    }

    /// Returns true when the next instruction was fused into this one.
    fn emitInstruction(self: *Emitter, inst: Instruction, index: usize) !bool {
        const w = self.writer;
        const reg_mode = self.region.mode == .register;
        var buf: [32]u8 = undefined;
        var buf2: [32]u8 = undefined;

        switch (inst) {
            .enter => {
                try w.writeAll("main:\n");
                try self.emitPrologue(self.plan.regions.getPtr(0).?, null);
            },
            .fn_prologue => |f| {
                self.region = self.plan.regions.getPtr(index).?;
                self.fn_end = self.program[index - 1].jump;
                self.depth = 0;
                try w.print("stacc_fn_{s}:\n", .{f.name});
                try self.emitPrologue(self.region, f.num_params);
            },
            .push_const => |v| {
                const bits: i64 = switch (v) {
                    .bool => |b| @intFromBool(b),
                    .i8 => |x| x,
                    .i32 => |x| x,
                    .i64 => |x| x,
                    .f64 => |x| @bitCast(x),
                };
                if (reg_mode) {
                    try w.print("    movabsq ${d}, {s}    # {f}\n", .{ bits, self.push(), v });
                } else {
                    try w.print(
                        \\    movabsq ${d}, %rax    # {f}
                        \\    pushq %rax
                        \\
                    , .{ bits, v });
                }
            },
            .load => |l| {
                const home = self.region.slotLocation(&buf, l.slot);
                if (reg_mode) {
                    try w.print("    movq {s}, {s}    # load {s}\n", .{ home, self.push(), l.name });
                } else {
                    try w.print("    pushq {s}    # load {s}\n", .{ home, l.name });
                }
            },
            .store => |s| {
                const home = self.region.slotLocation(&buf, s.slot);
                if (reg_mode) {
                    try w.print("    movq {s}, {s}    # store {s}\n", .{ self.popTop(), home, s.name });
                } else {
                    try w.print("    popq {s}    # store {s}\n", .{ home, s.name });
                }
            },
            .add, .sub, .mul => |t| {
                if (t == .f64) {
                    const op = switch (inst) {
                        .add => "addsd",
                        .sub => "subsd",
                        .mul => "mulsd",
                        else => unreachable,
                    };
                    if (reg_mode) {
                        const rhs = self.popTop();
                        const lhs = self.top();
                        try w.print(
                            \\    movq {s}, %xmm0
                            \\    movq {s}, %xmm1
                            \\    {s} %xmm1, %xmm0
                            \\    movq %xmm0, {s}
                            \\
                        , .{ lhs, rhs, op, lhs });
                    } else {
                        try w.print(
                            \\    movsd 8(%rsp), %xmm0
                            \\    movsd (%rsp), %xmm1
                            \\    {s} %xmm1, %xmm0
                            \\    addq $8, %rsp
                            \\    movsd %xmm0, (%rsp)
                            \\
                        , .{op});
                    }
                } else {
                    const op = switch (inst) {
                        .add => "addq",
                        .sub => "subq",
                        .mul => "imulq",
                        else => unreachable,
                    };
                    if (reg_mode) {
                        const rhs = self.popTop();
                        const lhs = self.top();
                        if (t == .i64) {
                            try w.print("    {s} {s}, {s}\n", .{ op, rhs, lhs });
                        } else {
                            try w.print(
                                \\    movq {s}, %rax
                                \\    {s} {s}, %rax
                                \\
                            , .{ lhs, op, rhs });
                            try emitNarrowCheck(w, t);
                            try w.print("    movq %rax, {s}\n", .{lhs});
                        }
                    } else {
                        try w.print(
                            \\    popq %rcx
                            \\    popq %rax
                            \\    {s} %rcx, %rax
                            \\
                        , .{op});
                        try emitNarrowCheck(w, t);
                        try w.writeAll("    pushq %rax\n");
                    }
                }
            },
            .div => |t| {
                if (t == .f64) {
                    if (reg_mode) {
                        const rhs = self.popTop();
                        const lhs = self.top();
                        try w.print(
                            \\    movq {s}, %xmm0
                            \\    movq {s}, %xmm1
                            \\    xorpd %xmm2, %xmm2
                            \\    ucomisd %xmm2, %xmm1
                            \\    je .Lstacc_div0
                            \\    divsd %xmm1, %xmm0
                            \\    movq %xmm0, {s}
                            \\
                        , .{ lhs, rhs, lhs });
                    } else {
                        try w.writeAll(
                            \\    movsd 8(%rsp), %xmm0
                            \\    movsd (%rsp), %xmm1
                            \\    xorpd %xmm2, %xmm2
                            \\    ucomisd %xmm2, %xmm1
                            \\    je .Lstacc_div0
                            \\    divsd %xmm1, %xmm0
                            \\    addq $8, %rsp
                            \\    movsd %xmm0, (%rsp)
                            \\
                        );
                    }
                } else {
                    if (reg_mode) {
                        const rhs = self.popTop();
                        const lhs = self.top();
                        try w.print(
                            \\    testq {s}, {s}
                            \\    je .Lstacc_div0
                            \\    movq {s}, %rax
                            \\    cqto
                            \\    idivq {s}
                            \\
                        , .{ rhs, rhs, lhs, rhs });
                        try emitNarrowCheck(w, t);
                        try w.print("    movq %rax, {s}\n", .{lhs});
                    } else {
                        try w.writeAll(
                            \\    popq %rcx
                            \\    popq %rax
                            \\    testq %rcx, %rcx
                            \\    je .Lstacc_div0
                            \\    cqto
                            \\    idivq %rcx
                            \\
                        );
                        try emitNarrowCheck(w, t);
                        try w.writeAll("    pushq %rax\n");
                    }
                }
            },
            .pow => |t| {
                // helper call: flush the pool (a C call clobbers it),
                // reuse the physical-stack sequence, reload survivors
                if (reg_mode) try self.flush();
                if (t == .f64) {
                    try w.writeAll(
                        \\    movsd 8(%rsp), %xmm0
                        \\    movsd (%rsp), %xmm1
                        \\    addq $16, %rsp
                        \\
                    );
                    try self.emitHelperCall("stacc_rt_pow");
                    try w.writeAll("    movq %xmm0, %rax\n");
                } else {
                    try w.writeAll(
                        \\    popq %rsi
                        \\    popq %rdi
                        \\
                    );
                    try self.emitHelperCall("stacc_rt_powi");
                    try emitNarrowCheck(w, t);
                }
                if (reg_mode) {
                    self.depth -= 2;
                    try self.unflush(self.depth);
                    try w.print("    movq %rax, {s}\n", .{self.push()});
                } else {
                    try w.writeAll("    pushq %rax\n");
                }
            },
            .eq, .ne, .lt, .gt, .le, .ge => |t| {
                // fuse comparison + jump_if_false into compare-and-branch
                const fused_target: ?usize = blk: {
                    if (index + 1 >= self.program.len) break :blk null;
                    if (self.plan.labels.contains(index + 1)) break :blk null;
                    break :blk switch (self.program[index + 1]) {
                        .jump_if_false => |target| target,
                        else => null,
                    };
                };
                if (t == .f64) {
                    const swapped = inst == .lt or inst == .le;
                    if (reg_mode) {
                        const rhs = self.popTop();
                        const lhs = self.popTop();
                        try w.print(
                            \\    movq {s}, %xmm0
                            \\    movq {s}, %xmm1
                            \\
                        , .{ lhs, rhs });
                    } else {
                        try w.writeAll(
                            \\    movsd 8(%rsp), %xmm0
                            \\    movsd (%rsp), %xmm1
                            \\    addq $16, %rsp
                            \\
                        );
                    }
                    try w.print("    ucomisd %xmm{d}, %xmm{d}\n", .{
                        @as(u8, if (swapped) 0 else 1),
                        @as(u8, if (swapped) 1 else 0),
                    });
                    if (fused_target) |target| {
                        try w.print("    {s} .L{d}\n", .{ switch (inst) {
                            .eq => "jne",
                            .ne => "je",
                            .gt, .lt => "jbe", // lt uses swapped operands
                            .ge, .le => "jb",
                            else => unreachable,
                        }, target });
                        return true;
                    }
                    try w.print("    {s} %al\n", .{switch (inst) {
                        .eq => "sete",
                        .ne => "setne",
                        .gt, .lt => "seta",
                        .ge, .le => "setae",
                        else => unreachable,
                    }});
                } else {
                    if (reg_mode) {
                        const rhs = self.popTop();
                        const lhs = self.popTop();
                        try w.print("    cmpq {s}, {s}\n", .{ rhs, lhs });
                    } else {
                        try w.writeAll(
                            \\    popq %rcx
                            \\    popq %rax
                            \\    cmpq %rcx, %rax
                            \\
                        );
                    }
                    if (fused_target) |target| {
                        try w.print("    {s} .L{d}\n", .{ switch (inst) {
                            .eq => "jne",
                            .ne => "je",
                            .lt => "jge",
                            .gt => "jle",
                            .le => "jg",
                            .ge => "jl",
                            else => unreachable,
                        }, target });
                        return true;
                    }
                    try w.print("    {s} %al\n", .{switch (inst) {
                        .eq => "sete",
                        .ne => "setne",
                        .lt => "setl",
                        .gt => "setg",
                        .le => "setle",
                        .ge => "setge",
                        else => unreachable,
                    }});
                }
                if (reg_mode) {
                    try w.print("    movzbq %al, {s}\n", .{self.push()});
                } else {
                    try w.writeAll(
                        \\    movzbq %al, %rax
                        \\    pushq %rax
                        \\
                    );
                }
            },
            .jump => |target| {
                if (reg_mode) std.debug.assert(self.depth == 0);
                try w.print("    jmp .L{d}\n", .{target});
            },
            .jump_if_false => |target| {
                if (reg_mode) {
                    const cond = self.popTop();
                    try w.print(
                        \\    testq {s}, {s}
                        \\    jz .L{d}
                        \\
                    , .{ cond, cond, target });
                } else {
                    try w.print(
                        \\    popq %rax
                        \\    testq %rax, %rax
                        \\    jz .L{d}
                        \\
                    , .{target});
                }
            },
            .call => |c| {
                if (reg_mode) try self.flush();
                try w.print("    call stacc_fn_{s}\n", .{c.name});
                if (c.num_params > 0) {
                    try w.print("    addq ${d}, %rsp\n", .{8 * @as(i64, c.num_params)});
                }
                if (reg_mode) {
                    self.depth -= c.num_params;
                    if (c.returns_value) try w.writeAll("    movq %rax, %r11\n");
                    try self.unflush(self.depth);
                    if (c.returns_value) {
                        try w.print("    movq %r11, {s}\n", .{self.push()});
                    }
                } else if (c.returns_value) {
                    try w.writeAll("    pushq %rax\n");
                }
            },
            .ret => |has_value| {
                if (has_value) {
                    if (reg_mode) {
                        std.debug.assert(self.depth == 1);
                        try w.print("    movq {s}, %rax\n", .{self.popTop()});
                    } else {
                        try w.writeAll("    popq %rax\n");
                    }
                }
                try self.emitRestores(self.region);
                try w.writeAll(
                    \\    leave
                    \\    ret
                    \\
                );
            },
            .trap => try w.writeAll("    jmp .Lstacc_missing_return\n"),
            .pop => {
                if (reg_mode) {
                    _ = self.popTop(); // dropping a register value is free
                } else {
                    try w.writeAll("    addq $8, %rsp\n");
                }
            },
            .convert => |t| switch (t) {
                .f64 => {
                    if (reg_mode) {
                        const top_reg = self.top();
                        try w.print(
                            \\    cvtsi2sdq {s}, %xmm0
                            \\    movq %xmm0, {s}
                            \\
                        , .{ top_reg, top_reg });
                    } else {
                        try w.writeAll(
                            \\    popq %rax
                            \\    cvtsi2sdq %rax, %xmm0
                            \\    movq %xmm0, %rax
                            \\    pushq %rax
                            \\
                        );
                    }
                },
                .i8, .i32 => {
                    if (reg_mode) {
                        try w.print("    movq {s}, %rax\n", .{self.top()});
                        try emitNarrowCheck(w, t);
                    } else {
                        try w.writeAll("    popq %rax\n");
                        try emitNarrowCheck(w, t);
                        try w.writeAll("    pushq %rax\n");
                    }
                },
                .i64 => {}, // integers are kept sign-extended; widening is free
                .bool => unreachable, // nothing coerces to bool
            },
            .convert_under => |t| {
                std.debug.assert(t == .f64); // only int -> f64 changes representation
                if (reg_mode) {
                    const under = pool_regs[self.depth - 2];
                    try w.print(
                        \\    cvtsi2sdq {s}, %xmm0
                        \\    movq %xmm0, {s}
                        \\
                    , .{ under, under });
                } else {
                    try w.writeAll(
                        \\    movq 8(%rsp), %rax
                        \\    cvtsi2sdq %rax, %xmm0
                        \\    movsd %xmm0, 8(%rsp)
                        \\
                    );
                }
            },
            .print => |t| {
                if (reg_mode) {
                    std.debug.assert(self.depth == 1);
                    const operand = self.popTop();
                    switch (t) {
                        .f64 => try w.print("    movq {s}, %xmm0\n", .{operand}),
                        else => try w.print("    movq {s}, %rdi\n", .{operand}),
                    }
                } else {
                    switch (t) {
                        .f64 => try w.writeAll(
                            \\    popq %rax
                            \\    movq %rax, %xmm0
                            \\
                        ),
                        else => try w.writeAll("    popq %rdi\n"),
                    }
                }
                try self.emitHelperCall(switch (t) {
                    .f64 => "stacc_rt_print_f64",
                    .bool => "stacc_rt_print_bool",
                    else => "stacc_rt_print_i64",
                });
            },
        }
        _ = &buf2;
        return false;
    }

    // ── virtual stack in registers ────────────────────────────────

    fn push(self: *Emitter) []const u8 {
        std.debug.assert(self.depth < max_pool_depth);
        const reg = pool_regs[self.depth];
        self.depth += 1;
        return reg;
    }

    fn popTop(self: *Emitter) []const u8 {
        std.debug.assert(self.depth >= 1);
        self.depth -= 1;
        return pool_regs[self.depth];
    }

    fn top(self: *Emitter) []const u8 {
        return pool_regs[self.depth - 1];
    }

    /// Materialize the whole virtual stack onto the hardware stack, in
    /// order (needed around calls: the pool is caller-saved, and our
    /// convention takes arguments on the hardware stack anyway).
    fn flush(self: *Emitter) !void {
        var i: usize = 0;
        while (i < self.depth) : (i += 1) {
            try self.writer.print("    pushq {s}\n", .{pool_regs[i]});
        }
    }

    /// Reload the bottom `count` values back into the pool.
    fn unflush(self: *Emitter, count: usize) !void {
        var i = count;
        while (i > 0) {
            i -= 1;
            try self.writer.print("    popq {s}\n", .{pool_regs[i]});
        }
    }

    // ── frames ────────────────────────────────────────────────────

    /// pushq %rbp; save the callee-saved variable registers this frame
    /// uses; allocate memory slots + scratch; zero-init variables; copy
    /// arguments into their homes (num_params != null for functions).
    fn emitPrologue(self: *Emitter, region: *const RegionPlan, num_params: ?u32) !void {
        const w = self.writer;
        try w.writeAll(
            \\    pushq %rbp
            \\    movq %rsp, %rbp
            \\
        );
        var r: u8 = 0;
        while (r < region.used_regs) : (r += 1) {
            try w.print("    pushq {s}\n", .{var_regs[r]});
        }
        try w.print("    subq ${d}, %rsp\n", .{region.frameBytes()});
        // zero-init, matching the VM's zeroed slots
        r = 0;
        while (r < region.used_regs) : (r += 1) {
            try w.print("    xorl {s}, {s}\n", .{ var_regs_32[r], var_regs_32[r] });
        }
        var rank: u32 = 0;
        while (rank < region.mem_count) : (rank += 1) {
            try w.print("    movq $0, {d}(%rbp)\n", .{region.memOffset(rank)});
        }
        if (num_params) |params| {
            var buf: [32]u8 = undefined;
            var i: u32 = 0;
            while (i < params) : (i += 1) {
                const arg_offset = 16 + 8 * (@as(i64, params) - 1 - i);
                const home = region.slotLocation(&buf, i);
                if (region.homes[i] == .reg) {
                    try w.print("    movq {d}(%rbp), {s}\n", .{ arg_offset, home });
                } else {
                    try w.print(
                        \\    movq {d}(%rbp), %rax
                        \\    movq %rax, {s}
                        \\
                    , .{ arg_offset, home });
                }
            }
        }
    }

    /// Restore this frame's callee-saved registers (before leave/ret).
    fn emitRestores(self: *Emitter, region: *const RegionPlan) !void {
        var r: u8 = 0;
        while (r < region.used_regs) : (r += 1) {
            try self.writer.print("    movq {d}(%rbp), {s}\n", .{ -8 * (@as(i64, r) + 1), var_regs[r] });
        }
    }

    /// Call into the C runtime: save %rsp in the frame's hidden scratch
    /// slot, align to 16 bytes as the System V ABI requires, restore.
    fn emitHelperCall(self: *Emitter, helper: []const u8) !void {
        const offset = self.region.scratchOffset();
        try self.writer.print(
            \\    movq %rsp, {d}(%rbp)
            \\    andq $-16, %rsp
            \\    call {s}
            \\    movq {d}(%rbp), %rsp
            \\
        , .{ offset, helper, offset });
    }
};

/// Result is in %rax and must fit `t`; traps on overflow. Integers stay
/// canonically sign-extended, so the check is compare-after-sign-extend.
fn emitNarrowCheck(writer: *std.Io.Writer, t: Type) !void {
    switch (t) {
        .i8 => try writer.writeAll(
            \\    movsbq %al, %rcx
            \\    cmpq %rax, %rcx
            \\    jne .Lstacc_overflow
            \\
        ),
        .i32 => try writer.writeAll(
            \\    movslq %eax, %rcx
            \\    cmpq %rax, %rcx
            \\    jne .Lstacc_overflow
            \\
        ),
        .i64 => {},
        .bool, .f64 => unreachable,
    }
}

// ── tests ──────────────────────────────────────────────────────────

const compile = @import("compiler.zig").compile;

fn emitToText(allocator: std.mem.Allocator, src: []const u8, aw: *std.Io.Writer.Allocating) ![]const u8 {
    const program = try compile(allocator, src);
    defer allocator.free(program);
    try emit(allocator, program, &aw.writer);
    return aw.writer.buffered();
}

test "variables live in callee-saved registers" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const asm_text = try emitToText(allocator, "let x = 1; let y = x + 2; print(y);", &aw);

    // x -> %rbx, y overlaps x -> %r12; no memory traffic for either
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "%rbx") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "xorl %ebx, %ebx") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "# store x") != null);
}

test "comparison fuses with the following branch" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const asm_text = try emitToText(allocator, "let i = 0; while (i < 3) { i = i + 1; }", &aw);

    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jge .L") != null); // fused i < 3
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "setl") == null); // no materialized bool
}

test "non-overlapping variables share a register" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    // a dies before b is declared: same register, optimally
    const asm_text = try emitToText(allocator, "let a = 1; print(a); let b = 2; print(b);", &aw);

    try std.testing.expect(std.mem.indexOf(u8, asm_text, "%r12") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "%rbx") != null);
}

test "deep expressions fall back to hardware-stack mode" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const asm_text = try emitToText(allocator, "print(1 + (2 + (3 + (4 + (5 + (6 + (7 + 8)))))));", &aw);

    try std.testing.expect(std.mem.indexOf(u8, asm_text, "pushq %rax") != null);
}

test "functions get frames and calls flush the pool" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const asm_text = try emitToText(allocator,
        \\fn add(a:i64, b:i64):i64 { return a + b; }
        \\print(add(1, 2) + 3);
    , &aw);

    try std.testing.expect(std.mem.indexOf(u8, asm_text, "stacc_fn_add:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "call stacc_fn_add") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "call stacc_rt_print_i64") != null);
}

test "more live variables than registers spill by furthest end" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    // seven variables all live to the end: two must be memory-resident
    const asm_text = try emitToText(allocator,
        \\let a = 1; let b = 2; let c = 3; let d = 4; let e = 5; let f = 6; let g = 7;
        \\print(a + b + c + d + e + f + g);
    , &aw);

    try std.testing.expect(std.mem.indexOf(u8, asm_text, "(%rbp)    # store") != null); // spilled homes exist
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "%r15") != null); // all five var regs used
}
