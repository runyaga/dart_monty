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
name: my_app
publish_to: none  # required when any dep is a path: dep — pub
                  # forbids publishing a package with path: deps,
                  # so this opts out of the publish path entirely.
dependencies:
  dart_monty:
    path: /absolute/path/to/dart_monty
  dart_monty_core:
    path: /absolute/path/to/dart_monty_core

dependency_overrides:
  dart_monty_core:
    path: /absolute/path/to/dart_monty_core
```

> **`publish_to: none` is required for any pubspec that uses
> `path:` deps.** Without it, `dart pub get` warns with
> `'Packages with this dependency cannot be published'` and the
> package becomes un-publishable. For applications and library
> sandboxes (which never publish to pub.dev), this is harmless —
> just declare it explicitly.

The `dependency_overrides` block is the canonical Dart workaround
for "I want this transitive dep to come from somewhere else than
the publishing pubspec says." **It only takes effect when this
package is the entry-point (your app)**, not when consumed as a
library by some other package — pub silently ignores
`dependency_overrides` blocks in transitive pubspecs.

## Consuming a third-party `dart_monty` extension

If you depend on a Dart package that itself uses `dart_monty` (for
example, a fictional `dart_monty_dataframe` extension), you cannot
just add the extension to your dependencies and expect things to
work. Until `dart_monty` 0.20.0 ships on pub.dev, every consumer
must declare top-level `dependency_overrides` for **both**
`dart_monty` and `dart_monty_core` — even if the extension's own
pubspec already has them.

```yaml
# your app's pubspec.yaml
name: my_app
dependencies:
  dart_monty_dataframe:
    git:
      url: https://github.com/example/dart_monty_dataframe.git
      ref: main

# REQUIRED — without these, pub will either fail with a source
# conflict ("dart_monty_core from git" vs "dart_monty_core from
# path") or silently resolve `dart_monty` to pub.dev's legacy
# 0.11.0 (different API, no `Monty.exec`).
dependency_overrides:
  dart_monty:
    git:
      url: https://github.com/runyaga/dart_monty.git
      ref: main
  dart_monty_core:
    git:
      url: https://github.com/runyaga/dart_monty_core.git
      ref: main
```

**Why this is required.** The extension's pubspec lists
`dart_monty: { git: ... }` as a transitive dep. Pub's resolver
treats the extension as a *library* in your project, not as the
entry point — so even if the extension's pubspec contains its own
`dependency_overrides` block, **pub ignores it** (overrides only
apply on the root pubspec). Without your own top-level override,
pub either fails with a source-mismatch error or silently picks
the wrong version.

For local worktree development, swap `git:` for `path:` on **all**
three entries (the dataframe-style direct dep AND both overrides):

```yaml
dependencies:
  dart_monty_dataframe:
    path: /absolute/path/to/dart_monty_dataframe

dependency_overrides:
  dart_monty:
    path: /absolute/path/to/dart_monty
  dart_monty_core:
    path: /absolute/path/to/dart_monty_core
```

After `dart pub get`, verify the resolved versions explicitly:

```bash
$ dart pub deps --no-dev | grep -E "dart_monty\b|dart_monty_core"
├── dart_monty 0.20.0
│   ├── dart_monty_core...
├── dart_monty_core 0.17.0
```

If you see `dart_monty 0.11.x`, your override didn't take and pub
fell back to pub.dev — re-check that the override block is at the
top level, not inside `dependencies`, and that you spelled both
package names correctly.

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
