# Installation

Install both `dart_monty` (the API) and `dart_monty_core` (the
package that owns the native/WASM build outputs) from pub.dev:

```bash
dart pub add dart_monty dart_monty_core
```

Or in `pubspec.yaml`:

```yaml
dependencies:
  dart_monty: ^0.17.0
  dart_monty_core: ^0.17.0
```

Import core directly when using concrete values, snapshots or other names
outside the nine core names re-exported by `dart_monty`.

For local worktree development, swap the version constraints for
`path:` deps.

## Bleeding edge (git main)

Use this only if you need an unreleased fix on `main`:

```yaml
dependencies:
  dart_monty:
    git:
      url: https://github.com/runyaga/dart_monty.git
      ref: main
  dart_monty_core:
    git:
      url: https://github.com/runyaga/dart_monty_core.git
      ref: main
```

Pin both — without an explicit `dart_monty_core` git entry, pub will
resolve the transitive dep from pub.dev and the APIs may drift.

## Platform Requirements

### Native (Desktop/Server)

- **macOS, Linux, Windows:** No manual setup. The native binary
  (built by `dart_monty_core`'s `hook/build.dart`) is compiled
  automatically when you run `dart pub get` — requires a working
  Rust toolchain (cargo + rustc).
- **iOS/Android:** Not yet supported. Planned once the FFI/WASM
  story stabilises.

### Flutter Web

Core declares its worker script and WASM module in its own `flutter.assets`
stanza. Include those declared assets when bundling a Flutter application:

```yaml
flutter:
  assets:
    - package: dart_monty_core
```

Core probes `assets/packages/dart_monty_core/lib/assets` first, followed by
`packages/dart_monty_core/assets`. It loads the worker when the pool starts.
There is no separate initialization API or bridge script to inject. Core
remains pure Dart; its asset declaration adds no Flutter SDK dependency.

**Security headers.** Serve your web app with:

- `Cross-Origin-Opener-Policy: same-origin`
- `Cross-Origin-Embedder-Policy: require-corp`

(Required for `SharedArrayBuffer`, which the WASM worker uses for
zero-copy communication.)

### Plain Dart web (no Flutter)

Serve core's `lib/assets/dart_monty_core_worker.js` and
`lib/assets/dart_monty_core_worker.wasm` together under
`packages/dart_monty_core/assets`, or pass their directory URL as
`workerLocation` to `Monty.start`. The worker script loads its sibling WASM
module. No bridge script tag is needed.
