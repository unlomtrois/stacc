# Zig-native modules

Design notes for the final form of Stacy's module system: modules
written in Stacy, extended with Zig where the language cannot reach.
This is how `str` will eventually be structured, and how a `net`
module becomes possible.

Status: design. Rung 1 below is implemented; rungs 2 and 3 are the
roadmap. Structs and tuples (`feat/type-vectors`) are a prerequisite
for rung 3's interesting cases.

## The module ladder

Every module sits on one of three rungs.

### Rung 1: Zig-defined modules (implemented)

A `Module` value in `src/modules/` gates a slice of the language
surface: a type name, literal forms, intrinsic methods. `use str;`
enables the `str` type, string literals and the intrinsic `s.len()`,
which the compiler lowers directly to the `str_len` instruction.

This rung never goes away. Operations that are about slots and types
themselves (pushing a string literal, slice bounds arithmetic, the fat
pointer layout) are compiler knowledge, not library code. They must be
intrinsics.

### Rung 2: pure-Stacy modules

`use math;` resolves to a source file (`modules/math.stacy`) and the
compiler splices that source in at the point of the `use`. This is
declare-before-use generalized to files: the single pass survives
untouched, total work stays O(sum of sources), and the module's `type`
declarations and `add(type) fn` methods land through machinery that
already exists.

Most of what reads as "the str module" belongs here. `trim`,
`contains`, `starts_with`, `split_at` are expressible today in pure
Stacy over the intrinsic primitives:

```
# modules/str_extras.stacy (illustrative)
use str;

add(str) fn starts_with(prefix:str):bool {
    if (prefix.len() > self.len()) { return false; }
    return self[0..prefix.len()] == prefix;
}
```

### Rung 3: hybrid modules (the final form)

A Stacy module that declares extern functions whose bodies are Zig:

```
# modules/net/net.stacy (illustrative)
use str;

type socket = { fd:i64 };

extern fn net_connect(host:str, port:i64):i64;
extern fn net_send(fd:i64, data:str):i64;

fn connect(host:str, port:i64):socket {
    return (net_connect(host, port),);
}

add(socket) fn send(data:str):i64 {
    return net_send(self.fd, data);
}
```

with `modules/net/net.zig` (or `.c`) providing `net_connect` and
`net_send`. The Stacy half owns the types, the safety rules and the
API shape; the Zig half owns the syscalls.

## The extern mechanism already exists

`stacc_rt_print_str` and `stacc_rt_str_eq` are externs in everything
but name: foreign code called from generated native code with the
System V convention, with the compiler already marshalling Stacy
values into it (a `str` is two registers). Rung 3 is that mechanism
made declarable by modules instead of hardcoded:

- **Native**: `stacc compile` already shells out to `zig cc`; a hybrid
  module contributes its `.zig`/`.c` file to that link line. An
  `extern fn` call lowers to exactly what a runtime helper call is
  today: flush the register pool, marshal slots into argument
  registers, save/realign `%rsp`, call.
- **VM**: a dispatch table mapping extern names to Zig function
  pointers, registered by the module.

Because types are flat slot vectors, every Stacy type is already an
FFI-ready layout: `socket` is one i64, `str` is (pointer, length).
Nothing needs boxing or translation at the boundary.

## Distribution boundary (stated, not hidden)

- First-party hybrid modules compile into `stacc` itself via the
  comptime registry, so they work on both engines.
- Third-party hybrid modules initially work native-only (their Zig
  half joins the `zig cc` link), or require rebuilding `stacc` to
  reach the VM. Dynamic loading (dlopen) could lift this later.
- Pure-Stacy modules (rung 2) work everywhere immediately.

## `use` is a capability manifest

Externs are unreachable without their module, so the `use` list at the
top of a program is its permission manifest. A program that never says
`use net;` provably cannot touch the network, enforced at compile
time, auditable at a glance. The same applies to future `fs`, `time`,
`proc` modules.

Caveat to design around: `use` is transitive (net uses str). The
compiler sees every `use` stream by, so it can print the transitive
capability closure with one flag; that flag should exist before the
first capability-bearing module ships.

## Migration path

1. Extern declarations plus the dispatch table (VM) and link-line
   plumbing (native): generalize the `stacc_rt_*` mechanism.
2. Module source resolution for `use x;`: built-in registry first,
   then `modules/x.stacy`, then project-local. Repeated `use` stays
   idempotent.
3. Namespacing decision: modules currently share the global scope.
   Qualified names (`net.connect`) can wait; collision detection at
   `use` time cannot.
4. Re-house `str`: the intrinsic core stays Zig (rung 1), convenience
   methods move to a `str.stacy` (rung 2). First dogfooded proof that
   the ladder works.
5. `net` as the second module: it forces struct externs, an error
   convention (negative fd versus a future result type), and module
   dependencies. Exactly the stress test the design needs.

## Constraints carried over from the manifesto

- Splicing at `use` keeps compilation a single forward pass; a module
  is compiled where it is enabled, and declare-before-use holds across
  file boundaries.
- The bytecode stays closed. Modules can add types (flat vectors) and
  externs (calls), never new instruction categories; intrinsics that
  need new instructions are rung 1 by definition and live with the
  backend.
- No graphs appear: module resolution is a stack of open files, the
  capability closure is a set accumulated during the same pass.
