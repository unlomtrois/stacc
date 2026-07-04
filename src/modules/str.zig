//! The `str` module: text as two-slot fat values (pointer, length)
//! into static data. Enabled with `use str;`.
//!
//! Provides:
//! - the `str` type name and string literals ("...")
//! - the intrinsic method `s.len()` -> i64
//!
//! Indexing `s[i]`, slicing `s[a..b]` and `==`/`!=` are operators on
//! the str type and become available with it. Backend machinery
//! (push_str/str_* instructions, VM handlers, .rodata emission and the
//! stacc_rt_print_str / stacc_rt_str_eq / stacc_rt_bounds runtime
//! helpers) lives in the compiler backend; this module opens the
//! language surface to it.
//!
//! Users can attach their own methods:
//!     add(str) fn head():i64 { return self[0]; }

const module = @import("module.zig");

pub const definition = module.Module{
    .name = "str",
    .provides_type = .str,
    .provides_string_literals = true,
    .intrinsics = &.{
        .{ .name = "len", .receiver = .str, .return_type = .i64, .intrinsic = .str_len },
    },
};
