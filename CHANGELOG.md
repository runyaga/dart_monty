## Unreleased

## 0.120.0 - 2026-10-29

- Overhaul the runtime Pages site with shared navigation/theme, resolved build
  metadata and an exact-output example catalog. Add workspace ownership,
  explicit child module grants, tools, stdlib, VFS scans and structured errors.
  Build and smoke branch artifacts; publish only tested main artifacts.

- Depend on dart_monty_core 0.120.0 from pub.dev (upstream monty 1.2.0).
  Native targets use core's prebuilt worker downloaded from its GitHub release;
  browsers use core's committed assets. The facade
  exports `ExternalModule`, runtime root sessions accept `externalModules`,
  and sandbox children use only `childExternalModules`. Integration tests
  pin rename's target-path result, shared file iteration position, and cwd
  retention after type-check rejection.

## 0.110.0-dev.4 - 2026-10-20

### Added

- The facade exports `OSAccess`, `MontyBool`, `MontyInt`, `MontyFloat`,
  `MontyString`, `MontyList`, `MontyTuple`, `MontyDict`, and `MontyBytes` so a
  host function can be written from the dm import alone. The facade has 54
  names.
- The facade exports `Frame`, `MontyRuntimeError`, `MontySyntaxError`,
  `MontyTypingError`, `MontyCrashedError`, `MontyExceptionValue` and
  `FrameTooLargeException`, so a consumer can read traceback frames and the
  error subtype from the dm import alone. The facade has 61 names.
- `BridgeRunError` gains `displayMessage`, `cause`, `causeStack` and
  `throwCause()`. `cause` is the `MontyError` for a Python failure or the
  recorded throw for an infrastructure failure, and `throwCause()` rethrows it
  with the captured stack. `message` is unchanged.
- `HostFunction.parity` registers a host function whose arguments and result
  follow pydantic-monty 1.1.0. Its handler may return any Dart object: `null`
  becomes `None`, and an object with no Monty form raises Python `TypeError`
  (`Cannot convert <type> to Monty value — wrap class instances in
  pydantic_monty.ClassInstance(...)`). A call that its parameters cannot bind
  raises Python `TypeError` with the CPython message. The original
  `HostFunction` constructor is unchanged.
- `docs/reference/upstream-divergences.md` lists every known behaviour that
  differs from pydantic-monty 1.1.0. It adds rows D-1 to D-3 to core's
  C-1 to C-12.

### Changed

- dart_monty builds on dart_monty_core 0.110.0-dev.4.
- dart_monty and dart_monty_core are 0.110.0-dev.3. VM tests and native
  programs use the prebuilt worker that core's build hook installs from the
  core release, and CI uses that worker without building one.

### Fixed

- The installation page lists the Git tag for `dart_monty`, the root
  `dependency_overrides` entry for `dart_monty_core`, and the worker build
  opt-in that native programs need. The user docs, tutorials and architecture
  pages use the current API.

### Breaking

dart_monty now builds on dart_monty_core 0.110 (the worker API). This first
step ports the types; behaviour that core no longer provides is rebuilt by the
following D1 changes, and until then it throws `UnimplementedError` naming the
change that brings it back.

- **`dart_monty_testing.dart`** and **`monty_backend_spi.dart`** are gone.
  Tests script `FakeMontySession` from `dart_monty_core_testing.dart`.
- **`DartMonty.ensureInitialized`** is gone: the web needs no init call. The
  `web` dependency goes with it.
- **`PlatformBridge`** is gone. `MontyBridge({required MontySession session,
  BridgeLogger? logger})` replaces `MontyBridge(platform:, limits:)`.
- **`MontyRuntime(...)`** is now **`await MontyRuntime.start(...)`**;
  `MontyRuntime.defaultCheckoutTimeout` is 30 s.
  `clearState()` returns a `Future`.
- **`ExtensionCoordinator.generateSystemPrompt`**, `systemPromptPrefix` and
  the `sandbox_spawn(system_prompt=)` parameter are gone;
  `MontyExtension.systemPromptContext` stays.
