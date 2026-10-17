# Deployment and Bundling

This guide covers how to bundle and deploy `dart_monty` for both web
and native applications.

## Packages you depend on

- **`dart_monty`** — high-level API. This is the only package your
  app lists as a direct dependency.
- **`dart_monty_core`** — ships the JS bridge, WASM worker, compiled
  WASM binary, and native `hook/build.dart`. Comes in transitively
  through `dart_monty`; you do not need to list it directly.

## Flutter Web

Bundle the worker assets declared by core's `flutter.assets` stanza as
described in [installation](install.md#flutter-web). Core's asset-path probe
finds the Flutter asset base before trying the plain Dart package path.
Start a pool with `Monty.start`; no separate initialization call is needed.
Core remains pure Dart.

### Required security headers

The WASM worker uses `SharedArrayBuffer` for zero-copy communication
with the bridge. Browsers only permit `SharedArrayBuffer` on pages
served with:

- `Cross-Origin-Opener-Policy: same-origin`
- `Cross-Origin-Embedder-Policy: require-corp`

GitHub Pages cannot set these headers; a standard hosting target
(nginx, Cloudflare Workers, S3+CloudFront with edge functions) can.

## Plain Dart web (no Flutter)

Serve `dart_monty_core_worker.js` and `dart_monty_core_worker.wasm` from
core's `lib/assets` directory at `packages/dart_monty_core/assets`.
Alternatively, pass their directory URL as `workerLocation` to `Monty.start`.

## Native (FFI)

For desktop / server / Flutter desktop / Flutter mobile targets,
`dart_monty_core/hook/build.dart` installs the verified host worker from the
core release during `dart run`, `dart test`, or `dart build`. Dart's
native-assets toolchain bundles the mount library into compiled output when the
root package opts in for `MountDir`.

Requirements:

- `dart pub get` resolves dependencies before a command that runs the hook.

### AOT-compiled standalone binaries

When you produce a `dart compile exe` binary without `workerLocation`, call
`runMontyWorkerIfChild(args)` first in `main` and opt in to `build_worker: true`
so the binary bundles the worker library and relaunches itself as the worker.
Dart's native-assets tooling handles mount library staging for an opted-in
package. See the
[Dart native-assets documentation](https://dart.dev/interop/c-interop/native-assets)
for the current layout.
