# Burn the Forest

**Stacy** (`stacc`) is an experimental statically-typed language built on one refusal: *no trees*. No AST, no IR graph, no visitor passes. Source code goes in one end, typed stack-machine bytecode comes out the other, in a single O(n) forward pass — with the shunting-yard algorithm as the backbone.

```
fn fact(n:i64):i64 {
    if (n < 2) { return 1; }
    return n * fact(n - 1);
}
print(fact(10));    # 3628800
```

Modern infix syntax, type inference, control flow, recursive functions — and at no point does a syntax tree exist.

## The thesis

Compilers conventionally parse into a tree because "you need the structure" — for precedence, for type checking, for code generation. Stacy is an existence proof that for a stack machine you don't:

- **Precedence** is handled by the shunting yard, which *is* a compiler to stack code: its reordering of operators into RPN is exactly bytecode emission order. Each token is pushed and popped at most once — O(n) amortized.
- **Type checking** runs on a compile-time **type stack** that mirrors, instruction by instruction, what the runtime value stack will contain. Every `push_const`/`load` pushes a type, every operator pops two and pushes the unified result — O(1) per instruction, zero extra passes. The compile-time and runtime stacks are structurally identical; that symmetry is the whole trick.
- **Structure** (blocks, loops, functions) needs exactly one technique: *emit a hole, patch it later*. Forward jump targets, loop exits, recursive call frame sizes, and the top-level frame allocation are all backpatched sentinels — O(1) per hole.

Total: compilation is a single forward pass, O(n) time, O(nesting depth) auxiliary memory. Execution is O(1) per instruction (variables are frame-relative slot indices — no name lookups at runtime).

## The language

```
# types: bool, i8, i32, i64, f64 — literals default to i64 (f64 with a dot)
let x:i8 = 5 + 2;          # annotations coerce (range-checked)
let y = x + 3;             # inference: i8 + i64 unifies to i64
let z = 2:f64 / 8;         # typed literals promote the expression
let ok:bool = y > 9;       # comparisons produce bool

if (ok) { print(y); } else { print(0); }

let i = 0;
while (i < 3) {            # conditions must be statically bool
    print(i);
    i = i + 1;
}

fn add(a:i64, b:i64):i64 { # declare before use; recursion works
    return a + b;
}
print(add(y, add(1, 2)));  # calls nest in expressions
```

Everything is checked at compile time by the type stack: undefined variables and functions, float-into-int annotations, non-bool conditions, arity mismatches, arithmetic on bool, chained comparisons, malformed expressions (`1 2`, `1 +`). Integer narrowing stays a runtime range check on the actual value.

## Watch it work

`--verbose` shows the type checker and backpatcher live, then the final bytecode:

```
$ zig build run -- --verbose examples/fib.stacy
── typecheck ──
  i64.load i@3             [i64]
  i64.load n@0             [i64 i64]
  i64.lt                   [bool]
  jump_if_false -> ?       []          <- hole emitted
  ...loop body...
  jump -> 8                []
  (patch @11 -> 25)                    <- hole filled
```

Recursive calls show the second kind of hole — a call site inside the function's own body can't know the final frame size yet:

```
  call fact -> 2 (1 params, 0 slots)   <- placeholder
  ...
  (patch call @12 slots -> 1)          <- patched at fn end
```

The bytecode is fully typed, WASM-style: `i64.const 5`, `i32.add`, `i8.store x@0`, `f64.convert`. The VM never re-derives a type or looks up a name — instructions are self-describing, which keeps the door open for a native backend that lowers instruction-by-instruction (frames, slot offsets, and the calling convention are already decided).

## Build & run

Requires Zig master (0.17-dev).

```sh
zig build test                              # run the test suite
zig build run -- examples/functions.stacy   # run a program
zig build run -- --verbose examples/fib.stacy
```

Runnable programs live in `examples/`. (`main.stacy` is a historical design sketch, not valid syntax.)

## Where the forest tries to grow back

Honest limits of the current single pass, kept deliberately:

- **No all-paths-return analysis** — a value-returning function that falls off the end is a runtime `error.MissingReturn` (`trap`), not a compile error.
- **Flat scoping per frame** — no block scoping or definite-assignment analysis; a variable declared only inside a branch reads as zero-initialized after it. The VM's runtime operand checks turn any static/runtime type divergence into an error rather than UB.
- **Declare before use** — so no mutual recursion (forward declarations would fix this and are single-pass-friendly).
- Optimization passes that reorder across statements would want a graph. Constant folding wouldn't. We'll see how far the fire spreads.

These are the next battlegrounds for the thesis, not counterexamples — WASM validators do all of the above streaming.
