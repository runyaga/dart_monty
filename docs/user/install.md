# Installation

`dart_monty` and `dart_monty_core` resolve from their Git tags.
`dart_monty_core` is not available from pub.dev, and
`dependency_overrides` in a dependency's pubspec do not apply to your package,
so the root pubspec overrides the core source:

```yaml
dependencies:
  dart_monty:
    git:
      url: https://github.com/runyaga/dart_monty.git
      ref: v0.110.0-dev.4

dependency_overrides:
  dart_monty_core:
    git:
      url: https://github.com/runyaga/dart_monty_core.git
      ref: v0.110.0-dev.4
```

A package that imports core names directly also lists
`dart_monty_core: ^0.110.0-dev.4` under `dependencies`.

Run `dart pub get` after editing `pubspec.yaml`.

Import `package:dart_monty/dart_monty.dart` for the supported high-level
surface. [dart_monty.dart](https://github.com/runyaga/dart_monty/blob/main/lib/dart_monty.dart)
lists its exports. Import `package:dart_monty_core/dart_monty_core.dart` for
core declarations outside that facade.

For local worktree development, use `path:` dependencies for both packages.

## Platform Requirements

### Native (Desktop, Server, and Flutter)

`dart pub get` resolves dependencies. `dart run`, `dart test`, and `dart build`
invoke core's build hook. The hook installs the verified prebuilt worker for the
host from the core release in a cache. A Rust toolchain is not required.

Core's public pool declaration describes how to select an explicit worker
location. `MountDir` needs the native mount library and the `dart_monty_core`
`build_worker` hook opt-in in the root package.

### Flutter Web

Include the assets declared by core when bundling a Flutter application:

```yaml
flutter:
  assets:
    - package: dart_monty_core
```

The worker loads when a pool starts. [Deployment](deployment.md) lists the
required web security headers.

### Plain Dart web

Serve `dart_monty_core_worker.js` and `dart_monty_core_worker.wasm` from
core's `lib/assets` directory at `packages/dart_monty_core/assets`. Core's
public pool declaration describes how to select another location.
