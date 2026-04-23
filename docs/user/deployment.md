# Deployment and Bundling

This guide covers how to bundle and deploy `dart_monty` for both web (WASM) and native (FFI) applications.

## Web (WASM)

When you build a web application that uses `dart_monty`, you need to ensure that the necessary JavaScript and WASM assets are available to your application at runtime.

### Core Packages

- **`dart_monty_core`**: This package provides the core WASM backend. It includes the JavaScript bridge and the WASM binary.
- **`dart_monty`**: This is the high-level API that you use in your application. It depends on `dart_monty_core`.

### Bundling

When you compile your Dart web application, you need to copy the following assets from the `dart_monty_core` package to your web application's output directory:

- `packages/dart_monty_core/assets/dart_monty_core_bridge.js`
- `packages/dart_monty_core/assets/dart_monty_core_worker.js`
- `packages/dart_monty_core/assets/dart_monty_native.wasm`

These files must be served from the same directory as your application's main JavaScript file. Most web development servers will do this automatically if you place them in your `web` or `public` directory.

Here is an example of how you might copy these files in a shell script:

```bash
cp packages/dart_monty_core/assets/dart_monty_core_bridge.js web/
cp packages/dart_monty_core/assets/dart_monty_core_worker.js web/
cp packages/dart_monty_core/assets/dart_monty_native.wasm web/
```

### Dependencies

The WASM implementation of `dart_monty` runs in a Web Worker. The `dart_monty_core_bridge.js` file handles communication between your main application and the `dart_monty_core_worker.js`, which in turn loads and runs the `dart_monty_native.wasm` file.

The good news is that you don't need to configure any special server headers like COOP/COEP. The `wasm32-wasip1` target allows `dart_monty` to run without these restrictions.

## Native (FFI)

When you build a native application with `dart_monty` (for example, a command-line application or a Flutter desktop app), you are using the FFI (Foreign Function Interface) to call into a native library.

### Native Library

The native library is a `.dylib` file on macOS, a `.so` file on Linux, or a `.dll` file on Windows. This library is built from Rust source code.

### Bundling

When you build your application using `dart compile`, you need to ensure that the native library is placed in the same directory as your compiled executable.

For example, if you compile your application to `build/my_app`, you need to copy the native library to `build/libdart_monty_native.dylib` (on macOS).

The `dart_monty_ffi` package uses a build hook to automatically download or build the correct native library for your platform. You can find the library in the `.dart_tool` directory of your project.

### AOT Compilation

When you create an AOT (Ahead-Of-Time) compiled binary of your application, you must manually copy the dynamic library to be alongside your executable. The Dart AOT runtime does not bundle dynamic libraries.

For example, on Linux, if your application is `my_app`, you would have a file structure like this:

```
/path/to/your/app/
├── my_app
└── libdart_monty_native.so
```

You can automate this copying process as part of your build script.
