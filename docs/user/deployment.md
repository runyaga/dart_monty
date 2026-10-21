# Deployment and Bundling

`dart_monty_core` supplies the Web Worker assets and native build hook used by
this package. Dependency setup is in [Installation](install.md).

## Flutter Web

Bundle the worker assets declared by core's `flutter.assets` stanza as
described in [installation](install.md#flutter-web). Core's asset lookup
supports Flutter and plain Dart package paths without a separate initialization
step.

### Required security headers

The WASM worker uses `SharedArrayBuffer`. Browsers only permit it on pages
served with:

```text
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

GitHub Pages cannot set these headers. A standard hosting target
(nginx, Cloudflare Workers, S3+CloudFront with edge functions) can.

## Plain Dart web (no Flutter)

Serve the worker assets from core's package asset path, or configure the pool
with their directory URL. Look in core's public pool declaration for the
worker-location option.

## Native (FFI)

For desktop / server / Flutter desktop / Flutter mobile targets,
`dart_monty_core/hook/build.dart` installs the verified host worker from the
core release during `dart run`, `dart test`, or `dart build`. Dart's
native-assets toolchain bundles the mount library into compiled output when the
root package opts in for `MountDir`.

Run `dart pub get` before a command that invokes the hook.

### AOT-compiled standalone binaries

Self-contained executables need core's worker-build opt-in and child-process
entrypoint so the binary can relaunch itself as the worker. Look in core's
public library for that entrypoint and in its build hook for the opt-in. Dart's
native-assets tooling handles mount library staging for an opted-in package.
See the
[Dart native-assets documentation](https://dart.dev/interop/c-interop/native-assets)
for the current layout.
