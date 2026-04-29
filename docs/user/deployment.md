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
# pubspec.yaml — install both packages from GitHub
dependencies:
  dart_monty:
    git:
      url: https://github.com/runyaga/dart_monty.git
      ref: main
  dart_monty_core:
    git:
      url: https://github.com/runyaga/dart_monty_core.git
      ref: main

flutter:
  assets:
    - package: dart_monty_core
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

### Local development serving command

For dev / smoke-testing the Flutter Web build locally, the simplest
COI-compliant server is a 30-line Python script. Save as
`tools/serve_coi.py` and run from your `build/web/` directory:

```python
# tools/serve_coi.py — minimal COOP/COEP-enabled static server.
import http.server, socketserver, sys

class COIHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        super().end_headers()

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
with socketserver.TCPServer(("", port), COIHandler) as httpd:
    print(f"Serving build/web/ at http://localhost:{port}/ with COI headers")
    httpd.serve_forever()
```

```bash
flutter build web
cd build/web && python3 ../../tools/serve_coi.py 8000
# open http://localhost:8000/ in Chrome — DevTools Network tab should
# show all three COI response headers on every asset.
```

For nginx in production:

```nginx
location / {
    add_header Cross-Origin-Opener-Policy   "same-origin";
    add_header Cross-Origin-Embedder-Policy "require-corp";
    try_files $uri $uri/ /index.html;
}
```

For Cloudflare Workers / Pages, add the headers via a Worker or
`_headers` file. The minimal `_headers`:

```
/*
  Cross-Origin-Opener-Policy: same-origin
  Cross-Origin-Embedder-Policy: require-corp
```

> **How to verify it's working.** Open Chrome DevTools → Console.
> If you see `SharedArrayBuffer is not defined` or
> `crossOriginIsolated === false`, the headers aren't reaching the
> browser. Check the Network tab — every response (including the
> top-level HTML) must carry both COOP and COEP headers, otherwise
> the page falls out of the cross-origin-isolated state.

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
