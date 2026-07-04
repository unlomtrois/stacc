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
   - `compiler/compiler.zig`: statement-level parser (`let name (:type)? = expr;`, `name = expr;`, `print(expr);`, `if (cond) {} else {}` with `else if` chaining, `while (cond) {}`, `fn name(p:type, ...) [:type] { ... return expr; ... }`, call statements) that runs an inline shunting-yard loop per expression and emits a flat `[]Instruction`. Control flow compiles in the same single pass via **jump backpatching** (`jump_if_false` emitted with an `unresolved` sentinel, patched after the block). Variable names in instructions are slices into the source buffer, which must outlive execution. It also does **static type checking** with a compile-time type stack mirroring the future value stack plus a symbol table: undefined variables, f64-into-int annotations, non-bool conditions, arithmetic on bool, chained comparisons, and unbalanced expressions (`1 2`, `1 +`) are compile errors; int narrowing remains a runtime range check. Comparisons (`==`, `!=`, `<`, `>`, `<=`, `>=`) take numeric operands and produce `bool`; `if`/`while` conditions must be statically `bool`. Note: the statement↔block and expression↔call recursions require the explicit `Compiler.Error` set (Zig cannot infer error sets across recursion). Scoping is flat within a frame (no block scoping); a variable declared only inside a conditional block reads as zero-initialized after it — the VM's runtime operand checks turn any resulting static/runtime type divergence into `error.TypeMismatch` rather than UB.
     - **Functions**: declare-before-use, top-level only (no nesting, no mutual recursion). Bodies compile inline where declared; top-level flow jumps over them. The signature is registered *before* the body compiles, so direct recursion works — recursive call sites get their frame size (`num_slots`) backpatched when the body finalizes (`pending_calls`). Params/locals live in per-call frames (slot 0 = first param); functions cannot see globals (`error.UndefinedVariable`). Args coerce to param types and returns to the return type via `convert` (range-checked at runtime). A value-returning function ends in `trap` (`error.MissingReturn` if reached — there is no all-paths-return analysis). Instruction 0 is always `enter N` (top-level frame size, backpatched at EOF). Expressions are re-entrant (call args nest), so the type stack is base-relative and each expression leaves its result type on it for the consuming statement to pop.
   - `compiler/value.zig`: `Value = union(Type)` with types bool/i8/i32/i64/f64 (integer enum order is widening order — `unify` relies on it; `bool` never unifies and coerces to/from nothing). Coercion: widening silent, int narrowing range-checked (`error.Overflow`), f64→int rejected (`error.TypeMismatch`). Untyped literals default to i64 (f64 with a decimal point); literals can also carry an annotation (`5:i8`, coerced at compile time, so `300:i8` is a compile error); `let` without annotation infers from the expression.
   - `compiler/instruction.zig`: instructions are fully typed at compile time (`i32.add`, `i8.store x@0`, `f64.const 0.5` — the arithmetic ops carry a `Type` payload, load/store carry the resolved variable type plus a flat **slot index**; the name is kept only for disassembly). The VM never re-derives types or looks up names.
   - `compiler/vm.zig`: stack VM with a program-counter loop (`jump`/`jump_if_false` set the pc). Variables live in a contiguous slot stack with a frame base pointer: `enter` allocates the top-level frame, `call` pushes a frame (popping args into its leading slots) and `ret` drops it — the return value stays on the value stack. Call depth is capped (`max_call_depth`, `error.StackOverflow`). Integer arithmetic runs in i64 and narrows to the instruction's type (range-checked); int `/` truncates.
   - `parser/shunting_yard.zig`: a standalone **lazy** shunting-yard infix→postfix iterator (`next() !?Token`) driven by an explicit state machine. The compiler reuses its `getPrecedence`/`isLeftAssoc`; `^` is the only right-associative operator.

`main.stacy` is a design sketch of future syntax (explicit literal casts like `5:i32`) — it does NOT parse with the current compiler; runnable programs live in `examples/`.

Note: the local toolchain is Zig master (0.17-dev), which the code follows (`std.process.Init`-style `main`, `std.Io` writers, `addPassthruArgs()` in build.zig).

Module layout: `src/root.zig` is the library root (module name `stacc`) and also registers each file's tests; `src/main.zig` is the CLI executable that imports the library. New source files with tests must be referenced from `root.zig` for `zig build test` to pick them up.
