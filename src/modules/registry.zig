//! All built-in modules, resolvable by `use <name>;`.

const module = @import("module.zig");

pub const Module = module.Module;
pub const Intrinsic = module.Intrinsic;
pub const IntrinsicMethod = module.IntrinsicMethod;

pub const builtin = [_]Module{
    @import("str.zig").definition,
};

pub fn find(name: []const u8) ?*const Module {
    const std = @import("std");
    for (&builtin) |*m| {
        if (std.mem.eql(u8, m.name, name)) return m;
    }
    return null;
}
