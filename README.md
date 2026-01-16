# Simple Stack-based VM language

In this repo I want to experiment with creating a stack-based language. Until now I only had experience with creating AST-based parsers.

Very elementary example:

```
    2 # 2
    3 # 2 3
    4 # 2 3 4
    add # 2 7
    mul # 14
    print

```

- No ast

# plan

✅ implement basics in `main.zig`
✅ - stack via arraylist
✅ - make number opcode, add opcode, print
✅ - make it print

✅ - make tokenizer
✅ - that's it for now