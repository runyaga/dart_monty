# dart_monty_ffi

Part of [dart_monty](https://github.com/runyaga/dart_monty) — pure Dart bindings for [Monty](https://github.com/pydantic/monty), a restricted, sandboxed Python interpreter built in Rust.

[Live Demo](https://runyaga.github.io/dart_monty/) | [GitHub](https://github.com/runyaga/dart_monty) | [Monty](https://github.com/pydantic/monty)

<img src="https://raw.githubusercontent.com/runyaga/dart_monty/main/docs/bob.png" alt="Bob" height="18"> This package is co-designed by human and AI — nearly all code is AI-generated.

**Pure Dart** native FFI implementation of dart_monty. Wraps the Rust `libdart_monty_native` shared library via `dart:ffi`, providing synchronous bindings to the Monty sandboxed Python interpreter.

This package has no Flutter dependency and can be used in CLI tools, server-side Dart, or any Dart project.

- **Flutter apps** should import `dart_monty` instead — the federated plugin selects the correct backend automatically.
- **Pure Dart projects** (CLI, server) can depend on this package directly to run Python via the native Rust library.

## Architecture

```text
Dart -> NativeBindingsFfi (dart:ffi)
  -> DynamicLibrary.open(libdart_monty_native)
    -> 17 extern "C" functions (Rust)
```

## Key Classes

| Class | Description |
|-------|-------------|
| `NativeBindings` | Abstract interface over the 17 native C functions |
| `NativeBindingsFfi` | Concrete FFI implementation with pointer lifecycle management |
| `MontyFfi` | `MontyPlatform` implementation using `NativeBindings` |
| `NativeLibraryLoader` | Platform-aware library path resolution |

See the [main dart_monty repository](https://github.com/runyaga/dart_monty) for full documentation.