- **`SandboxExtension`** no longer takes `platformFactory`; `childLimits` is a
  `ResourceLimits`.
- OS handlers are core's **`OsHandler`** (`MontyValue` arguments and result)
  instead of `OsCallHandler`, and raise `ExternalException(excType, message)`
  instead of `OsCallException`. `HostFunctionSchema.mapAndValidate` takes
  `(args, kwargs)`.
- **`timeHandler`** is gone, with the `date.*` and `datetime.*` routing in
  `defaultOsHandler()`: the worker answers the clock with upstream's `system`
  clock (UTC), so clock calls never reach a handler. `composeOsHandlers`,
  `osArgString` and `PathOp` are no longer exported.
- **OS-call declines are synchronous.** `fsHandler`, `memoryFsHandler`,
  `sandboxedFsHandler`, `readOnlyHandler`, `overlayFsHandler` and the composer
  decline with `throw const OsCallNotHandledException()` and answer
  synchronously; a returned `Future` that fails with it no longer declines
  (core raises `TypeError`). `envHandler` declines an unknown `os.*` operation
  instead of throwing `UnsupportedError`.
- **`ExecutionHandle.result`** and `HostContext.subExecute` complete with a
  `MontyValue` and fail with `MontyError`; `BridgeRunError.exception` and
  `ChildFailed.exception` are `MontyError`.
- **`BridgeLogger.silent`** is the silent logger.
- **`MontyBridge.execute`** runs each execution as one `feedRun` on the
  session. Print text is collected with core's `CollectString` and attached
  to the run's terminal event. With no OS handler registered, OS calls take
  the worker's default (`PermissionError` for a filesystem call,
  `RuntimeError` for any other) instead of dm's `PermissionError`, and emit
  no events. A declined call reports `BridgeOsCallResult.result`
  `'Declined'`. Calls the worker answers itself (the OS policy's clock and
  sleep, mounts) emit no events.
- A run that fails with a throw that is not a `MontyError` emits
  `BridgeRunError(exception: null)`, and `extractBridgeResult` rethrows the
  original throw.
- Host functions are passed to the feed as core `MontyHostFunction` values.
  A `DispatchMode.future` function is a core `coroutine`; a
  `DispatchMode.sync` one is awaited and Python sees its value. A call to an
  unregistered name, or to a function with no handler on this backend, now
  raises `NameError` instead of `RuntimeError: Unknown function`. Validation
  and handler failures still raise `RuntimeError`; a handler that throws an
  `ExternalException` raises that exception's type.
- **`MontyRuntime.start(pool:)`** runs on a core `Monty` pool. With a `pool`
  the caller sizes and closes it; without one the runtime starts its own,
  with room for a root execution, a sub-execution and a `SandboxExtension`'s
  `maxChildren`, and closes it on `dispose`. That default pool finds the
  worker by core's discovery; until the worker ships with core, pass a pool
  started with `workerLocation`. Shared mode holds one session for the
  runtime's life; sandbox mode checks one out per `execute` and closes it.
  `execute(inputs:)` binds globals through the feed instead of a code prefix,
  and `execute(os:)` is that feed's OS handler.
- **`ExecutionHandle.cancel`** closes the execution's busy session: a running
  turn fails with `MontyCrashedError`, a pending host call fails at once. In
  shared mode the next `execute` runs on a fresh session, without the old
  globals. Cancel also cancels the `HostContext.cancelToken` of the
  execution's host calls; after the execution ends it does nothing.
- **`clearState()`** disposes the extensions, closes the held session and
  checks out a new one. **`dispose()`** releases the session and an owned
  pool even when an extension's `onDispose` throws, then rethrows.
- `MontyRuntimeRef` and `currentBackendKind` are no longer exported.
- **`HostContext.subExecute`** runs on a second session checked out of the
  runtime's pool, with default limits, the inputs bound by the feed, no OS
  handler and no host functions; the session is closed afterwards, and on
  `dispose`. A checkout that waits past the pool's `checkoutTimeout` fails
  with `TimeoutException`. A bridge built on a bare session gives handlers
  no `subExecute`, so `run_script` raises its `StateError` there.
  `run_script` returns the sub-script's value as it is (a tuple stays a
  tuple).
