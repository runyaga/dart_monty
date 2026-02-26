# dart_monty_native

Part of [dart_monty](https://github.com/runyaga/dart_monty) — pure Dart bindings for [Monty](https://github.com/pydantic/monty), a restricted, sandboxed Python interpreter built in Rust.

[Live Demo](https://runyaga.github.io/dart_monty/) | [GitHub](https://github.com/runyaga/dart_monty) | [Monty](https://github.com/pydantic/monty)

<img src="https://raw.githubusercontent.com/runyaga/dart_monty/main/docs/bob.png" alt="Bob" height="18"> This package is co-designed by human and AI — nearly all code is AI-generated.

**Flutter plugin** — native implementation of dart_monty using FFI. Runs the Monty Python interpreter in a background Isolate for non-blocking execution from Flutter apps on macOS, Linux, Windows, iOS, and Android.

Requires Flutter. This package is not intended for direct use. Import `dart_monty` instead — the federated plugin system selects this package automatically on native platforms.

## How It Works

`DartMontyNative` registers itself as the `MontyPlatform` instance via Flutter's `dartPluginClass` mechanism. Execution runs in a background `Isolate` to keep the UI thread responsive, delegating to `dart_monty_ffi` for the actual FFI calls.

## Bundled Binaries

This package vendors pre-built native libraries for supported platforms:

- `macos/libdart_monty_native.dylib`
- `linux/libdart_monty_native.so`

## Usage

This package registers itself automatically. In your Flutter app, use the public API:

```dart
import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

Future<void> main() async {
  // MontyPlatform.instance is set to MontyNative on desktop automatically.
  // MontyNative runs the interpreter in a background Isolate.
  final monty = MontyPlatform.instance;
  final result = await monty.run('2 + 2');
  print(result.value); // 4

  await monty.dispose();
}
```

See the [main dart_monty repository](https://github.com/runyaga/dart_monty) for full documentation.
