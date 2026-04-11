# Stacy

A fully stack-based typed language with **infix-first** syntax.

## Burn the Forest

Traditional languages build an AST—a forest of trees—and code lives in that structure.

Stacy burns the forest. No AST. No trees. No intermediate representation.

Just stacks flowing through the program.

## The insight: functions are shunting-yard first-class citizens

Parser == shunting-yard. That's it. Write naturally:

```
print(2 + 3 * 4)
```

The parser internally converts to `2 3 + 4 * print` (RPN), executes on the stack, done.

## Type inference has never been this easy

Types flow through the stack exactly like values. Push a value, its type follows. Apply an operator, types transform. Pop a result, type checks.

Since types live on the same stack as values, type inference is just... stack traversal. Trivial. Obvious. No constraint solving, no unification, no mystery.

```
x: int = 10
y: int = 20
print(x + y)
```

The compiler knows `x` is `int`, `y` is `int`, `+` preserves `int`, so `print` receives `int`. Flow, not inference.

## Status

Experimental. What happens when you let go of trees and trust the stack?