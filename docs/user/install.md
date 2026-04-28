# Installation

Both `dart_monty` and `dart_monty_core` install from GitHub via
`git:` deps. **Do not run `dart pub add dart_monty`** — pub.dev's
`dart_monty` is the legacy 0.11.0 with a different API (no
`Monty.exec`, no `MontyRuntime`); the current code lives only on
GitHub for now.

```yaml
# pubspec.yaml
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

Both packages must be listed under `git:` — without an explicit
`dart_monty_core` entry, pub will resolve the transitive dep from
pub.dev and the APIs won't match. For local worktree development
swap `git:` for `path:`.

## Platform Requirements

### Native (Desktop/Server)

- **macOS, Linux, Windows:** No manual setup. The native binary
  (built by `dart_monty_core`'s `hook/build.dart`) is compiled
  automatically when you run `dart pub get` — requires a working
  Rust toolchain (cargo + rustc).

  Supported host triples in v0.17.0:

  | OS / arch | Triple |
  |---|---|
  | macOS arm64 | `aarch64-apple-darwin` |
  | macOS x86_64 | `x86_64-apple-darwin` |
  | Linux arm64 | `aarch64-unknown-linux-gnu` |
  | Linux x86_64 | `x86_64-unknown-linux-gnu` |
  | Windows arm64 | `aarch64-pc-windows-msvc` |
  | Windows x86_64 | `x86_64-pc-windows-msvc` |

  Other triples (32-bit ARM, musl libc, BSDs, …) are not built by
  the hook today.

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
  dart_monty:
    git:
      url: https://github.com/runyaga/dart_monty.git
      ref: main
  # Required — Flutter's asset bundler needs this listed directly.
  # Do not remove; it is not redundant with dart_monty.
  dart_monty_core:
    git:
      url: https://github.com/runyaga/dart_monty_core.git
      ref: main

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
# dart_monty_core is git-installed, so its assets live under the
# git pub cache (not the pub.dev hosted cache).
CORE_ASSETS=$(dart pub cache dir)/git/dart_monty_core-*/lib/assets
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
