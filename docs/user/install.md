# Installation

`dart_monty` uses branch `port-0.120`. Its core dependency is pinned to
commit `bcfbc23` on branch 0.120, with upstream pydantic/monty 1.2.0.
The core pin is not a release.
`dart_monty_core` is not available from pub.dev, and
`dependency_overrides` in a dependency's pubspec do not apply to your package,
so the root pubspec overrides the core source:

```yaml
dependencies:
  dart_monty:
    git:
      url: https://github.com/runyaga/dart_monty.git
      ref: port-0.120

dependency_overrides:
  dart_monty_core:
    git:
      url: https://github.com/runyaga/dart_monty_core.git
      ref: bcfbc232ece6436c3e68ec7edfca7c1cad6a32be
```

A package that imports core names directly also lists
`dart_monty_core: any` under `dependencies`; the root Git override above
selects the exact core commit.

Run `dart pub get` after editing `pubspec.yaml`.

Import `package:dart_monty/dart_monty.dart` for the supported high-level
surface. [dart_monty.dart](https://github.com/runyaga/dart_monty/blob/main/lib/dart_monty.dart)
lists its exports. Import `package:dart_monty_core/dart_monty_core.dart` for
core declarations outside that facade.

For local worktree development, use `path:` dependencies for both packages.

## Platform Requirements

### Native (Desktop, Server, and Flutter)

The core branch 0.120 pin has no prebuilt native worker. After `dart pub get`,
resolve `dart_monty_core` via `.dart_tool/package_config.json` (`rootUri`) and
run `bash tool/build_worker.sh` in that checkout with Rust stable installed
before native tests/examples. Resolve a relative `rootUri` against the
package configuration file's URI. CI builds the worker from the same pin.

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
