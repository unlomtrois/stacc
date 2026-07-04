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

/// VM-side implementation of an `extern fn`. Arguments arrive as raw
/// stack slots in declaration order; the handler fills `results` and
/// returns how many slots it produced (must match the declared return
/// width). Handlers are infallible: failures are reported through
/// values (e.g. a negative fd), keeping both engines' behavior
/// identical.
pub const ExternHandler = *const fn (args: []const value.Value, results: *[2]value.Value) u32;

pub const VmExtern = struct {
    symbol: []const u8,
    handler: ExternHandler,
};

pub const Module = struct {
    name: []const u8,
    /// a type name this module makes resolvable
    provides_type: ?value.Type = null,
    /// whether string literals require this module
    provides_string_literals: bool = false,
    intrinsics: []const IntrinsicMethod = &.{},
    /// rung 2/3: Stacy source spliced into the token stream at `use`
    stacy_source: ?[]const u8 = null,
    /// rung 3: C source providing the module's extern symbols, linked
    /// into native executables that use the module
    native_impl: ?[]const u8 = null,
    /// rung 3: the same extern symbols for the VM
    vm_externs: []const VmExtern = &.{},
};
