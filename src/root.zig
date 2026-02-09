//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const vm = @import("vm/vm.zig");

test "lexer tests" {
    comptime {
        _ = @import("./lexer/lexer.zig");
    }
}

test "old vm tests" {
    comptime {
        _ = @import("vm/vm.zig");
    }
}