- **`HostFunction.childPropagation`** and `ChildPropagation` are gone: a
  function registered on a runtime never reaches a child sandbox.
  `HostFunctionSchema.mapAndValidate` and the `HostArgs` extension are no
  longer exported.
- **`MontyExtension.coordinator`** and **`MontyRuntime.coordinator`** are
  gone, and `ExtensionCoordinator`, `StructLogBridgeLogger`,
  `NullBridgeLogger` and `UnsupportedBackendError` are no longer exported.
  Use `BridgeLogger.silent` to silence logging; a `null` logger is still
  dm's struct_log logger. An unsupported backend still fails attachment
  with an `Error`.
- **`EventLoopExtension`** no longer exposes `channelState` or
  `channelStateSignal`, and `EventLoopState` and its variants are no longer
  exported; use `isWaiting`.

- **`MontyRuntime.start(limits:)`** sets the `ResourceLimits` of the
  sessions `execute()` runs on: the held session (and each one that replaces
  it) in shared mode, each execution's session in sandbox mode.
  Sub-executions keep the defaults.
- In shared mode a feed that fails with **`MontyCrashedError`**, or with a
  `MemoryError` or `TimeoutError` (what a memory or time limit raises),
  closes the held session, and the next `execute()` runs on a fresh one with
  empty globals. The extensions stay attached; it is not a `clearState()`.
- **`MontyValueX`** is no longer exported. Read values with `dartValue` or a
  pattern on core's `MontyValue` subtypes.
- **The only library entry point is `package:dart_monty/dart_monty.dart`.**
  The former `dart_monty_bridge.dart` entry point is gone. Core types are
  re-exported only for these nine names: `Monty`, `MontySession`,
  `MontyValue`, `MontyNone`, `MontyError`, `ResourceLimits`, `OsHandler`,
  `OsCallNotHandledException` and `ExternalException`. Import any other core
  type from `package:dart_monty_core/dart_monty_core.dart`.
  `extractBridgeResult` is no longer exported.
- The message bus moved to the extras package. No compatibility alias and no
  extras dependency is added to dart_monty.
- A host function returns a dataclass-like value as core's `ClassInstance`;
  `example/dataclass_demo.dart` shows it.

Eight features that nothing used have been moved out of this package. There
is no deprecation period and no replacement API.

- **`JinjaTemplateExtension`** (`tmpl_render`) and
  `defaultMaxTemplateInputSize` are gone, and with them the `dinja`
  dependency.
- **`defaultExtensions()`** is gone. List the extensions you want explicitly,
  e.g. `[MessageBusExtension(), EventLoopExtension()]`.
- **`StatefulExtension`** and **`HasStateSignal`** are gone, as is
  `ExtensionCoordinator.statefulObservations()`. `EventLoopExtension` and
  `SandboxExtension` keeps `childrenSignal`; they no
  longer expose `state`, `stateSignal`, `stateSignalAsObject` or
  `setInitialState`.
- **`MontyInterceptor`** is gone: the `interceptor` parameter of
  `MontyRuntime`, `MontyBridge` and `PlatformBridge` is removed, and so is
  `HostFunction.isInfra`, which only selected functions that skipped the
  interceptor. Host functions are always called directly.
- **`DescriptionProvider`** is gone, with the `descriptionProvider` parameter
  of `MontyRuntime` and `ExtensionCoordinator.attachTo`. Put the description
  in the function's `HostFunctionSchema`.
- **`FunctionSurface`** is gone, with `HostFunction.surfaces` and
  `exposedSchemas` on `MontyRuntime`, `MontyBridge` and `PlatformBridge`. Use
  `schemas`.
- **`ParamRenderHint`** is gone, with `HostParam.renderAs` and
  `HostParam.renderHintFrom`. `HostParam.toJsonSchema()` no longer emits
  `x-render-as` or `x-render-hint-from`.
- **`ChildSystemPromptBuilder`** is gone, with
  `SandboxExtension.systemPromptBuilder`. A child's system prompt is now only
  the `system_prompt` argument of `sandbox_spawn`.

