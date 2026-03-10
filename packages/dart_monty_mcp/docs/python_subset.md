# Monty Python Subset

Monty is a restricted Python interpreter built in Rust
([pydantic/monty](https://github.com/pydantic/monty)). It does **not**
include the Python standard library -- modules like `math`, `json`, `os`,
`sys`, `re`, etc. are not available.

## Supported features

- Variables and assignments
- Arithmetic (`+`, `-`, `*`, `/`, `//`, `%`, `**`)
- Comparison and logical operators
- f-strings
- Control flow (`if`/`elif`/`else`, `for`, `while`)
- Function definitions and calls
- List comprehensions
- `try`/`except`
- Built-in functions: `range()`, `len()`, `print()`, `str()`, `int()`,
  `float()`, `bool()`, `list()`, `dict()`, `type()`, `isinstance()`
- Host functions (registered via the [host function API](host_functions.md))

## Not supported

- `import` of standard library modules
- Classes
- Generators / `yield`
- Decorators
- `with` statements
- File I/O
- Network access

## print() output capture

Python's `print()` function is intercepted by the interpreter. Output is
captured and included in the result returned to the caller, alongside any
expression result. See [Handling Results and Errors](results_and_errors.md)
for the exact output format.

```python
print("hello")
2 + 2
```

Returns:

```text
hello
4
```

## The host function escape hatch

The host function system is the intended way to add capabilities beyond
what the Python subset provides. Implement functionality in Dart and expose
it to Python as a callable function. See
[Host Functions](host_functions.md) for the full API.
