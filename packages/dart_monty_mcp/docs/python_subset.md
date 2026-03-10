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

The host function system is the intended escape hatch: implement
capabilities in Dart and expose them to Python.
