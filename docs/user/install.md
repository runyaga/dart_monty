# Installation

Install from pub.dev:

```bash
dart pub add dart_monty
```

Or add to `pubspec.yaml`:

```yaml
dependencies:
  dart_monty: ^0.120.0
```

`dart_monty` depends on `dart_monty_core 0.120.0` from pub.dev, wrapping
upstream pydantic/monty 1.2.0. If you import core directly, also declare
`dart_monty_core: ^0.120.0` under `dependencies`.

Run `dart pub get` after editing `pubspec.yaml`.

Import `package:dart_monty/dart_monty.dart` for the supported high-level
surface. [dart_monty.dart](https://github.com/runyaga/dart_monty/blob/main/lib/dart_monty.dart)
lists its exports. Import `package:dart_monty_core/dart_monty_core.dart` for
core declarations outside that facade.

For local worktree development, use `path:` dependencies for both packages.

## Platform Requirements

### Native (Desktop, Server, and Flutter)

Core's build hook downloads the prebuilt native worker from its GitHub
release during `dart run`, `dart test`, or `dart build`.

Core's public pool declaration describes how to select an explicit worker
location. `MountDir` also needs the native mount library; see
[Deployment](deployment.md).

### Browser assets

The browser needs no extra build or download. Core's committed `lib/assets`
contains the Web Worker and WASM assets; serve or bundle them as below.

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
