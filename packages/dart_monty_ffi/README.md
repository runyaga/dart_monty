# dart_monty_ffi

Native FFI implementation of dart_monty for desktop and mobile platforms. Wraps the Rust `libdart_monty_native` shared library via `dart:ffi`, providing synchronous bindings to the Monty sandboxed Python interpreter.

This package is not intended for direct use. Import `dart_monty` instead.

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
