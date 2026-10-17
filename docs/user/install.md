# Installation

`dart_monty` and `dart_monty_core` version `0.110.0-dev.2` resolve from
their Git tags. `dart_monty_core` is not available from pub.dev, and
`dependency_overrides` in a dependency's pubspec do not apply to your package,
so the root pubspec overrides the core source:

```yaml
dependencies:
  dart_monty:
    git:
      url: https://github.com/runyaga/dart_monty.git
      ref: v0.110.0-dev.2

dependency_overrides:
  dart_monty_core:
    git:
      url: https://github.com/runyaga/dart_monty_core.git
      ref: v0.110.0-dev.2
```

A package that imports core names directly also lists
`dart_monty_core: ^0.110.0-dev.2` under `dependencies`.

Run `dart pub get` after editing `pubspec.yaml`.

Import `package:dart_monty/dart_monty.dart` for the runtime, host functions,
`OSAccess`, and the value types `MontyBool`, `MontyInt`, `MontyFloat`,
`MontyString`, `MontyList`, `MontyTuple`, `MontyDict`, and `MontyBytes`.
Import `package:dart_monty_core/dart_monty_core.dart` for other core names,
including `MemoryFile`, `MontyPath`, snapshots, and type-check types.

For local worktree development, use `path:` dependencies for both packages.

## Platform Requirements

### Native (Desktop, Server, and Flutter)

A native program needs a worker executable. Opt in to the build hook in the
root pubspec and build with `dart build cli`:

```yaml
hooks:
  user_defines:
    dart_monty_core:
      build_worker: true
```

Call `runMontyWorkerIfChild(args)` from `package:dart_monty_core/dart_monty_core.dart`
as the first statement of `main`. The hook compiles the worker library with a
stable Rust toolchain (`cargo` and `rustc`) and a C linker. Alternatively pass
the path of a prebuilt worker executable as `workerLocation` to `Monty.start`.

### Flutter Web

Include the assets declared by core when bundling a Flutter application:

```yaml
flutter:
  assets:
    - package: dart_monty_core
```

The worker loads when a pool starts. A web deployment needs these headers for
`SharedArrayBuffer`:

- `Cross-Origin-Opener-Policy: same-origin`
- `Cross-Origin-Embedder-Policy: require-corp`

### Plain Dart web

Serve `dart_monty_core_worker.js` and `dart_monty_core_worker.wasm` from
core's `lib/assets` directory at `packages/dart_monty_core/assets`. A pool can
also receive that directory URL through `Monty.start(workerLocation: ...)`.
