# Burn the Forest

**Stacy** (`stacc`) is an experimental statically-typed language built around one constraint: no trees. No AST, no IR graph, no visitor passes. Source code compiles to typed stack-machine bytecode in a single O(n) forward pass, using the shunting-yard algorithm as the backbone.

```
fn fact(n:i64):i64 {
    if (n < 2) { return 1; }
    return n * fact(n - 1);
}
print(fact(10));    # 3628800
```

Infix syntax, type inference, control flow and recursive functions, without a syntax tree at any point.

## The idea

Compilers usually parse into a tree on the assumption that later stages need the structure: precedence, type checking, code generation. For a stack machine that assumption turns out to be unnecessary:

- **Precedence.** The shunting yard already produces operators in RPN order, which is the same as bytecode emission order. Each token is pushed and popped at most once, so this is O(n) amortized.
- **Type checking** runs on a compile-time type stack that mirrors, instruction by instruction, what the runtime value stack will contain. Every `push_const` and `load` pushes a type; every operator pops two and pushes the unified result. O(1) per instruction, no extra passes. The compile-time and runtime stacks have the same shape, which is what makes this work.
- **Structure** (blocks, loops, functions) needs one technique: emit a placeholder, patch it later. Forward jump targets, loop exits, recursive call frame sizes and the top-level frame allocation are all backpatched. O(1) per patch.

Compilation is a single forward pass: O(n) time, O(nesting depth) auxiliary memory. Execution is O(1) per instruction; variables are frame-relative slot indices, so there are no name lookups at runtime.

## The language

```
# types: bool, i8, i32, i64, f64. Literals default to i64 (f64 with a dot)
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

Checked at compile time: undefined variables and functions, float-into-int annotations, non-bool conditions, arity mismatches, arithmetic on bool, chained comparisons, malformed expressions (`1 2`, `1 +`). Integer narrowing stays a runtime range check on the actual value.

## Verbose output

`--verbose` traces the type checker and the backpatcher, then prints the final bytecode:

```
$ zig build run -- --verbose examples/fib.stacy
── typecheck ──
  i64.load i@3             [i64]
  i64.load n@0             [i64 i64]
  i64.lt                   [bool]
  jump_if_false -> ?       []          <- placeholder emitted
  ...loop body...
  jump -> 8                []
  (patch @11 -> 25)                    <- placeholder resolved
```

Recursive calls show the second kind of placeholder. A call site inside the function's own body cannot know the final frame size yet:

```
  call fact -> 2 (1 params, 0 slots)   <- placeholder
  ...
  (patch call @12 slots -> 1)          <- patched at fn end
```

The bytecode is fully typed, in the style of WASM: `i64.const 5`, `i32.add`, `i8.store x@0`, `f64.convert`. The VM never re-derives a type or looks up a name. Since instructions are self-describing and the frame layout and calling convention are already fixed, a future native backend could lower them instruction by instruction.

## Build & run

Requires Zig master (0.17-dev).

```sh
zig build test                              # run the test suite
zig build run -- examples/functions.stacy   # run a program (interpreter)
zig build run -- --verbose examples/fib.stacy
zig build run -- --native examples/fib.stacy -o fib   # compile to a native executable
./fib
```

`--native` lowers the bytecode to x86-64 assembly (`fib.s`, readable) and assembles/links it with `zig cc`, so no extra toolchain is needed. The typed instructions map directly: `i64.add` becomes an `addq`, `call fact` a real `call` with a real stack frame. Recursive `fib(30)` runs about 200x faster than the interpreter.

The backend does register allocation without ever building an interference graph, in two linear passes. A prescan over the flat bytecode computes each variable's live interval (first to last access, clamped to enclosing loop brackets: anything touched inside a loop is live for the whole loop, so liveness is bracket matching rather than dataflow). Because Stacy declares before use and its control flow is structured, those intervals form an interval graph whose perfect elimination order is declaration order, so greedy assignment to the callee-saved registers is an optimal coloring; when more than five variables overlap, the interval ending furthest is demoted to memory (Belady's rule applied to whole intervals). Expression temporaries need no analysis at all: the shunting yard's stack discipline means virtual stack depth is itself an optimal coloring, so depth indexes a fixed pool of caller-saved registers, with a per-frame fallback to hardware-stack mode for expressions deeper than the pool. Comparisons fuse with the branch that consumes them. The result for a typical counting loop is a body with zero memory accesses:

```asm
.L5:
    movq %rbx, %rsi          # i
    movabsq $100000000, %rdi
    cmpq %rdi, %rsi
    jge .L22                 # fused i < N
    ...
    movq %rsi, %r12          # acc
    jmp .L5
```

Runnable programs live in `examples/`. (`main.stacy` is an old design sketch, not valid syntax.)

## Current limits

Consequences of the single pass, kept deliberately:

- No all-paths-return analysis. A value-returning function that falls off the end is a runtime `error.MissingReturn` (`trap`), not a compile error.
- Flat scoping per frame. No block scoping or definite-assignment analysis; a variable declared only inside a branch reads as zero-initialized after it. The VM checks operand types at runtime, so a static/runtime type divergence is an error rather than UB.
- Declare before use, so no mutual recursion. Forward declarations would fix this and fit the single pass.
- Optimization passes that reorder across statements would want a graph. Constant folding would not.

WASM validators handle all of the above while streaming, so none of these look fundamental.
