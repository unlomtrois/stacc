//! The language-level type layer: every type is a flat vector of
//! machine scalars occupying consecutive stack slots.
//!
//! One composition operator — concatenation. A struct is a labeled
//! concatenation, a tuple an unlabeled one, and nesting flattens at
//! declaration time into offsets, so type descriptors are never trees:
//! flat arrays with name overlays. Recursive types are unrepresentable
//! by construction (they would flatten forever), which is exactly
//! right for stack-resident values.
//!
//! The bytecode below this layer stays closed: arithmetic and converts
//! speak `value.Type` scalar kinds, loads/stores speak slot + width.
//! Language types erase to layouts at that boundary; the VM and the
//! native backend never see this table.

const std = @import("std");
const value = @import("value.zig");

pub const TypeId = u32;

// builtin ids, in seeding order
pub const bool_id: TypeId = 0;
pub const i8_id: TypeId = 1;
pub const i32_id: TypeId = 2;
pub const i64_id: TypeId = 3;
pub const f64_id: TypeId = 4;
pub const str_id: TypeId = 5;

pub const Field = struct {
    /// "" for tuple elements (accessed positionally)
    name: []const u8,
    type: TypeId,
    /// slot offset from the start of the compound
    offset: u32,
};

pub const TypeInfo = struct {
    /// "" for anonymous tuples
    name: []const u8,
    /// the closed bytecode kind, for scalars (str included: it has
    /// intrinsic instructions even though it is 2 slots wide)
    scalar: ?value.Type = null,
    width: u32,
    /// owned by the table
    fields: []Field = &.{},
};

pub const TypeTable = struct {
    allocator: std.mem.Allocator,
    infos: std.ArrayList(TypeInfo),
    names: std.StringHashMapUnmanaged(TypeId),

    pub fn init(allocator: std.mem.Allocator) !TypeTable {
        var table = TypeTable{ .allocator = allocator, .infos = .empty, .names = .empty };
        errdefer table.deinit();
        // seeding order must match the *_id constants
        try table.seedBuiltin("bool", .bool, 1);
        try table.seedBuiltin("i8", .i8, 1);
        try table.seedBuiltin("i32", .i32, 1);
        try table.seedBuiltin("i64", .i64, 1);
        try table.seedBuiltin("f64", .f64, 1);
        try table.seedBuiltin("str", .str, 2);
        return table;
    }

    fn seedBuiltin(self: *TypeTable, builtin_name: []const u8, scalar: value.Type, w: u32) !void {
        const id: TypeId = @intCast(self.infos.items.len);
        try self.infos.append(self.allocator, .{ .name = builtin_name, .scalar = scalar, .width = w });
        try self.names.put(self.allocator, builtin_name, id);
    }

    pub fn deinit(self: *TypeTable) void {
        for (self.infos.items) |info| {
            if (info.fields.len > 0) self.allocator.free(info.fields);
        }
        self.infos.deinit(self.allocator);
        self.names.deinit(self.allocator);
    }

    pub fn get(self: *const TypeTable, id: TypeId) *const TypeInfo {
        return &self.infos.items[id];
    }

    pub fn width(self: *const TypeTable, id: TypeId) u32 {
        return self.get(id).width;
    }

    pub fn scalarOf(self: *const TypeTable, id: TypeId) ?value.Type {
        return self.get(id).scalar;
    }

    pub fn name(self: *const TypeTable, id: TypeId) []const u8 {
        const info = self.get(id);
        return if (info.name.len > 0) info.name else "tuple";
    }

    pub fn byName(self: *const TypeTable, type_name: []const u8) ?TypeId {
        return self.names.get(type_name);
    }

    pub fn builtinId(scalar: value.Type) TypeId {
        return switch (scalar) {
            .bool => bool_id,
            .i8 => i8_id,
            .i32 => i32_id,
            .i64 => i64_id,
            .f64 => f64_id,
            .str => str_id,
        };
    }

    pub fn fieldByName(self: *const TypeTable, id: TypeId, field_name: []const u8) ?Field {
        for (self.get(id).fields) |field| {
            if (std.mem.eql(u8, field.name, field_name)) return field;
        }
        return null;
    }

    pub fn fieldByIndex(self: *const TypeTable, id: TypeId, index: usize) ?Field {
        const fields = self.get(id).fields;
        if (index >= fields.len) return null;
        return fields[index];
    }

    /// Anonymous tuple of the given element types, deduplicated
    /// structurally (same elements -> same id, so equality stays an
    /// id compare).
    pub fn internTuple(self: *TypeTable, elements: []const TypeId) !TypeId {
        outer: for (self.infos.items, 0..) |info, id| {
            if (info.name.len > 0 or info.scalar != null) continue;
            if (info.fields.len != elements.len) continue;
            for (info.fields, elements) |field, element| {
                if (field.type != element) continue :outer;
            }
            return @intCast(id);
        }
        const fields = try self.allocator.alloc(Field, elements.len);
        errdefer self.allocator.free(fields);
        var offset: u32 = 0;
        for (fields, elements) |*field, element| {
            field.* = .{ .name = "", .type = element, .offset = offset };
            offset += self.width(element);
        }
        const id: TypeId = @intCast(self.infos.items.len);
        try self.infos.append(self.allocator, .{ .name = "", .width = offset, .fields = fields });
        return id;
    }

    /// `type Name = { f:type, ... };` — a nominal type over the same
    /// structural machinery. Nesting flattens here: offsets are slot
    /// offsets, widths are sums.
    pub fn declareStruct(self: *TypeTable, type_name: []const u8, field_names: []const []const u8, field_types: []const TypeId) !TypeId {
        std.debug.assert(field_names.len == field_types.len);
        const fields = try self.allocator.alloc(Field, field_names.len);
        errdefer self.allocator.free(fields);
        var offset: u32 = 0;
        for (fields, field_names, field_types) |*field, fname, ftype| {
            field.* = .{ .name = fname, .type = ftype, .offset = offset };
            offset += self.width(ftype);
        }
        const id: TypeId = @intCast(self.infos.items.len);
        try self.infos.append(self.allocator, .{ .name = type_name, .width = offset, .fields = fields });
        try self.names.put(self.allocator, type_name, id);
        return id;
    }

    /// Register another name for an existing type (`type byte = i8;`).
    pub fn declareAlias(self: *TypeTable, alias: []const u8, target: TypeId) !void {
        try self.names.put(self.allocator, alias, target);
    }

    /// Can a value of type `from` be relabeled as `to` with no code?
    /// True when `from` is an anonymous tuple whose elements match
    /// `to`'s fields exactly (recursively, so nested tuples adopt
    /// nested structs). Pure type-stack event; zero instructions.
    pub fn adoptable(self: *const TypeTable, from: TypeId, to: TypeId) bool {
        if (from == to) return true;
        const from_info = self.get(from);
        if (from_info.name.len > 0 or from_info.scalar != null) return false; // only tuples adopt
        const to_info = self.get(to);
        if (to_info.scalar != null) return false;
        if (from_info.fields.len != to_info.fields.len) return false;
        for (from_info.fields, to_info.fields) |from_field, to_field| {
            if (!self.adoptable(from_field.type, to_field.type)) return false;
        }
        return true;
    }
};

