# Installation

> ## ⚠️ Do **not** run `dart pub add dart_monty`
>
> pub.dev's `dart_monty` is the **legacy 0.11.0** with a completely
> different API — no `Monty.exec`, no `MontyRuntime`, no
> `Monty.typeCheck`. The short `dart pub add` form silently succeeds
> against that legacy package and you'll spend time debugging an API
> mismatch that has nothing to do with your code.
>
> Install via `git:` deps as shown below. Both `dart_monty` **and**
> `dart_monty_core` must be listed explicitly — see "Why both
> packages?" after the snippet.

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

**Why both packages?** `dart_monty` depends on `dart_monty_core`. If
you list only `dart_monty` under `git:`, pub will resolve the
transitive `dart_monty_core` dependency from **pub.dev**, where it
either does not exist or resolves to an old version that does not
match the current API. The build succeeds and then fails at
runtime with confusing import errors. Listing both as `git:` deps
forces pub to resolve them together.

For local worktree development swap `git:` for `path:` on **both**
entries — see "Local worktree development" below.

## Local worktree development

When using `path:` deps that point at local worktrees, pub still
resolves `dart_monty`'s transitive dependency on `dart_monty_core`.
If `dart_monty`'s pubspec pins `dart_monty_core` via `git:` while
your top-level pubspec uses a `path:`, pub fails the resolution
with a constraint conflict. Override the transitive resolution
with `dependency_overrides`:

```yaml
# pubspec.yaml — local development
dependencies:
  dart_monty:
    path: /absolute/path/to/dart_monty
  dart_monty_core:
    path: /absolute/path/to/dart_monty_core

dependency_overrides:
  dart_monty_core:
    path: /absolute/path/to/dart_monty_core
```

The `dependency_overrides` block is the canonical Dart workaround
for "I want this transitive dep to come from somewhere else than
the publishing pubspec says." It only takes effect when the package
is the entry-point (your app), not when published.

## Verifying the install

After `dart pub get` succeeds, run the three-tier smoke test below.
Each tier adds one capability, so a failure tells you which part of
the stack is broken. Don't stop at tier 1 — `2 + 2` proves the FFI
binary loads, but you haven't actually exercised the bridge layer,
the type checker, or extensions until tiers 2 and 3 also pass.

```dart
// bin/smoke.dart (or lib/main.dart)
import 'package:dart_monty/dart_monty.dart';
// Required for tier 3 — extensions live in the bridge library, not
// dart_monty.dart. Importing both is correct and idiomatic.
import 'package:dart_monty/dart_monty_bridge.dart';

Future<void> main() async {
  // ── Tier 1: one-shot exec (proves FFI loads + interpreter runs) ──
  final r1 = await Monty.exec('2 + 2');
  print('tier 1 exec result: ${r1.value}');  // expect MontyInt(4)

  // ── Tier 2: typeCheck with prefixCode stub (proves type checker
  // works AND that you understand the prefixCode requirement for
  // host-named symbols — see api-reference.md > Static type checking)
  const prefix = 'def fetch(url: str) -> str: return ""';
  final errs = await Monty.typeCheck(
    'result: str = fetch("https://example.com")',
    prefixCode: prefix,
  );
  print('tier 2 typeCheck errors: ${errs.length}');  // expect 0

  // ── Tier 3: MontyRuntime + extension (proves bridge wiring) ──
  final runtime = MontyRuntime(extensions: [JinjaTemplateExtension()]);
  final r3 = await runtime
      .execute("tmpl_render(template='Hello {{ name }}!', "
               "context={'name': 'World'})")
      .result;
  print('tier 3 runtime+extension: ${r3.value}');  // expect MontyString("Hello World!")
  await runtime.dispose();
}
```

```bash
$ dart run bin/smoke.dart
tier 1 exec result: MontyInt(4)
tier 2 typeCheck errors: 0
tier 3 runtime+extension: MontyString("Hello World!")
```

If a tier fails, the failure tells you exactly where to look:

- **Tier 1 fails:** the FFI binary didn't compile or load. Most
  common cause is a missing Rust toolchain on first `pub get` —
  `hook/build.dart` needs `cargo` and `rustc` on `$PATH`. See
  the troubleshooting section in `AGENTS.md`.
- **Tier 2 fails with `unresolved-reference: fetch`:** you forgot
  the `prefixCode:` argument or used `def fetch(...): ...` (Ellipsis)
  for the body. See api-reference.md > Static type checking.
- **Tier 3 fails to compile (`JinjaTemplateExtension` undefined):**
  you're missing the `import 'package:dart_monty/dart_monty_bridge.dart';`
  line. Extensions are not exported from `dart_monty.dart`.

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
