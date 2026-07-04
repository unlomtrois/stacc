//! All built-in modules, resolvable by `use <name>;`.

const module = @import("module.zig");

pub const Module = module.Module;
pub const Intrinsic = module.Intrinsic;
pub const IntrinsicMethod = module.IntrinsicMethod;
pub const ExternHandler = module.ExternHandler;
pub const VmExtern = module.VmExtern;

pub const builtin = [_]Module{
    @import("str.zig").definition,
    @import("net.zig").definition,
};

pub fn find(name: []const u8) ?*const Module {
    const std = @import("std");
    for (&builtin) |*m| {
        if (std.mem.eql(u8, m.name, name)) return m;
    }
    return null;
}

/// VM dispatch for `call_extern`.
pub fn findExtern(symbol: []const u8) ?ExternHandler {
    const std = @import("std");
    for (&builtin) |*m| {
        for (m.vm_externs) |ext| {
            if (std.mem.eql(u8, ext.symbol, symbol)) return ext.handler;
        }
    }
    return null;
}

/// The C implementation backing an extern symbol, for the native link.
pub fn nativeImplForSymbol(symbol: []const u8) ?[]const u8 {
    const std = @import("std");
    for (&builtin) |*m| {
        for (m.vm_externs) |ext| {
            if (std.mem.eql(u8, ext.symbol, symbol)) return m.native_impl;
        }
    }
    return null;
}