The published web demos no longer show template rendering.

### Changed

- The package version is `0.110.0-dev.2`, matching `dart_monty_core`. The
  `dart_monty_core` constraint is `^0.110.0-dev.2`, resolved from the commit
  behind that core's `v0.110.0-dev.2` tag, and every published demo page shows
  both.

### Fixed

- Extensions of equal `priority` attach in registration order even when more
  than 32 are registered, where `List.sort` is not stable.
- A child spawn that fails part-way (a `createChildInstance` throws) disposes
  the clones it already made instead of leaking them.

- `timeHandler`: `datetime.now()` and `datetime.now(tz)` dropped the
  milliseconds. Python's `datetime.microsecond` is the whole sub-second part,
  but the handler copied Dart's `DateTime.microsecond`, which holds only the
  part below one millisecond, so 12:34:56.123456 reached Python as `.000456`.

## 0.23.0

Requires `dart_monty_core` 0.23 (monty v0.0.23), consumed from the `v0.23.0`
git tag. That release is tagged but not on pub.dev, so the pin stays a git ref
and this package is not publishable until it is.

The version jumps 0.18.0 -> 0.23.0 rather than 0.19.0 so that dart_monty and
dart_monty_core state the same number. They are released together and pinned to
each other; two different numbers on one line made "which core does this
dart_monty want" a question you had to open `pubspec.yaml` to answer, and the
published page said `v0.18.0 - dart_monty_core integration/0.23`, which reads
like a mismatch rather than a pairing.

### Changed

- `dart_monty_core` is pinned to the `v0.23.0` tag in `pubspec.yaml`,
  `example/pubspec.yaml`, `example/web/pubspec.yaml` and `pages.yaml`;
  `tool/check_core_ref.sh` requires all four to agree. It was an
  `integration/0.23` branch ref until that line was merged and tagged.

### Fixed