test "builtins, tuples, structs, adoption" {
    var table = try TypeTable.init(std.testing.allocator);
    defer table.deinit();

    try std.testing.expectEqual(i64_id, table.byName("i64").?);
    try std.testing.expectEqual(@as(u32, 2), table.width(str_id));

    const pair = try table.internTuple(&.{ i64_id, f64_id });
    const pair_again = try table.internTuple(&.{ i64_id, f64_id });
    try std.testing.expectEqual(pair, pair_again); // structural dedup
    try std.testing.expectEqual(@as(u32, 2), table.width(pair));

    const point = try table.declareStruct("Point", &.{ "x", "y" }, &.{ i64_id, f64_id });
    try std.testing.expectEqual(@as(u32, 2), table.width(point));
    try std.testing.expectEqual(@as(u32, 1), table.fieldByName(point, "y").?.offset);
    try std.testing.expect(table.adoptable(pair, point));
    try std.testing.expect(!table.adoptable(point, pair)); // nominal does not un-adopt

    // nesting flattens: Line is 4 slots, b at offset 2
    const line = try table.declareStruct("Line", &.{ "a", "b" }, &.{ point, point });
    try std.testing.expectEqual(@as(u32, 4), table.width(line));
    try std.testing.expectEqual(@as(u32, 2), table.fieldByName(line, "b").?.offset);

    // nested tuples adopt nested structs
    const pair_of_pairs = try table.internTuple(&.{ pair, point });
    try std.testing.expect(table.adoptable(pair_of_pairs, line));

    const wrong = try table.internTuple(&.{ f64_id, i64_id });
    try std.testing.expect(!table.adoptable(wrong, point));
}
