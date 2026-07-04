const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const Type = value.Type;

/// Sentinel jump target used during compilation, before backpatching
/// resolves the real one. Never survives in a successfully compiled program.
pub const unresolved: usize = std.math.maxInt(usize);

/// Every instruction is fully typed at compile time by the type checker.
/// Variable names are slices into the source buffer, which must outlive
/// both compilation and execution.
pub const Instruction = union(enum) {
    push_const: Value,
    load: Load,
    store: Store,
    add: Type,
    sub: Type,
    mul: Type,
    div: Type,
    pow: Type,
    /// comparisons are typed by their operand type and push a bool
    eq: Type,
    ne: Type,
    lt: Type,
    gt: Type,
    le: Type,
    ge: Type,
    /// unconditional jump to an absolute instruction index
    jump: usize,
    /// pop a bool; jump to the absolute index when it is false
    jump_if_false: usize,
    /// allocate the top-level frame (always instruction 0, backpatched
    /// with the final slot count at end of compilation)
    enter: u32,
    /// marks a function entry; a no-op in the VM, but carries the frame
    /// shape that native codegen lowers into a prologue. num_slots is
    /// backpatched when the body finishes compiling.
    fn_prologue: FnPrologue,
    /// pop the arguments into a fresh frame and jump to the function body
    call: Call,
    /// drop the current frame and resume at the saved pc; a return value,
    /// if any (`true`), stays on the value stack
    ret: bool,
    /// falling off the end of a value-returning function
    trap,
    /// discard the top of the value stack (unused call result)
    pop,
    /// pop, coerce to the given type (range-checked), push
    convert: Type,
    /// like convert, but for the value one below the top (left operand
    /// of a binary op that unified to f64)
    convert_under: Type,
    /// pop and print a value of the statically known type
    print: Type,
    /// push a str: pointer to the bytes, then the length (2 slots).
    /// The slice points into the source buffer; native codegen copies
    /// the bytes into .rodata.
    push_str: []const u8,
    /// [ptr][len] -> [len]
    str_len,
    /// [ptr][len][idx] -> [byte as i64], bounds-checked
    str_index,
    /// [ptr][len][a][b] -> [ptr+a][b-a], checked 0 <= a <= b <= len
    str_slice,
    /// [ptr][len][ptr][len] -> [bool], content comparison
    str_eq,
    str_ne,

    pub const FnPrologue = struct {
        name: []const u8,
        num_params: u32,
        num_slots: u32,
        returns_value: bool,
    };

    pub const Call = struct {
        /// callee name, kept only for disassembly
        name: []const u8,
        /// entry pc of the function body
        target: usize,
        num_params: u32,
        /// full frame size (params + locals); backpatched for recursive
        /// call sites emitted before the body finished compiling
        num_slots: u32,
        returns_value: bool,
    };

    pub const Load = struct {
        /// original variable name, kept only for disassembly
        name: []const u8,
        /// index into the VM's flat slot array
        slot: u32,
        /// static type of the variable being loaded
        type: Type,
    };

    pub const Store = struct {
        /// original variable name, kept only for disassembly
        name: []const u8,
        /// index into the VM's flat slot array
        slot: u32,
        /// resolved type: the declared annotation, or the inferred
        /// expression type. The VM coerces the stored value to it
        /// (range-checked when narrowing).
        type: Type,
    };

    /// `{f}` formatter, e.g. `i64.const 5`, `i32.add`, `i8.store x@0`
    pub fn format(self: Instruction, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .push_const => |v| {
                try writer.print("{s}.const ", .{@tagName(v.getType())});
                try v.write(writer);
            },
            .load => |l| try writer.print("{s}.load {s}@{d}", .{ @tagName(l.type), l.name, l.slot }),
            .store => |s| try writer.print("{s}.store {s}@{d}", .{ @tagName(s.type), s.name, s.slot }),
            .print => |t| try writer.print("{s}.print", .{@tagName(t)}),
            .enter => |n| try writer.print("enter {d}", .{n}),
            .fn_prologue => |f| try writer.print("fn {s} ({d} params, {d} slots)", .{ f.name, f.num_params, f.num_slots }),
            .call => |c| try writer.print("call {s} -> {d} ({d} params, {d} slots)", .{ c.name, c.target, c.num_params, c.num_slots }),
            .ret => |has_value| try writer.writeAll(if (has_value) "ret value" else "ret"),
            .trap => try writer.writeAll("trap"),
            .pop => try writer.writeAll("pop"),
            .convert => |t| try writer.print("{s}.convert", .{@tagName(t)}),
            .convert_under => |t| try writer.print("{s}.convert_under", .{@tagName(t)}),
            .push_str => |bytes| try writer.print("str.const \"{s}\"", .{bytes}),
            .str_len => try writer.writeAll("str.len"),
            .str_index => try writer.writeAll("str.index"),
            .str_slice => try writer.writeAll("str.slice"),
            .str_eq => try writer.writeAll("str.eq"),
            .str_ne => try writer.writeAll("str.ne"),
            inline .jump, .jump_if_false => |target, op| {
                if (target == unresolved) {
                    try writer.print("{s} -> ?", .{@tagName(op)});
                } else {
                    try writer.print("{s} -> {d}", .{ @tagName(op), target });
                }
            },
            inline .add, .sub, .mul, .div, .pow, .eq, .ne, .lt, .gt, .le, .ge => |t, op| try writer.print("{s}.{s}", .{ @tagName(t), @tagName(op) }),
        }
    }
};
