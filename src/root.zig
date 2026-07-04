//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const vm = @import("vm/vm.zig");
pub const compiler = @import("compiler/compiler.zig");
pub const value = @import("compiler/value.zig");
pub const codegen_x86 = @import("compiler/codegen_x86.zig");

test "old vm tests" {
    comptime {
        _ = @import("vm/vm.zig");
    }
}

test "lexer tests" {
    comptime {
        _ = @import("./lexer/lexer.zig");
    }
}

test "shunting yard" {
    comptime {
        _ = @import("./parser/shunting_yard.zig");
    }
}

test "compiler tests" {
    comptime {
        _ = @import("./compiler/value.zig");
        _ = @import("./compiler/types.zig");
        _ = @import("./compiler/instruction.zig");
        _ = @import("./compiler/vm.zig");
        _ = @import("./compiler/compiler.zig");
        _ = @import("./compiler/codegen_x86.zig");
    }
}
