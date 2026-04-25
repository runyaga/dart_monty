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

```yaml
# pubspec.yaml
dependencies:
  dart_monty: ^<version>
```

```dart
// main.dart
import 'package:dart_monty/dart_monty.dart';
import 'package:flutter/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DartMonty.ensureInitialized();
  runApp(const MyApp());
}
```

Flutter bundles `dart_monty_core`'s declared `flutter.assets`
automatically — no consumer-side redeclaration is needed.
`DartMonty.ensureInitialized()` injects
`assets/packages/dart_monty_core/lib/assets/dart_monty_core_bridge.js` into
`document.head` at runtime, awaits load, and verifies
`window.DartMontyBridge` is defined. No manual `<script>` tag in
`web/index.html` is required; `--base-href` is honoured
automatically.

### Required security headers

The WASM worker uses `SharedArrayBuffer` for zero-copy communication
with the bridge. Browsers only permit `SharedArrayBuffer` on pages
served with:

- `Cross-Origin-Opener-Policy: same-origin`
- `Cross-Origin-Embedder-Policy: require-corp`

GitHub Pages cannot set these headers; a standard hosting target
(nginx, Cloudflare Workers, S3+CloudFront with edge functions) can.

## Plain Dart web (no Flutter)

Without Flutter's asset bundler, copy the three asset files from the
`dart_monty_core` pub cache into your own `web/` directory and add a
`<script>` tag:

```bash
CORE_ASSETS=$(dart pub cache dir)/hosted/pub.dev/dart_monty_core-*/assets
cp $CORE_ASSETS/dart_monty_core_bridge.js   web/
cp $CORE_ASSETS/dart_monty_core_worker.js   web/
cp $CORE_ASSETS/dart_monty_core_native.wasm web/
```

```html
<!-- web/index.html -->
<script src="dart_monty_core_bridge.js"></script>
```

The synchronous `<script>` tag sets `window.DartMontyBridge` before
Dart starts, so `DartMonty.ensureInitialized()` sees the bridge as
already loaded and returns immediately.

## Native (FFI)

For desktop / server / Flutter desktop / Flutter mobile targets,
`dart_monty_core/hook/build.dart` compiles a platform-specific
shared library at `pub get` time and registers it as a `CodeAsset`.
Dart's native-assets toolchain bundles the library into your
compiled output automatically — no manual copy step required.

Requirements:

- Rust toolchain (`cargo` + `rustc stable`) on the build machine.
- `flutter pub get` or `dart pub get` triggers the build.

### AOT-compiled standalone binaries

When you produce a plain `dart compile exe` binary, the native
assets hook still runs at build time and the dylib is referenced
with an absolute path from the pub cache. For distribution, Dart's
native-asset tooling handles the staging; see the
[Dart native-assets documentation](https://dart.dev/interop/c-interop/native-assets)
for the current layout.
