const value = @import("value.zig");
const Value = value.Value;
const Type = value.Type;

/// Variable names are slices into the source buffer, which must outlive
/// both compilation and execution.
pub const Instruction = union(enum) {
    push_const: Value,
    load: []const u8,
    store: Store,
    add,
    sub,
    mul,
    div,
    pow,
    print,

    pub const Store = struct {
        name: []const u8,
        /// Type from a `let name:type = ...` annotation; null means infer.
        declared_type: ?Type,
    };
};
