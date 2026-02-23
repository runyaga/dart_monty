# dart_monty_desktop

Part of [dart_monty](https://github.com/runyaga/dart_monty) — pure Dart bindings for [Monty](https://github.com/pydantic/monty), a restricted, sandboxed Python interpreter built in Rust.

[Live Demo](https://runyaga.github.io/dart_monty/) | [GitHub](https://github.com/runyaga/dart_monty) | [Monty](https://github.com/pydantic/monty)

**Flutter plugin** — macOS and Linux desktop implementation of dart_monty using native FFI. Runs the Monty Python interpreter in a background Isolate for non-blocking execution from Flutter desktop apps.

Requires Flutter. This package is not intended for direct use. Import `dart_monty` instead — the federated plugin system selects this package automatically on macOS and Linux.

## How It Works

`DartMontyDesktop` registers itself as the `MontyPlatform` instance via Flutter's `dartPluginClass` mechanism. Execution runs in a background `Isolate` to keep the UI thread responsive, delegating to `dart_monty_ffi` for the actual FFI calls.

## Bundled Binaries

This package vendors pre-built native libraries for supported platforms:

- `macos/libdart_monty_native.dylib`
- `linux/libdart_monty_native.so`

See the [main dart_monty repository](https://github.com/runyaga/dart_monty) for full documentation.
