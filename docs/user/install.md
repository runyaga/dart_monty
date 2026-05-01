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

Both must be listed directly. `dart_monty_core` is already a
transitive dependency of `dart_monty`, but Flutter's asset bundler
does not chase transitive references — `flutter.assets` entries must
name the package that physically owns the files (see
[Flutter Web](#flutter-web) below). Listing `dart_monty_core`
explicitly also keeps the two versions in lockstep.

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

Flutter consumers depend on **both** `dart_monty` (the API) and
`dart_monty_core` (the package whose pubspec physically declares the
WASM/JS assets). Flutter's asset resolver does not chase transitive
references — `- package: X` under `flutter.assets` must name the
package that owns the files.

```yaml
# pubspec.yaml
dependencies:
  dart_monty: ^0.17.0
  # Required — Flutter's asset bundler needs this listed directly.
  # Do not remove; it is not redundant with dart_monty.
  dart_monty_core: ^0.17.0

# Flutter only — instructs the asset bundler to include
# dart_monty_core's WASM/JS bridge files. Plain-Dart consumers
# ignore this stanza.
flutter:
  assets:
    - package: dart_monty_core
```

```dart
// main.dart
import 'package:dart_monty/dart_monty.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DartMonty.ensureInitialized(); // loads bridge on web; no-op native
  runApp(const MyApp());
}
```

`DartMonty.ensureInitialized()` dynamically injects the
`dart_monty_core` JS bridge into `document.head` and awaits load. No
manual `<script>` tag in `web/index.html` is required;
`--base-href` is honoured automatically.

**Security headers.** Serve your web app with:

- `Cross-Origin-Opener-Policy: same-origin`
- `Cross-Origin-Embedder-Policy: require-corp`

(Required for `SharedArrayBuffer`, which the WASM worker uses for
zero-copy communication.)

### Plain Dart web (no Flutter)

Without Flutter's asset bundler, copy the three asset files from the
`dart_monty_core` package into your own `web/` dir and add a
`<script>` tag:

```bash
# Pub.dev install — assets live under the hosted cache.
# (For a git-installed dart_monty_core, swap `hosted/pub.dev` for `git`.)
CORE_ASSETS=$(dart pub cache dir)/hosted/pub.dev/dart_monty_core-*/lib/assets
cp $CORE_ASSETS/dart_monty_core_bridge.js web/
cp $CORE_ASSETS/dart_monty_core_worker.js web/
cp $CORE_ASSETS/dart_monty_core_native.wasm web/
```

```html
<!-- web/index.html — must load before your compiled Dart app -->
<script src="dart_monty_core_bridge.js"></script>
```

`dart_monty_core`'s own `packages/dart_monty_web/` is a working
reference example for this pattern.
