# The `dart_monty_core` boundary

**What belongs downstream, what belongs in core, and where the two currently
overlap.** Measured 2026-09-17 against `dart_monty` `8d00f4d` and
`dart_monty_core` `036e746`, both on `integration/0.23`, and against
`pydantic_monty` 0.0.23 — the reference Python binding over the same engine
version core pins.

Every figure here was counted, not estimated. Where a claim is an inference it
says so.

## The split, stated

**`dart_monty_core` is the interpreter binding. `dart_monty` is the integration
layer.** That is a deliberate division, and the measurement supports it: core
contains **zero** references to any of the concepts this package is built
around.

| concept | references in core's `lib/` |
|---|---:|
| `MontyExtension` | 0 |
| `ExtensionCoordinator` | 0 |
| `SandboxExtension` | 0 |
| `ChildSpawnContext` | 0 |
| `MessageBus` | 0 |
| `HostFunction` | 0 |
| `BridgeEvent` | 0 |

The extension registry, child sandboxes, host-function schemas and the bridge
event stream are **dart_monty concepts**. Pushing them into core would invert
the architecture.

## How much of this package overlaps core

`lib/src/` — **7,511 lines across seven directories plus one top-level file**:

| subsystem | files | lines | core counterpart |
|---|---:|---:|---|
| `extensions/` | 6 | **1,988** | none |
| `host/` | 9 | 1,188 | none |
| **`os_call/`** | 11 | **1,218** | **`core/lib/src/mount/`, 1,865 lines** |
| `bridge/` | 5 | 1,014 | none, except the driver loop (below) |
| `extension/` | 4 | 984 | none |
| `runtime/` | 9 | 883 | partial — adapters over `MontyRepl` |
| `web/` | 3 | 91 | none |
| `introspection_functions.dart` | 1 | 145 | none |

**One directory out of seven overlaps core — 16% of the implementation.** The
rest is the layer's reason for existing.

> **Note the two similarly named directories.** `extension/` (984 lines) is the
> extension *mechanism* — `MontyExtension`, `ExtensionCoordinator`. `extensions/`
> (1,988 lines) is the shipped *batteries* built on it, and is the single
> largest unit in the package. An earlier revision of this document listed only
> the former and undercounted the package.

## The one thing core cannot currently support

**Core has no observable execution API.** Counted: **zero** public methods in
core return a `Stream`. Every entry point returns a single terminal value —
`Monty.run()`, `Monty.runPrecompiled()`, `MontyRepl.feedRun()` all return
`Future<MontyResult>`.

`MontyBridge.execute()` returns `Stream<BridgeEvent>`, because the integration
layer must emit an event at **each step** — run started, every OS call, every
host-function call, every child event. Core's `_driveLoop` is **private**
(`monty_repl.dart:487`) and yields only the final result.

So `PlatformBridge._run` re-drives the same five `MontyProgress` cases to
interleave its event emissions. Its own doc comment says so:

> *"Drives the Monty start/resume loop, mirroring the shape of
> `MontyRepl._driveLoop`."* — `lib/src/bridge/platform.dart:398-399`

**This is a core gap, not downstream duplication.** There is no way to observe
core's loop from outside it. A per-step observer hook in core would remove a
507-line file's reason to exist, and it is the highest-value single change
identified by this analysis. It is also independent of every filesystem
question below.

## Where `os_call/` and core's `mount/` genuinely differ

They are not two implementations of one design. They are different things:

- **core is a virtual filesystem** — it delegates path resolution and state to a
  separate structure (`vfs.lookup(path)`, `vfs.parentDirOf(path)`), backed by a
  mount table with byte quotas.
- **`os_call/` is a security proxy over the host OS** — it resolves a
  containment boundary (`safeResolved`) and delegates straight to `dart:io`.

Consequences, each measured:

| | core | dart_monty |
|---|---|---|
| backing store | memory mount table | `package:file` — real disk **or** memory |
| containment | structural, by mount | root-based, checked per operand |
| quotas | `VfsAccountant`, 100 MB default | none |
| `Path.stat` | implemented | **absent from `PathOp`** |
| symlinks | `is_symlink` returns `false` unconditionally | real, via `dart:io` |
| composition | single `fallthrough` | `composeOsHandlers`, overlay, read-only decorators |
| child sandboxes | none | `ChildVfsStrategy` |

**Neither is a superset.** "Adopt core's handler and delete `os_call/`" is not
available: core has no API accepting a `package:file` backend or a physical
root, and models no child sandbox.

## Known behavioural divergences

These are contract differences between this package and core/the reference.
Each is a `path:line` fact; none is yet adjudicated by a shared test.

1. **Missing parent on write.** `fs_handlers.dart:87` creates it
   (`..parent.createSync(recursive: true)`). Core requires it
   (`requireParentDir`), and the reference raises `FileNotFoundError`.
2. **Raw Dart exceptions escape into the sandbox.** `mkdir` with a missing
   parent and `read_text` on a directory surface a `FileSystemException`, where
   core and the reference both raise typed Python errors.
3. **`rename` return value.** Core returns `null`; this package returns the new
   path (`fs_handlers.dart:152`).
4. **`args.first` is used 18 times in `sandboxed_fs_handler.dart` with no
   emptiness guard.** Core declines instead —
   `final rawPath = args.firstOrNull; if (rawPath is! String) return notMine(...)`.
   An empty argument list raises `StateError`, which is an `Error` and not
   caught by `on Exception`. *(The blast radius was not tested.)*
5. **`_codepointCount` is byte-identical in three files** — core's handler and
   both handlers here — private in all three.

## Unadjudicated, and why

No test has ever run the same fixture against both implementations. The
conformance corpus can now do it — `runMountFsFixture(name, osHandler)` in
`monty_conformance` runs a fixture against a caller-supplied handler — but two
gaps remain: each candidate needs the same six-file seed, and the fixture root
is hardcoded to `/mnt`, which a root-based handler will refuse.

Until that table exists, **every claim about how much the two diverge is
inference.** The list above is what reading established; it is not a
measurement of divergence.

## An option not yet taken

A third package could hold what is genuinely shared — operation semantics,
argument extraction, the codepoint counting — leaving core as the binding and
this package as the integration layer. **Not a recommendation**; recorded
because it is the option that neither "adopt core's handler" nor "keep two
implementations" covers, and it should be weighed against the observer hook
above, which is cheaper and deletes more.

## Provenance

Derived from a three-way analysis — this package, `dart_monty_core`, and the
`pydantic_monty` reference binding — reviewed by two independent readers under a
citation contract. The full working, including the corrections that review
forced, is in `solpi-bench/artifacts/ANALYSIS-VFS-COMPLETE.md`.
