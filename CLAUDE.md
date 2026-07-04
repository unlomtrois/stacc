# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`stacc` is an experimental stack-based VM language written in Zig (minimum Zig 0.15.1). The goal is a language where programs push values onto a stack and apply operators, e.g. `2 3 4 add mul print` (see README.md). Source files use the `.stacy` extension.

## Commands

- Build: `zig build`
- Run: `zig build run -- examples/basic.stacy` (the CLI takes a `.stacy` file path)
- Run all tests: `zig build test`
- Test a single file: `zig test src/vm/vm.zig` (or any other file; tests live inline in source files)

## Architecture

There are two coexisting implementations:

1. **Old VM** (`src/vm/`) — the original legacy path, kept for reference. `tokenizer.zig` produces value/op tokens from postfix (RPN) input; `executor.zig` evaluates them on an `f64` stack. No longer wired to the CLI. Integration tests live in `src/vm/vm.zig`.

2. **Current pipeline** (`src/lexer/` → `src/compiler/`), wired into `src/main.zig`, which reads a `.stacy` file and runs `compiler.interpret`:
   - `lexer/lexer.zig`: UTF-8-aware streaming lexer (`Lexer.next() ?Token`), handles BOM, keywords (`let`), operators, float literals, `:` type annotations, braces/brackets. Tokens (`lexer/token.zig`) are spans (`start`/`end` byte offsets + tag) into the source.
   - `compiler/compiler.zig`: statement-level parser (`let name (:type)? = expr;`, `print(expr);`) that runs an inline shunting-yard loop per expression and emits a flat `[]Instruction`. Variable names in instructions are slices into the source buffer, which must outlive execution. It also does **static type checking** with a compile-time type stack mirroring the future value stack plus a variable-type table: undefined variables, f64-into-int annotations, and unbalanced expressions (`1 2`, `1 +`) are compile errors (`error.UndefinedVariable`, `error.TypeMismatch`, `error.InvalidExpression`); int narrowing remains a runtime range check.
   - `compiler/value.zig`: `Value = union(Type)` with types i8/i32/i64/f64 (enum declared in widening order — `unify` relies on it). Coercion: widening silent, int narrowing range-checked (`error.Overflow`), f64→int rejected (`error.TypeMismatch`). Untyped literals default to i64 (f64 with a decimal point); literals can also carry an annotation (`5:i8`, coerced at compile time, so `300:i8` is a compile error); `let` without annotation infers from the expression.
   - `compiler/vm.zig`: stack VM executing instructions with a variable table; integer arithmetic runs in i64 and narrows back to the unified operand type; int `/` truncates.
   - `parser/shunting_yard.zig`: a standalone **lazy** shunting-yard infix→postfix iterator (`next() !?Token`) driven by an explicit state machine. The compiler reuses its `getPrecedence`/`isLeftAssoc`; `^` is the only right-associative operator.

`main.stacy` is a design sketch of future syntax (explicit literal casts like `5:i32`) — it does NOT parse with the current compiler; runnable programs live in `examples/`.

Note: the local toolchain is Zig master (0.17-dev), which the code follows (`std.process.Init`-style `main`, `std.Io` writers, `addPassthruArgs()` in build.zig).

Module layout: `src/root.zig` is the library root (module name `stacc`) and also registers each file's tests; `src/main.zig` is the CLI executable that imports the library. New source files with tests must be referenced from `root.zig` for `zig build test` to pick them up.