- The example smoke test ran its children from the repo root, where each one
  republished the native asset this process had mmap'd, killing the test runner
  with SIGBUS/SIGSEGV/SIGABRT. They now run inside `example/`
  (dart_monty_core#161, dart-lang/sdk#62361).
- `el_recv()` is an async host function, so monty returns a coroutine from it.
  The event-loop and signals experiment scripts called it bare and failed with
  `TypeError: 'coroutine' object is not subscriptable`; they now `await` it.

### CI

- `ci.yaml` and `pages.yaml` fire on `integration/**`, not `main` alone. Six
  commits had previously run TruffleHog and nothing else.
- New `test-integration` job runs the 26 integration-tagged files -- including
  13 of the 14 that exercise real `dart_monty_core` through FFI -- which no
  pipeline ran before (#452).
- DCM runs on the host; the container skips it visibly rather than failing on a
  version mismatch it cannot resolve.

## 0.18.0

Requires `dart_monty_core` 0.18.1 (monty v0.0.18).

### Breaking

- **`OsCallException` is now `dart_monty_core`'s.** The parallel
  `OsCallException(operation, message)` plus `OsCallFileNotFoundError` /
  `OsCallPermissionError` subclasses are gone. Handlers throw
  `OsCallException(message, pythonExceptionType: 'FileNotFoundError')` instead,
  and that type is delivered to Python — so `except FileNotFoundError:` /
  `except PermissionError:` now work (previously every OS error surfaced as
  `RuntimeError`). Catch sites that matched the old subclasses should switch to
  `OsCallException` and check `pythonExceptionType`.

### Added

- **`open()` / file I/O.** The filesystem handlers (`fsHandler`,
  `memoryFsHandler`, `sandboxedFsHandler`, and the read-only/overlay
  decorators) service Python's `open()` — read/write/append, binary mode, and
  `with open(...) as f:`. The bare `Open` OS-call routes to whatever handler
  backs `Path.*`; core's `resolveOpenCall` owns the open() semantics, so the
  handlers just supply their filesystem primitives. `read_bytes` now returns
  typed bytes so binary reads buffer correctly. See `example/file_io_demo.dart`.

## 0.17.1

Requires `dart_monty_core` 0.17.1 — see its changelog for `MontyCallback`,
`.args`, and `inputs:` details.

### Breaking

- **`MontyRuntime(useFutures: true)` removed.** Set `dispatch: DispatchMode.future`
  on each `HostFunction` that Python should be able to `await` instead.
- **`MontyCallback`/`.args` rename** — inherited from `dart_monty_core` 0.17.1;
  update all handler signatures and `MontyPending`/`MontyOsCall` field accesses.

### Added

- **`DispatchMode.future`** on `HostFunction` — makes a handler `await`-able from
  Python; `asyncio.gather` over multiple such functions runs them concurrently.
- **`execute(inputs:)`** — inject Dart values as Python variables for one call.
- **`buildRunScriptFunction`** — `HostFunction` factory that runs a named Python
  script.
- **`HostContext.parent` / `subExecute`** — safe sub-execution from inside a
  handler; direct `runtime.execute()` re-entrancy is guarded.

## 0.17.0

- Low-level bindings have been factored into a separate package,
  [`dart_monty_core`](https://pub.dev/packages/dart_monty_core).

## 0.13.0

### Breaking

- **`MontyResult.value` is now `MontyValue?`** (was `Object?`). Use pattern
  matching or `.dartValue` for migration:
  ```dart
  switch (result.value) {
    case MontyInt(:final value): print(value);
    case MontyString(:final value): print(value);
    case MontyDate(:final year, :final month, :final day): ...
  }
  ```
- **`MontyPending.arguments` is now `List<MontyValue>`** (was `List<Object?>`).
  Same for `kwargs` (`Map<String, MontyValue>?`).
- **`MontyOsCall.arguments/kwargs`** follow the same typed pattern.
- **Removed cancel infrastructure**: `MontyCancelledError`,
  `MontyCancelToken`, `MontyCancelRegistry`, `cancel()`, `handleId`,
  `sandbox_cancel` host function — all removed. Upstream `LimitedTracker`
  with `time_limit_ms` provides runaway protection.

### Added

- **`MontyValue` sealed class** with 18 subclasses for type-safe Python
  values: `MontyNull`, `MontyBool`, `MontyInt`, `MontyFloat`, `MontyString`,
  `MontyBytes`, `MontyList`, `MontyTuple`, `MontyDict`, `MontySet`,
  `MontyFrozenSet`, `MontyDate`, `MontyDateTime`, `MontyTimeDelta`,
  `MontyTimeZone`, `MontyPath`, `MontyNamedTuple`, `MontyDataclass`.
- **`__type` JSON wrappers** in Rust `convert.rs` for lossless round-trips
  of all `MontyObject` variants (Date, DateTime, Path, Tuple, Set, etc.).
- **OsCall support**: Python code using `pathlib`, `os.getenv`, `os.environ`,
  `date.today()`, `datetime.now()` now yields to Dart instead of erroring.
  New `MontyOsCall` sealed subclass, `OsCallHandler` callback, and
  `BridgeOsCallStart`/`BridgeOsCallResult` events.
- **Platform-aware `OsCallHandler`** via conditional imports: `dart:io` on
  native (full filesystem + env + datetime), datetime-only on web.
- **Tier 20 ladder fixtures** for OsCall operations (12 tests, cross-platform).

### Changed

- **Upgrade Monty interpreter from 0.0.9 to 0.0.10** (via `runyaga/0.0.10` fork branch)
- Cherry-picked upstream JSON perf improvements and mount edge case fixes
- Fork reduced to 1 meaningful commit (`frames.is_empty()` guard fix)
- `HandleState` simplified: 6 clean variants (Ready, Paused, OsCall,
  Futures, Complete, Consumed), no tracker-type doubling

### Fixed

- Lossless JSON round-trips for datetime types (were opaque debug strings)
- Ladder fixture expected values updated for `__type` wrappers
- Gate compliance across all packages (format, analyze, test)

## 0.12.0

### Changed

- **Upgrade Monty interpreter from 0.0.9 to 0.0.10** (via `runyaga/0.0.10` fork branch)
- Upstream monty 0.0.10 adds: mounting filesystems, async in Rust,
  executor deduplication, multi-module import statements (`import a, b, c`),
  JSON performance improvements, CI improvements (zizmor, yamlfmt, PGO fixes)
- Update snapshot format pinning for v0.0.10 postcard changes
- Bump `NATIVE_LIB_VERSION` to 0.10.0

### Fixed

- **Cancel race condition**: `cancel()` was a silent no-op when called before
  the worker isolate sent back its handle ID (during Rust compilation). Now
  awaits the handle ID with a 10s timeout instead of dropping the cancel.
  Reliably reproducible on cold-start cancel at <150ms delay.
- Fix analyzer infos in FFI mock test (`curly_braces_in_flow_control_structures`,
  `document_ignores`)
- Apply `dart format` (tall style) across all packages

## 0.11.0

### Breaking

- **API audit**: Trim public barrels across all packages. Internal
  implementation types moved to SPI barrels (`ffi_backend_spi.dart`,
  `wasm_backend_spi.dart`, `bridge_internals.dart`). Remove deprecated
  `MontyCancelledException` typedef and `BaseMontyPlatform` static methods.
  Remove `JsonExtension` from bridge barrel.

### Changed

- **Upgrade Monty interpreter from 0.0.8 to 0.0.9** (via `runyaga/0.0.9` fork branch)
- Upstream monty 0.0.9 adds: `json` module, `datetime` module, nested subscript
  assignment, `max()` kwargs/default, `str.expandtabs()`, BigInt string conversion
  limit, memory growth tracking
- Handle new `MontyObject` datetime variants (`Date`, `DateTime`, `TimeDelta`,
  `TimeZone`) in FFI `convert.rs` — serialized as debug strings for now

### Added

- **Tier 17: `json` module** (13 tests) — `json.dumps`, `json.loads`, roundtrip
  nested structures, `indent`/`sort_keys`/`separators` kwargs, None/bool
  serialization, number types, invalid JSON error handling
- **Tier 18: `datetime` module** (13 tests) — `date`, `datetime`, `timedelta`
  constructors, properties (`.year`, `.month`, `.day`, `.hour`, etc.), methods
  (`.isoformat()`, `.date()`, `.total_seconds()`), date arithmetic
  (`date - date`, `date + timedelta`), comparisons, both import styles
- **`docs/prompt.txt`** — recommended system prompt for LLMs generating Python
  code targeting the Monty sandbox
- Document upstream Monty module system in CLAUDE.md (`crates/monty/src/modules/`)

### Fixed

- Un-xfail tier 7 test #66 (`nested subscript assignment`) — now passes with
  monty 0.0.9
- **Native ladder gate was silently passing** — `tool/test_python_ladder.sh`
  ran `dart test --tags=ladder` without `--run-skipped`, so all ladder tests
  were skipped by `dart_test.yaml` and the gate reported PASSED without
  actually running them
- Remove obsolete `DYLD_LIBRARY_PATH`/`LD_LIBRARY_PATH` from gate scripts
  and test doc comments — the `hook/build.dart` native assets hook handles
  library resolution automatically for both `dart run` and `dart test`
- Fix `dart_test.yaml` skip messages in `dart_monty_ffi` and `dart_monty_bridge`
  to show correct invocation (`dart test --run-skipped --tags=...`)
- Add `--run-skipped` to `test_python_ladder.sh`, `test_snapshot_portability.sh`

### Docs

- Update README: add `json` module usage example, correct stdlib module
  coverage to "Partial" (only `math`, `re`, `json` — not all stdlib)
- Add Testing section to CLAUDE.md with `dart test` guidance

## 0.10.0

### Changed

- Upgrade Monty interpreter from 0.0.7 to 0.0.8 (via `dart_monty_native` 0.8.0)
- Upstream monty 0.0.8 adds: full `math` module, PEP 448 unpacking, `re` module,
  dict view/set operators, compiler stack-depth fixes

### Added

- **Tier 10: `math` module** (15 tests) — `factorial`, `sqrt`, `pi`, `e`, `ceil`,
  `floor`, `gcd`, `pow`, `log`, `isnan`/`isinf`, `fabs`, `copysign`, `sin`/`cos`,
  `radians`/`degrees`, combined hypotenuse
- **Tier 11: `re` module** (10 tests) — `match`, `search`, `findall`, `sub`, `split`,
  no-match `None`, capture groups, `sub` with count limit, multi-group `findall`
- **Tier 12: monty 0.0.8 features** (16 tests) — `filter()` builtin, PEP 448
  generalized unpacking (list, dict, function call, `**kwargs` call), augmented
  subscript assignment (list, dict), tuple/string comparison operators, `dict(zip(…))`,
  `dict(**kwargs)`, set operators (`|`, `&`, `-`), `getattr` (xfail: no classes)
- Un-xfail tier 7 test #65 (`import math`) — now passes with monty 0.0.8
- Register new tiers in web spike, WASM package, and site demo ladder runners

### Fixed

- ForIter stack corruption (#225) in nested for-loops with try/except — fixed by
  upstream compiler stack-depth tracking (#246, #268)

## 0.9.2

- Align all dependency lower bounds with actual API usage (fixes pub.dev
  downgrade tests across ffi, wasm, native, web)
- Update `dart_monty_ffi` constraint to `^0.8.3`
- Update `dart_monty_wasm` constraint to `^0.8.4`

## 0.9.1

> **Pre-1.0 stability notice**: dart_monty is under active development. APIs may
> change between minor versions. If you encounter issues, please
> [open an issue](https://github.com/runyaga/dart_monty/issues).

- Fix pub.dev analysis failure: update `dart_monty_ffi` constraint to `^0.8.2`
  (0.8.1 had a required `bindings` parameter incompatible with zero-arg `MontyFfi()`)
- Update `dart_monty_wasm` constraint to `^0.8.3`
- Update `dart_monty_platform_interface` constraint to `^0.8.0`

## 0.9.0

- **Pure Dart** — remove Flutter SDK dependency; all packages are pure Dart with compile-time conditional imports
- **`Monty()` convenience class** — auto-selects native (FFI) or web (WASM) backend via `dart.library.ffi` / `dart.library.js_interop`
- **Zero-arg constructors** — `MontyFfi()`, `MontyNative()`, `MontyWasm()` now default to production bindings
- **`Monty.withPlatform()`** — explicit backend injection for testing or custom bindings
- **Fix**: WASM bindings use static method API matching JS bridge (was broken since Worker pool refactor)
- SDK constraint raised to `^3.10.0`

## 0.8.1

- Fix CI release workflow: add WASM build step, remove broken AOT compilation
- Align all package versions and dependency constraints for clean pub.dev release
- Add `dart_monty_bridge` publish workflow
- Update release documentation in CLAUDE.md and CONTRIBUTING.md

## 0.8.0

- **WASM direct C-ABI** — bypass NAPI-RS entirely: 28 direct Rust function calls via `wasm32-wasip1`, drops SharedArrayBuffer/COOP/COEP requirement, WASM binary 4.5 MB (was 256 MB overhead)
- **CI** — lower patch coverage gate to 70% (issue #135 tracks raising to 95%)

## 0.7.0

- **CancellableTracker** — sealed `MontyError` hierarchy (6 subtypes), `MontyCancelToken` for cross-isolate cancel, FFI cancel via atomic flag in Monty bytecode loop
- **WASM multi-session** — Worker pool with `createSession`/`disposeSession`, timeout caching, binary snapshot transfer, strip NAPI-RS overhead (256MB → 16MB per session)
- **Monty fork migration** — switch from `pydantic/monty` to `runyaga/monty` fork with NameLookup handled internally in Rust
- **P0 safety fixes** — TOCTOU race in handle lifecycle, handle leak on error paths, sync throw deadlock in iterative execution
- **dispose() hang fix** — `dispose()` now calls `cancel()` first to unblock stuck FFI calls (#113)
- **Web ladder runner** — Dart-side `DartMontyBridge` construction, `getDefaultSessionId` API
- **Cancel experiment suite** — 9 experiments across JIT/AOT/WASM, all passing (evidence in `docs/cancel-experiments-evidence.md`)

## 0.6.2

- **dart_monty_bridge** (0.2.1): Add `printOutput` to `BridgeRunError`, `sandbox_free` host function, fix `cancel()` resource leak.

## 0.6.1

- **dart_monty_wasm**: Fix `toSerializable()` in worker bridge for robust dict/set/bigint handling
  - Add circular reference guard (WeakSet) to prevent stack overflow
  - Add cross-realm Map/Set duck-typing via `.get` presence/absence
  - Convert Set → Array (Python frozenset/set from NAPI-RS)
  - Convert BigInt → Number/String (prevents JSON.stringify crash)
  - Convert TypedArray → Array (Python bytes from NAPI-RS)
- Update all package READMEs with usage examples and human/AI attribution
- Enrich `example/example.dart` across all packages
- Add README and example doctest coverage (20 integration tests)
- Remove 8 obsolete planning docs

## 0.6.0

- **BREAKING**: Rename `dart_monty_desktop` to `dart_monty_native`
- **BREAKING**: Collapse `DartMontyWeb` to registration-only shim
- **BREAKING**: Add `BaseMontyPlatform` + `MontyCoreBindings` architecture
- Add `MontySession` API for state persistence (`run()`, `start()`, `resume()`)
- Add `MontyStateMixin` for shared state management across platforms
- Add capability interfaces (`MontyFutureCapable`, `MontySnapshotCapable`)
- Extract shared contract test harness (`LadderRunner`, `LadderAssertions`)
- Fix `restore()` to set restored instance to active state

## 0.4.3

- Fix vendored macOS dylib `install_name` pointing to CI runner path instead of `@rpath` (#47)
- Add `build.rs` to set `@rpath` install_name at compile time on macOS
- Add `install_name_tool` safety net in release CI workflow

## 0.4.2

- Plumb async/futures API through desktop Isolate bridge (`resumeAsFuture()`, `resolveFutures()`, `resolveFuturesWithErrors()`)
- Override async/futures methods in web extension with `UnsupportedError`
- Add tier 4 function parameter fixtures (keyword-only, mixed args/kwargs, forwarding, positional-only)
- Enable tier 13 async ladder fixtures (remove xfail)
- Add "Async gather" and "Function params" examples to desktop and web example apps
- Expand web ladder runner to tiers 1-9, 13, 15

## 0.4.1

- Extract reusable publish workflow for all 6 packages
- Add path filters to skip CI on docs-only changes
- Extract enforce-coverage composite action (DRY)

## 0.4.0

- Add `MontyResolveFutures` progress variant for async/futures support (M13)
- Add `resumeAsFuture()`, `resolveFutures()`, `resolveFuturesWithErrors()` to platform API
- Add `MONTY_PROGRESS_RESOLVE_FUTURES` tag and `FutureSnapshot` handling in Rust C FFI
- Implement futures support in FFI and WASM packages (WASM stubs with `UnsupportedError`)
- Add tier 13 async/futures ladder fixtures (IDs 170-175)

## 0.3.5

- Add `scriptName`, `excType`, `traceback`, `kwargs`, `callId`, `methodCall` to data models
- Add Rust C FFI accessors and `script_name` parameter for richer run/start metadata
- Reject invalid UTF-8 in native FFI external function names and script names
- Wire FFI bindings to expose new native accessors to Dart
- Wire WASM JS bridge: kwargs, callId, scriptName, excType, and traceback in worker responses
- Fix worker onerror to reject pending promises on crash
- Fix `restore()` state machine to return active instance
- Fix FFI error paths to parse full error JSON (excType, traceback, filename)
- Add ladder test fixtures for tiers 8 (kwargs/callId), 9 (exceptions/traceback), 15 (scriptName)
- Xfail pre-existing try-except and syntax error ladder fixtures
- Add Flutter web extension (dart_monty_web) with 52 unit tests
- Add Flutter web example app with sorting visualizer, TSP, and ladder runner
- Deploy Flutter web app to GitHub Pages at /flutter/

## 0.3.4

- Initial release.
