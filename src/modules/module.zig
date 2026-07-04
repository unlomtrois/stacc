//! Built-in modules: optional language features enabled by `use name;`.
//!
//! A module owns a piece of the language surface — a type name, literal
//! forms, and intrinsic methods on its type. The backend (bytecode
//! instructions, VM handlers, native lowerings) stays in the backend;
//! the module decides whether the front door to them is open.

const value = @import("../compiler/value.zig");

/// Compiler-implemented method bodies. The compiler lowers a call to
/// one of these directly to typed instructions instead of a `call`.
pub const Intrinsic = enum {
    str_len,
};

pub const IntrinsicMethod = struct {
    name: []const u8,
    receiver: value.Type,
    return_type: value.Type,
    intrinsic: Intrinsic,
};

pub const Module = struct {
    name: []const u8,
    /// a type name this module makes resolvable
    provides_type: ?value.Type = null,
    /// whether string literals require this module
    provides_string_literals: bool = false,
    intrinsics: []const IntrinsicMethod = &.{},
};
