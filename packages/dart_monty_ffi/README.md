# dart_monty_ffi

Part of [dart_monty](https://github.com/runyaga/dart_monty) — pure Dart bindings for [Monty](https://github.com/pydantic/monty), a restricted, sandboxed Python interpreter built in Rust.

[Live Demo](https://runyaga.github.io/dart_monty/) | [GitHub](https://github.com/runyaga/dart_monty) | [Monty](https://github.com/pydantic/monty)

<img src="https://raw.githubusercontent.com/runyaga/dart_monty/main/docs/bob.png" alt="Bob" height="18"> This package is co-designed by human and AI — nearly all code is AI-generated.

**Pure Dart** native FFI implementation of dart_monty. Wraps the Rust `libdart_monty_native` shared library via `dart:ffi`, providing synchronous bindings to the Monty sandboxed Python interpreter.

This package has no Flutter dependency and can be used in CLI tools, server-side Dart, or any Dart project.

- **Most users** should import `dart_monty` instead — it selects the native or web backend at compile time via conditional imports.
- **Direct usage** is for projects that need explicit control over the backend (e.g. custom bindings, testing).

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
| `MontyNative` | Isolate-based wrapper — runs FFI calls off the main thread |
| `NativeIsolateBindings` | Abstract interface for the Isolate bridge |
| `NativeIsolateBindingsImpl` | Concrete Isolate bridge implementation |
| `NativeLibraryLoader` | Platform-aware library path resolution |

`MontyNative` and the Isolate bridge classes were moved here from `dart_monty_native` in 0.7.0, making the Isolate bridge usable without Flutter (CLI tools, server-side Dart).

### Cancellation

`cancel()` sets an atomic flag in the Monty bytecode loop via FFI, causing the interpreter to abort cooperatively. `terminate()` adds a 5-second timeout with zombie tracking for stuck FFI calls.

## Usage

```dart
import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

Future<void> main() async {
  final monty = MontyFfi();

  // Simple execution
  final result = await monty.run('2 + 2');
  print(result.value); // 4

  // External function dispatch — Python pauses when it calls fetch().
  var progress = await monty.start(
    'fetch("https://example.com")',
    externalFunctions: ['fetch'],
  );
  if (progress is MontyPending) {
    // Your app handles the call (HTTP, DB, etc.) and feeds the
    // return value back to Python. Here we just return a mock result.
    progress = await monty.resume({'status': 'ok'});
  }
  final complete = progress as MontyComplete;
  print(complete.result.value); // {status: ok}

  await monty.dispose();
}
```

See the [main dart_monty repository](https://github.com/runyaga/dart_monty) for full documentation.
