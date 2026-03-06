# dmonty — Monty Python CLI

Standalone CLI for the Monty sandboxed Python interpreter. Run Python
scripts, evaluate expressions, or drop into an interactive REPL — all
powered by Dart + Rust FFI.

## Setup

### Build the native library

```bash
cd native && cargo build --release
```

This produces `native/target/release/libdart_monty_native.dylib` (macOS),
`.so` (Linux), or `.dll` (Windows).

### Compile the CLI binary

```bash
cd packages/monty_cli
dart compile exe bin/dmonty.dart -o build/dmonty
cp ../../native/target/release/libdart_monty_native.dylib build/
```

The compiled binary auto-detects the dylib when it's in the same directory.

### Run without compiling

```bash
cd packages/monty_cli
dart run bin/dmonty.dart --library-path ../../native/target/release/libdart_monty_native.dylib <command>
```

## Commands

### `repl` — Interactive REPL

```bash
dmonty repl
```

Multi-turn REPL with persistent Python state. Variables defined in one
line carry over to subsequent lines.

```text
monty> x = 42
monty> x * 2
84
monty> name = "Bob"
monty> f"hello {name}, x={x}"
hello Bob, x=42
monty> /state
  x = 42
  name = Bob
monty> /quit
```

**Slash commands:**

| Command | Description |
|---------|-------------|
| `/help` | Show available commands |
| `/state` | Show all persisted variables |
| `/clear` | Clear persisted state |
| `/quit` | Exit the REPL |

### `-p` / `--prompt` — Expression pipeline

Execute one or more Python expressions in a single session. State carries
across `-p` flags, and only the last expression's result is printed.

```bash
# Single expression
dmonty -p "2 ** 10"
# 1024

# Multi-expression pipeline
dmonty -p "x = 42" -p "y = x * 2" -p "x + y"
# 126

# JSON output
dmonty -p "x = [1, 2, 3]" -p "x" --json
```

### `eval` — Single expression

```bash
dmonty eval "2 + 2"
# 4

dmonty eval "[i * i for i in range(5)]"
# [0, 1, 4, 9, 16]
```

### `run` — Execute a file

```bash
dmonty run script.py
```

### `demo` — Host function dispatch

Run Python code with built-in host functions (for testing the
start/pending/resume dispatch loop).

```bash
dmonty demo                # Run built-in demo script
dmonty demo -s "log('hi')" # Run custom code with host functions
dmonty demo --list         # List available host functions
```

## Options

All commands support:

| Option | Description |
|--------|-------------|
| `--library-path <path>` | Path to the native Monty shared library |
| `--json` | Output results as JSON |
| `-v` / `--verbose` | Show resource usage stats on stderr |
| `--timeout <ms>` | Execution timeout in milliseconds |
| `--memory <bytes>` | Memory limit in bytes |
| `--stack-depth <n>` | Maximum stack depth |

### Library resolution

The native library is resolved in this order:

1. `--library-path` flag
2. `MONTY_LIBRARY_PATH` environment variable
3. Co-located dylib next to the compiled binary
4. System default `DynamicLibrary.open` search path

## Monty Python Subset

Monty is a sandboxed subset of Python. What works:

- Variables, assignments, f-strings
- `def` functions with default args, closures, first-class refs
- `if`/`elif`/`else`, `while`, `for`, `break`
- `list`, `dict`, `tuple`, `str`, `int`, `float`, `bool`
- `dict.get(key, default)`, `"key" in dict`, `dict` iteration
- List comprehensions, dict comprehensions
- `len()`, `range()`, `sum()`, `str()`, `int()`
- String methods: `.upper()`, `.startswith()`, `.split()`

What doesn't work:

- `import` (no standard library)
- Classes
- `x = y = 0` (chained assignment)
- `async`/`await`
- Exceptions (`try`/`except`)
