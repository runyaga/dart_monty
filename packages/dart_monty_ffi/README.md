# dart_monty_ffi

**Pure Dart** native FFI implementation of dart_monty. Wraps the Rust `libdart_monty_native` shared library via `dart:ffi`, providing synchronous bindings to the Monty sandboxed Python interpreter.

This package has no Flutter dependency and can be used in CLI tools, server-side Dart, or any Dart project. Most apps should import `dart_monty` instead.

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
