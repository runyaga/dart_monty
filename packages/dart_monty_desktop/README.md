# dart_monty_desktop

macOS and Linux desktop implementation of dart_monty using native FFI. Runs the Monty Python interpreter in a background Isolate for non-blocking execution from Flutter desktop apps.

This package is not intended for direct use. Import `dart_monty` instead — the federated plugin system selects this package automatically on macOS and Linux.

## How It Works

`DartMontyDesktop` registers itself as the `MontyPlatform` instance via Flutter's `dartPluginClass` mechanism. Execution runs in a background `Isolate` to keep the UI thread responsive, delegating to `dart_monty_ffi` for the actual FFI calls.

## Bundled Binaries

This package vendors pre-built native libraries for supported platforms:

- `macos/libdart_monty_native.dylib`
- `linux/libdart_monty_native.so`

See the [main dart_monty repository](https://github.com/runyaga/dart_monty) for full documentation.
