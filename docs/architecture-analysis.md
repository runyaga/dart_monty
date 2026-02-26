# dart_monty Architecture Analysis

**Date:** 2026-02-25
**Branch:** `worktree-arch-analysis`
**Methodology:** Layer-by-layer SOLID analysis via Gemini 3.1-pro, cross-referenced with source

---

## 1. What We Have Today

dart_monty is a **federated Flutter plugin** that exposes pydantic's Monty sandboxed
Python interpreter to Dart/Flutter applications. It runs Python code on **desktop (FFI
into Rust)** and **web (WASM via JS Worker)** with cross-platform parity verified by a
shared test ladder.

### Layer Cake (Bottom to Top)

```text
┌─────────────────────────────────────────────────────┐
│  Flutter App / Agent Framework (consumer)            │
├─────────────────────────────────────────────────────┤
│  dart_monty_native          dart_monty_web          │  ← Flutter plugins (register)
│    ├─ Isolate RPC              ├─ Delegate to WASM   │
│    └─ NativeIsolateBindings          └─ WasmBindings       │
├─────────────────────────────────────────────────────┤
│  dart_monty_ffi              dart_monty_wasm          │  ← Pure Dart impl packages
│    ├─ MontyFfi                 ├─ MontyWasm           │
│    ├─ NativeBindings           ├─ WasmBindings        │
│    └─ NativeBindingsFfi        └─ WasmBindingsJs      │
├─────────────────────────────────────────────────────┤
│  dart_monty_platform_interface                        │  ← Abstract contract (pure Dart)
│    ├─ MontyPlatform (sealed progress, data models)    │
│    ├─ MontyStateMixin (state machine)                 │
│    └─ Testing harness (LadderRunner)                  │
├─────────────────────────────────────────────────────┤
│  native/ (Rust C FFI)        @pydantic/monty (WASM)  │  ← Runtime engines
│    └─ MontyHandle               └─ Web Worker         │
└─────────────────────────────────────────────────────┘
```

### Key Numbers

| Metric | Value |
|--------|-------|
| Dart packages | 5 (interface, ffi, wasm, desktop, web) |
| Rust source files | 4 (lib, handle, convert, error) |
| API coverage | ~40% of upstream monty surface |
| Refactoring slices | 5/9 complete (0-5 done, 6-9 pending) |
| Active branch focus | Slice 7 (desktop & WASM refinement) |

---

## 2. SOLID Analysis by Layer

### 2.1 Platform Interface (`dart_monty_platform_interface`)

| Principle | Rating | Key Evidence |
|-----------|--------|--------------|
| **S** — Single Responsibility | **Strong** | Data classes are anemic holders with serialization. State machine is a separate mixin. Progress states are isolated domain models. |
| **O** — Open/Closed | **Strong** | `sealed class MontyProgress` forces exhaustive `switch`. New platforms extend without modifying the interface. |
| **L** — Liskov Substitution | **Adequate** | `rejectInputs()` allows subclasses to throw `UnsupportedError` for `inputs` — a client calling `run(code, inputs: {...})` can't trust the base type unconditionally. |
| **I** — Interface Segregation | **Weak** | `MontyPlatform` is a **fat interface**: simple run, iterative execution, futures resolution, and snapshots are all one class. Web throws `UnsupportedError` for 3 methods. |
| **D** — Dependency Inversion | **Strong** | Textbook DIP. Both high-level (app) and low-level (ffi, wasm) depend on this abstraction. Arrows point inward. |

**Abstraction Leaks:**

- JSON serialization baked into every data class (`fromJson`/`toJson`) — assumes message-passing transport
- Python-specific semantics in `MontyException.excType` and `MontyStackFrame` docs referencing "monty TracebackFrame"

**Missing Abstractions:**
- No `MontyTypeCodec` for Dart-to-Python type marshaling
- No stdin/filesystem abstraction (only stdout capture via `printOutput`)

### 2.2 FFI Layer (`dart_monty_ffi`)

| Aspect | Rating | Detail |
|--------|--------|--------|
| Separation of Concerns | **9/10** | `NativeBindings` strips `Pointer<T>` to primitive `int` handles. `MontyFfi` never sees `dart:ffi`. |
| Adapter Pattern | **Clean** | `MontyFfi` maps raw `RunResult`/`ProgressResult` (int tags + JSON) to rich domain objects. |
| Memory Management | **Good, with risks** | `try/finally` for handles. `_readAndFreeString` for C strings. **Risk:** sequential allocations before `try` block — if alloc 2 throws, alloc 1 leaks. Fix: use `Arena`. |
| Error Handling | **Robust** | C tags + JSON → `MontyException` with full tracebacks. Minor: invalid JSON from C would leak as `FormatException`. |
| Testability | **Excellent** | `NativeBindings` is pure Dart interface with primitives — trivially mockable. |
| DRY | **Needs work** | Handle/state assertions duplicated across 5+ methods. FFI boilerplate (`outError` alloc, `_buildProgressResult`) repeated identically. |

### 2.3 WASM Layer (`dart_monty_wasm`)

| Aspect | Rating | Detail |
|--------|--------|--------|
| Bridge Pattern | **Functional** | Dart → `dart:js_interop` → `window.DartMontyBridge` → `postMessage` → Worker → WASM. |
| Serialization | **JSON-over-strings** | All data including binary (`snapshot`) goes through Base64-in-JSON. No zero-copy. |
| Error Mapping | **Result pattern** | JS bridge returns `{ok: false, error: ...}` instead of throwing — Dart maps to `MontyException`. |
| Shared Contract with FFI | **None** | Ad-hoc duplication. Same conceptual API, different signatures (sync vs async, handles vs implicit). |
| State tracking | **Implicit** | Worker holds session state. No handle/ID system. Single session per Worker. |

### 2.4 Native Plugin (`dart_monty_native`)

| Aspect | Rating | Detail |
|--------|--------|--------|
| Composition | **Clean** | Flutter registration → `MontyNative` → `NativeIsolateBindingsImpl` → `MontyFfi`. |
| Isolate Strategy | **Sound** | Same-group isolate with correlation-ID RPC. Domain objects pass directly (no JSON). |
| Unnecessary Wrapping | **Yes** | `NativeRunResult`/`NativeProgressResult` wrap `MontyResult`/`MontyProgress` with zero added value. Should return domain types directly. |
| Flutter Coupling | **Minimal** | No `package:flutter` imports in core files. Only `registerWith` ties to Flutter's plugin system. |

### 2.5 Rust C FFI (`native/`)

| Aspect | Rating | Detail |
|--------|--------|--------|
| Handle Design | **Sound** | `Box::into_raw` / `Box::from_raw`. Internal `HandleState` enum prevents double-execution. |
| Panic Safety | **Excellent** | `catch_ffi_panic` wraps all entry points. Panics → `out_error` strings. |
| Pointer Safety | **Good, 3 risks** | (1) `CStr::from_ptr` trusts NUL termination, (2) cross-allocator free possible, (3) Dart must `monty_string_free` every returned string. |
| Extensibility | **Rigid** | Handle state machine is single-use. REPL needs `ReplReady` state. Type checker needs bypass of `MontyHandle` entirely. |
| Dart Constraints | **Significant** | Single-use handles (no persistent environments), binary data goes through JSON array of ints, no object references. |

### 2.6 Testing Harness (`ladder_runner` + `ladder_assertions`)

| Aspect | Rating |
|--------|--------|
| Strategy Pattern | **Excellent** — JSON fixtures + `createPlatform` factory = fully decoupled |
| Cross-Platform | **Proven** — same fixtures run on FFI, WASM, and mock |
| Extensibility | **High** — pattern works for any input/output verification scenario |
| Coupling Risk | **Low** — `jsonEncode(actual) == jsonEncode(expected)` limits complex object assertion |

---

## 3. Refactoring Opportunities

### 3.1 Interface Segregation (High Impact)

**Problem:** `MontyPlatform` is a fat interface. Web throws `UnsupportedError` for 3 methods.

**Proposal:** Split into composable capabilities:

```dart
/// Core — every platform MUST implement
abstract class MontyPlatform {
  Future<MontyResult> run(String code, {MontyLimits? limits, String? scriptName});
  Future<MontyProgress> start(String code, {List<String>? externalFunctions, ...});
  Future<MontyProgress> resume(Object? returnValue);
  Future<MontyProgress> resumeWithError(String errorMessage);
  Future<void> dispose();
}

/// Optional capability — only implement if the backend supports it
abstract class MontySnapshotCapable {
  Future<Uint8List> snapshot();
  Future<MontyPlatform> restore(Uint8List data);
}

/// Optional capability — async/futures resolution
abstract class MontyFutureCapable {
  Future<MontyProgress> resumeAsFuture();
  Future<MontyProgress> resolveFutures(Map<int, Object?> results);
  Future<MontyProgress> resolveFuturesWithErrors(Map<int, Object?> results, Map<int, String> errors);
}
```

Consumers check capabilities: `if (platform is MontySnapshotCapable) { ... }`

### 3.2 Unified Bindings Contract (Medium Impact)

**Problem:** `NativeBindings` and `WasmBindings` have identical conceptual APIs but no shared contract. Logic for state assertions, JSON decoding, and error mapping is duplicated across `MontyFfi` and `MontyWasm`.

**Proposal:** Extract a `MontyCoreBindings` interface with `Future`-based signatures. FFI wraps sync calls in `Future.value()` (or better, runs them on an Isolate). WASM keeps its natural async. Shared `BaseMontyPlatform` handles state machine, error mapping, and JSON decoding once:

```dart
abstract class MontyCoreBindings {
  Future<CoreRunResult> run(String code, {String? limitsJson});
  Future<CoreProgressResult> start(String code, {String? extFnsJson, ...});
  Future<CoreProgressResult> resume(String valueJson);
  Future<void> destroy();
}

abstract class BaseMontyPlatform extends MontyPlatform with MontyStateMixin {
  BaseMontyPlatform(this._bindings);
  final MontyCoreBindings _bindings;

  @override
  Future<MontyResult> run(String code, ...) async {
    assertNotDisposed('run');
    assertIdle('run');
    final result = await _bindings.run(code, limitsJson: _encodeLimits(limits));
    return _translateRunResult(result); // SHARED — written once
  }
}
```

**Impact:** Eliminates ~300-400 lines of duplicated state/error/JSON logic.

### 3.3 DRY Extraction in FFI Boilerplate (Low-Medium Impact)

**Problem:** `MontyFfi` repeats handle-assertion + state-check across 5+ methods. `NativeBindingsFfi` repeats `outError` alloc + `_buildProgressResult` identically.

**Fix:**

```dart
// In MontyFfi:
Future<MontyProgress> _withActiveHandle(String caller, Future<MontyProgress> Function(int) action) async {
  assertNotDisposed(caller);
  assertActive(caller);
  final handle = _handle ?? (throw StateError('Cannot $caller: no active handle'));
  return action(handle);
}

// In NativeBindingsFfi:
ProgressResult _callProgress(int handle, int Function(Pointer<MontyHandle>, Pointer<Pointer<Char>>) fn) {
  final ptr = Pointer<MontyHandle>.fromAddress(handle);
  final outError = calloc<Pointer<Char>>();
  try {
    final tag = fn(ptr, outError);
    return _buildProgressResult(ptr, tag, outError.value);
  } finally {
    calloc.free(outError);
  }
}
```

### 3.4 Arena-Based Memory Safety in FFI (Low Impact, High Value)

**Problem:** Sequential `calloc` allocations before `try` block — if alloc N throws, allocs 1..N-1 leak.

**Fix:** Use `package:ffi`'s `using((Arena arena) { ... })` pattern:

```dart
RunResult run(int handle, {String? limitsJson}) {
  return using((Arena arena) {
    final cCode = code.toNativeUtf8(allocator: arena).cast<Char>();
    final outError = arena<Pointer<Char>>();
    // ...all allocations tracked by arena, freed automatically
  });
}
```

### 3.5 Remove Desktop Wrapper Types (Quick Win)

**Problem:** `NativeRunResult` and `NativeProgressResult` wrap domain types with zero added value.

**Fix:** `NativeIsolateBindings` returns `Future<MontyResult>` and `Future<MontyProgress>` directly. Delete the wrapper classes.

### 3.6 Type Codec Abstraction (Future-Facing)

**Problem:** Dart↔Python type translation is invisible, scattered in JSON encoding/decoding across FFI and WASM layers. Adding a new type (e.g., `DateTime` ↔ `datetime`) requires touching every platform.

**Proposal:** `MontyTypeCodec` — a pluggable registry for encoding/decoding:

```dart
abstract class MontyTypeCodec {
  Object? encode(Object? dartValue);   // Dart → JSON-safe for Python
  Object? decode(Object? pythonValue); // Python JSON → Dart types
}
```

This becomes essential for M8 (Rich Type Bridge: `$tuple`, `$set`, `$bytes`, dataclass).

---

## 4. Evolved Design

Taking the refactoring opportunities together, here's the evolved architecture:

```text
┌─────────────────────────────────────────────────────────┐
│  Consumer: Flutter App / Agent / CLI                     │
├──────────┬──────────────────────────────┬───────────────┤
│ Capability checks:                      │               │
│  platform is MontySnapshotCapable?      │               │
│  platform is MontyFutureCapable?        │               │
│  platform is MontyReplCapable?          │               │
├──────────┴──────────────────────────────┴───────────────┤
│  BaseMontyPlatform                                       │
│    ├─ MontyStateMixin (state machine — SHARED)           │
│    ├─ Error mapping (JSON → MontyException — SHARED)     │
│    ├─ MontyTypeCodec (type translation — SHARED)         │
│    └─ Delegates to MontyCoreBindings                     │
├──────────┬──────────────────────────────┬───────────────┤
│  FfiCoreBindings                        │ WasmCoreBindings │
│  (NativeBindingsFfi + Arena)            │ (WasmBindingsJs) │
│  wrapped in Isolate for                 │ naturally async   │
│  non-blocking execution                 │                   │
├──────────┴──────────────────────────────┴───────────────┤
│  MontyPlatform (slim: run, start, resume, dispose)       │
│  + MontySnapshotCapable (optional mixin)                 │
│  + MontyFutureCapable (optional mixin)                   │
│  + MontyReplCapable (future: M12)                        │
│  + MontyTypeCheckCapable (future: M14)                   │
├─────────────────────────────────────────────────────────┤
│  native/ Rust FFI             @pydantic/monty WASM       │
└─────────────────────────────────────────────────────────┘
```

### What Changes

1. **Fat interface → capability interfaces** — no more `UnsupportedError`
2. **Duplicated platform logic → `BaseMontyPlatform`** — state, errors, JSON decoded once
3. **Ad-hoc bindings → `MontyCoreBindings` contract** — FFI and WASM implement the same interface
4. **Untyped `Object?` → `MontyTypeCodec`** — pluggable type bridge for M8+
5. **Wrapper types eliminated** — `NativeRunResult` etc. deleted
6. **Arena-based FFI** — no leak risks from sequential allocations
7. **Future capabilities slot in cleanly** — REPL (M12), type checking (M14), OS calls (M11) each get their own capability interface

### Extension Story

| "I want to..." | How |
|-----------------|-----|
| Add a new platform (iOS) | Implement `MontyCoreBindings`, extend `BaseMontyPlatform` |
| Add a new execution mode (REPL) | Add `MontyReplCapable` interface, implement in backends that support it |
| Add a new Python type | Register a codec in `MontyTypeCodec` — all platforms get it for free |
| Add a new progress state | Add subclass to `sealed MontyProgress` — compiler enforces exhaustive handling |
| Run in a CLI (no Flutter) | Use `BaseMontyPlatform` + `FfiCoreBindings` directly — no Flutter dependency |

---

## 5. Novel Use Cases

### 5.1 Use Case: Sandboxed Data Pipeline DSL

**Scenario:** A Flutter app lets users define data transformation pipelines (filter, map, aggregate) using Python syntax. The app provides a visual pipeline builder, but the execution engine is Monty.

**How it fits the architecture:**

```text
User builds pipeline in UI
  → generates Python code: "result = df.filter(age > 30).map(name.upper()).agg(count)"
  → run() with inputs: {'df': [...rows...]}
  → MontyTypeCodec encodes List<Map> → Python list-of-dicts
  → Monty executes the pipeline in sandbox
  → MontyTypeCodec decodes result → Dart List<Map>
  → UI renders data table
```

**Why the evolved architecture helps:**
- `MontyTypeCodec` is critical — tabular data needs rich type round-tripping
- `BaseMontyPlatform` means the same pipeline runs on desktop (FFI/Isolate) and web (WASM)
- Resource limits (`MontyLimits`) prevent runaway user scripts
- `MontySnapshotCapable` enables "save pipeline state" / "resume from checkpoint"
- No `UnsupportedError` surprises — web gracefully degrades on unsupported features

**Stress test for the architecture:**
- Large dataset inputs test the binary/JSON bottleneck (validates need for `MontyTypeCodec` with efficient binary paths)
- Streaming results test the progress model (validates M7B print streaming)
- User-defined functions in the pipeline test the external function callback loop

### 5.2 Use Case: Multi-Tenant AI Agent Code Executor

**Scenario:** A server-side Dart application hosts multiple AI agents. Each agent can execute Python tool code in an isolated Monty sandbox. Agents run concurrently. Each agent gets its own sandbox with different resource limits and external function sets.

**How it fits the architecture:**

```text
Agent 1 ──→ MontyNative(Isolate 1) ──→ FFI Handle 1 ──→ Rust Sandbox 1
Agent 2 ──→ MontyNative(Isolate 2) ──→ FFI Handle 2 ──→ Rust Sandbox 2
Agent 3 ──→ MontyNative(Isolate 3) ──→ FFI Handle 3 ──→ Rust Sandbox 3
                                           │
                                    BaseMontyPlatform (shared logic)
                                    MontyCoreBindings (shared contract)
```

**Why the evolved architecture helps:**
- **Capability interfaces** — server doesn't need snapshots? Don't implement `MontySnapshotCapable`
- **`BaseMontyPlatform` + `MontyCoreBindings`** — each Isolate gets its own bindings instance. No singleton. This is critical — the current `MontyPlatform.instance` singleton pattern breaks for multi-tenant
- **`MontyFutureCapable`** — agents can issue concurrent `asyncio.gather` calls (M13), essential for parallel tool execution
- **`MontyReplCapable`** (M12) — agents can maintain conversational Python state across turns
- **`MontyTypeCodec`** — agents receive typed results (not `Object?`) from tool calls
- **Isolate-per-agent** — natural concurrency, no GIL concerns, each sandbox is truly isolated

**Stress test for the architecture:**
- Multi-instance validates that the design isn't coupled to Flutter's singleton pattern
- Concurrent execution validates Isolate safety of the FFI layer
- Per-agent resource limits validate that `MontyLimits` is per-handle, not global
- Agent state persistence (snapshot/restore) validates cross-restart durability
- External function sets per-agent test that the callback mechanism is instance-scoped

---

## 6. Summary of Recommendations

| Priority | Recommendation | Impact | Aligns With |
|----------|---------------|--------|-------------|
| **P0** | Split `MontyPlatform` into capability interfaces | Eliminates `UnsupportedError`, enables clean multi-tenant | M12, M14, M11 |
| **P0** | Extract `BaseMontyPlatform` with shared logic | ~400 lines deduplication, single point for error/state/JSON | Slice 6-8 |
| **P1** | Introduce `MontyCoreBindings` contract | Unifies FFI and WASM behind same interface | Slice 8 |
| **P1** | Arena-based FFI memory | Eliminates leak risks | Slice 8 |
| **P2** | Delete `NativeRunResult`/`NativeProgressResult` | Remove unnecessary wrapping | Slice 7 |
| **P2** | Extract `MontyTypeCodec` | Pluggable type bridge for M8 | M8 |
| **P3** | Decouple from singleton pattern | Enable multi-instance (CLI, server, multi-agent) | M9, novel use cases |

---

## 7. Architecture Diagrams

### 7.1 BEFORE: Current Class Hierarchy

```text
                        ┌──────────────────────────────┐
                        │      PlatformInterface       │
                        │        (flutter pkg)         │
                        └──────────────┬───────────────┘
                                       │ extends
                        ┌──────────────┴───────────────┐
                        │       MontyPlatform           │
                        │    (FAT INTERFACE: 10 methods)│
                        │                               │
                        │  run()                        │
                        │  start()                      │
                        │  resume()                     │
                        │  resumeWithError()            │
                        │  resumeAsFuture()        ◄──── web throws UnsupportedError
                        │  resolveFutures()        ◄──── web throws UnsupportedError
                        │  resolveFuturesWithErrors()◄── web throws UnsupportedError
                        │  snapshot()                   │
                        │  restore()                    │
                        │  dispose()                    │
                        └──────┬──────────┬─────────────┘
                               │          │
            ┌──────────────────┤          ├───────────────────┐
            │                  │          │                    │
   ┌────────┴────────┐  ┌─────┴──────┐  ┌┴────────────┐  ┌───┴──────────┐
   │   MontyFfi      │  │ MontyWasm  │  │MontyNative  │  │ DartMontyWeb │
   │ with StateMixin │  │ w/ Mixin   │  │ w/ Mixin     │  │ (delegate)   │
   │                 │  │            │  │              │  │              │
   │ 340 lines       │  │ 274 lines  │  │ 186 lines    │  │ 110 lines    │
   │ ALL 10 methods  │  │ 10 methods │  │ ALL 10       │  │ 10 methods   │
   │ + _handleProg   │  │ 3 throw!   │  │ + wrappers   │  │ 3 throw!     │
   │ + _decodeResult │  │ + _translate│  │              │  │              │
   │ + _applyLimits  │  │ + _encode  │  │              │  │              │
   │ + _freeHandle   │  │ + _parse   │  │              │  │              │
   └────────┬────────┘  └─────┬──────┘  └──────┬───────┘  └───┬──────────┘
            │                 │                │               │
            │ uses            │ uses           │ uses          │ delegates to
   ┌────────┴────────┐  ┌────┴───────┐  ┌─────┴──────┐       │ MontyWasm
   │ NativeBindings  │  │WasmBindings│  │DesktopBinds│       │
   │  (abstract)     │  │ (abstract) │  │ (abstract)  │       │
   │                 │  │            │  │             │       │
   │  14 sync methods│  │12 async    │  │12 async     │       │
   │  int handles    │  │JSON strings│  │wrapper types│       │
   └────────┬────────┘  └────┬───────┘  └─────┬───────┘       │
            │                │                │               │
   ┌────────┴────────┐  ┌────┴───────┐  ┌─────┴──────────┐   │
   │NativeBindingsFfi│  │WasmBindsJs │  │DesktopBindsIsol│   │
   │  (dart:ffi)     │  │(js_interop)│  │  (Isolate RPC) │   │
   │  305 lines      │  │ 210 lines  │  │  426 lines     │   │
   └─────────────────┘  └────────────┘  └────────────────┘   │
                                              │               │
                                              │ spawns        │
                                              ▼               │
                                        ┌──────────┐         │
                                        │ MontyFfi │ ◄───────┘
                                        │(in Isolate)
                                        └──────────┘
```

### 7.2 Duplicated Logic Heatmap

The following logic is implemented **independently** in both `MontyFfi` and `MontyWasm`:

```text
  MontyFfi (340 lines)                    MontyWasm (274 lines)
  ════════════════════                    ═══════════════════════

  ┌─────────────────────────────┐        ┌─────────────────────────────┐
  │ State guards                │        │ State guards                │
  │  assertNotDisposed('run')   │◄══DUP══►  assertNotDisposed('run')   │
  │  assertIdle('run')          │        │  assertIdle('run')          │
  │  rejectInputs(inputs)      │        │  rejectInputs(inputs)       │
  └─────────────────────────────┘        └─────────────────────────────┘

  ┌─────────────────────────────┐        ┌─────────────────────────────┐
  │ Limits encoding             │        │ Limits encoding             │
  │  _applyLimits() [3 calls]  │◄══DUP══►  _encodeLimits() [JSON map] │
  │  (imperative set* calls)    │        │  (declarative JSON encode)  │
  └─────────────────────────────┘        └─────────────────────────────┘

  ┌─────────────────────────────┐        ┌─────────────────────────────┐
  │ Run result → MontyResult    │        │ Run result → MontyResult    │
  │  _decodeRunResult()         │◄══DUP══►  _translateRunResult()      │
  │  JSON → MontyResult.fromJson│        │  fields → MontyResult()     │
  │  error → MontyException     │        │  error → MontyException     │
  └─────────────────────────────┘        └─────────────────────────────┘

  ┌─────────────────────────────┐        ┌─────────────────────────────┐
  │ Progress → MontyProgress    │        │ Progress → MontyProgress    │
  │  _handleProgress()          │◄══DUP══►  _translateProgress()       │
  │  tag 0 → MontyComplete      │        │  'complete' → MontyComplete │
  │  tag 1 → MontyPending       │        │  'pending' → MontyPending   │
  │  tag 2 → MontyException     │        │  !ok → MontyException       │
  │  tag 3 → MontyResolveFutures│        │  'resolve_futures' → same   │
  │  handle lifecycle mgmt      │        │  state machine transitions  │
  └─────────────────────────────┘        └─────────────────────────────┘

  ┌─────────────────────────────┐        ┌─────────────────────────────┐
  │ Traceback parsing           │        │ Traceback parsing           │
  │  MontyException.fromJson()  │◄══DUP══►  _parseTraceback() →        │
  │  (handles JSON internally)  │        │  MontyStackFrame.listFromJson│
  └─────────────────────────────┘        └─────────────────────────────┘

  Estimated shared logic: ~150 lines duplicated across the two files
```

### 7.3 AFTER: Refactored Class Hierarchy

```text
                      ┌──────────────────────────────┐
                      │      PlatformInterface       │
                      └──────────────┬───────────────┘
                                     │ extends
                      ┌──────────────┴───────────────┐
                      │       MontyPlatform           │
                      │    (SLIM: 5 core methods)     │
                      │                               │
                      │  run()                        │
                      │  start()                      │
                      │  resume()                     │
                      │  resumeWithError()            │
                      │  dispose()                    │
                      └──────────────┬───────────────┘
                                     │ extends
              ┌──────────────────────┴───────────────────────┐
              │          BaseMontyPlatform                    │
              │         with MontyStateMixin                  │
              │                                              │
              │  SHARED LOGIC (~120 lines):                   │
              │  ● run()      → bindings.run() → translate   │
              │  ● start()    → bindings.start() → translate │
              │  ● resume()   → bindings.resume() → translate│
              │  ● dispose()  → bindings.dispose()           │
              │  ● translateRunResult()    ◄── WRITTEN ONCE   │
              │  ● translateProgress()     ◄── WRITTEN ONCE   │
              │  ● encodeLimits()          ◄── WRITTEN ONCE   │
              │  ● encodeExternalFns()     ◄── WRITTEN ONCE   │
              │                                              │
              │  Delegates to: MontyCoreBindings              │
              └───────┬────────────────────┬─────────────────┘
                      │                    │
         ┌────────────┴──┐           ┌─────┴───────────┐
         │   MontyFfi    │           │   MontyWasm      │
         │   ~60 lines   │           │   ~40 lines      │
         │               │           │                  │
         │ + snapshot()  │           │ + snapshot()     │
         │ + restore()   │           │ + restore()      │
         │ + resumeAs..  │           │                  │
         │ + resolveFu.. │           │                  │
         └───────────────┘           └──────────────────┘
               │                            │
               │ implements                  │ implements
               ▼                            ▼
    ┌──────────────────┐          ┌──────────────────┐
    │MontySnapshotCapable│        │MontySnapshotCapable│
    │MontyFutureCapable │          └──────────────────┘
    └──────────────────┘

  ┌─────────────────────────────────────────────────────────┐
  │              Capability Interfaces                       │
  │                                                         │
  │  ┌─────────────────────┐   ┌─────────────────────────┐ │
  │  │MontySnapshotCapable │   │  MontyFutureCapable      │ │
  │  │                     │   │                          │ │
  │  │  snapshot()         │   │  resumeAsFuture()        │ │
  │  │  restore()          │   │  resolveFutures()        │ │
  │  │                     │   │  resolveFuturesWithErrors()│
  │  └─────────────────────┘   └─────────────────────────┘ │
  │                                                         │
  │  Consumer checks:  if (platform is MontyFutureCapable)  │
  │                    if (platform is MontySnapshotCapable) │
  └─────────────────────────────────────────────────────────┘
```

### 7.4 MontyCoreBindings + Adapter Pattern

```text
  ┌─────────────────────────────────────────────────────────────────────┐
  │                    MontyCoreBindings (abstract)                     │
  │                 Unified contract — all Future-based                 │
  │                                                                     │
  │   init()                    resume(valueJson)                       │
  │   run(code, limitsJson)     resumeWithError(errorMessage)           │
  │   start(code, extFnsJson)   resumeAsFuture()                       │
  │   snapshot()                resolveFutures(resultsJson, errorsJson) │
  │   restore(data)             dispose()                               │
  └───────────────────────┬────────────────────┬────────────────────────┘
                          │                    │
               implements │                    │ implements
                          │                    │
           ┌──────────────┴──────┐   ┌─────────┴──────────────┐
           │  FfiCoreBindings    │   │  WasmCoreBindings       │
           │  (ADAPTER)          │   │  (ADAPTER)              │
           │  ~80 lines          │   │  ~60 lines              │
           │                     │   │                         │
           │  sync → Future      │   │  WasmResult → CoreResult│
           │  int handle mgmt    │   │  WasmProgress → Core    │
           │  JSON → CoreResult  │   │  synthetic usage → null │
           │  tag enum → state   │   │  state string → state   │
           └──────────┬──────────┘   └──────────┬──────────────┘
                      │ wraps                    │ wraps
                      │                          │
           ┌──────────┴──────────┐   ┌───────────┴─────────────┐
           │  NativeBindings     │   │  WasmBindings            │
           │  (UNTOUCHED)        │   │  (UNTOUCHED)             │
           │                     │   │                          │
           │  14 sync methods    │   │  12 async methods        │
           │  int handles        │   │  JSON strings            │
           │  RunResult struct   │   │  WasmRunResult struct    │
           │  ProgressResult     │   │  WasmProgressResult      │
           └──────────┬──────────┘   └───────────┬─────────────┘
                      │ impl                     │ impl
           ┌──────────┴──────────┐   ┌───────────┴─────────────┐
           │ NativeBindingsFfi   │   │ WasmBindingsJs           │
           │ (UNTOUCHED)         │   │ (UNTOUCHED)              │
           │ dart:ffi pointers   │   │ dart:js_interop          │
           └─────────────────────┘   └─────────────────────────┘
```

### 7.5 Call Flow: `run()` — Before vs After

**BEFORE** — duplicated translation logic in each platform:

```text
  Consumer: platform.run('2+2', limits: MontyLimits(timeoutMs: 1000))
                │
       ┌────────┴────────────────────────────┐
       │                                     │
  MontyFfi.run()                        MontyWasm.run()
       │                                     │
  assertNotDisposed ◄─── DUPLICATED ───► assertNotDisposed
  assertIdle        ◄─── DUPLICATED ───► assertIdle
  rejectInputs      ◄─── DUPLICATED ───► rejectInputs
       │                                     │
  _applyLimits()                        _encodeLimits()
  ├─ setMemoryLimit()                   ├─ build JSON map
  ├─ setTimeLimitMs()                   └─ json.encode()
  └─ setStackLimit()                         │
       │                                     │
  create(code) → handle                 _ensureInitialized()
  run(handle) → RunResult               _bindings.run(code) → WasmRunResult
       │                                     │
  _decodeRunResult()                    _translateRunResult()
  ├─ json.decode()   ◄── DUPLICATED ──► ├─ check ok
  ├─ MontyResult.fromJson()             │ ├─ MontyResult(value, _syntheticUsage)
  └─ MontyException.fromJson()          │ └─ MontyException(message, excType)
       │                                └─ _parseTraceback()
  free(handle)                               │
       │                                     │
       └────────┬────────────────────────────┘
                │
          MontyResult returned
```

**AFTER** — shared logic in BaseMontyPlatform:

```text
  Consumer: platform.run('2+2', limits: MontyLimits(timeoutMs: 1000))
                │
       BaseMontyPlatform.run()     ◄── SHARED (written once)
                │
       assertNotDisposed('run')
       assertIdle('run')
       rejectInputs(inputs)
       _ensureInitialized()
                │
       encodeLimits(limits) → String?   ◄── SHARED
                │
       bindings.run(code, limitsJson: ...)
                │
       ┌────────┴────────────────────────────┐
       │                                     │
  FfiCoreBindings.run()               WasmCoreBindings.run()
       │                                     │
  create(code) → handle              _wasm.run(code, limitsJson)
  _applyLimits(handle)               → WasmRunResult
  _native.run(handle)                     │
  → RunResult                        map to CoreRunResult
       │                             (null usage → synthetic zeros
  _decodeRunResult()                  filled in by Base)
  → CoreRunResult                         │
       │                                  │
  free(handle)                            │
       │                                  │
       └────────┬────────────────────────────┘
                │
       CoreRunResult returned to Base
                │
       translateRunResult()    ◄── SHARED (written once)
       ├─ ok → MontyResult(value, usage ?? syntheticZeros)
       └─ error → throw MontyException(message, excType, traceback)
                │
          MontyResult returned
```

### 7.6 Desktop Isolate Integration — Before vs After

**BEFORE:**

```text
  ┌────────────────────────────────────────────────────────────┐
  │  MAIN ISOLATE                                              │
  │                                                            │
  │  MontyNative                                              │
  │  ├─ 10 methods (all MontyPlatform)                         │
  │  ├─ state guards (assertIdle, assertActive, etc.)          │
  │  ├─ _handleProgress() — state transitions                  │
  │  └─ calls NativeIsolateBindingsImpl                           │
  │       │                                                    │
  │       │ SendPort/ReceivePort RPC                           │
  │       │ sends: _RunRequest, _StartRequest, etc.            │
  │       │ receives: _RunResponse(NativeRunResult), etc.     │
  │       │            ─────────────┬──────                    │
  │       │                         │                          │
  │       │            NativeRunResult ◄── UNNECESSARY WRAPPER│
  │       │            NativeProgressResult ◄── DITTO         │
  └───────┼─────────────────────────┼──────────────────────────┘
          │                         │
  ┌───────┼─────────────────────────┼──────────────────────────┐
  │  BACKGROUND ISOLATE             │                          │
  │                                 │                          │
  │  MontyFfi(NativeBindingsFfi)    │                          │
  │  ├─ Full 340-line implementation│                          │
  │  ├─ _handleProgress()          │                          │
  │  ├─ _decodeRunResult()         │                          │
  │  └─ all translation logic       │                          │
  │                                 │                          │
  │  Returns MontyResult/MontyProgress ─────────►              │
  │  (wrapped in NativeRunResult/NativeProgressResult)       │
  └────────────────────────────────────────────────────────────┘
```

**AFTER:**

```text
  ┌────────────────────────────────────────────────────────────┐
  │  MAIN ISOLATE                                              │
  │                                                            │
  │  MontyNative                                              │
  │  ├─ implements MontySnapshotCapable, MontyFutureCapable    │
  │  ├─ state guards + _handleProgress()                       │
  │  └─ calls NativeIsolateBindings (returns domain types directly)  │
  │       │                                                    │
  │       │ SendPort/ReceivePort RPC                           │
  │       │ NO wrapper types                                   │
  └───────┼────────────────────────────────────────────────────┘
          │
  ┌───────┼────────────────────────────────────────────────────┐
  │  BACKGROUND ISOLATE                                        │
  │                                                            │
  │  MontyFfi(FfiCoreBindings(NativeBindingsFfi))              │
  │  ├─ extends BaseMontyPlatform (~60 lines)                  │
  │  ├─ shared translateRunResult()                            │
  │  ├─ shared translateProgress()                             │
  │  └─ capability methods only (snapshot, restore, futures)   │
  └────────────────────────────────────────────────────────────┘
```

### 7.7 Commit Progression

```text
  COMMIT 1: Capability Interfaces + Slim MontyPlatform
  ═══════════════════════════════════════════════════════

  MontyPlatform: 10 methods → 5 methods (remove futures + snapshot)
                                            │
                            ┌───────────────┼───────────────┐
                            │               │               │
                   MontySnapshotCapable  MontyFutureCapable  │
                   │  snapshot()        │  resumeAsFuture()  │
                   │  restore()         │  resolveFutures()  │
                   │                    │  resolveFuturesW() │
                   │                    │                    │
    MontyFfi ──────┤────────────────────┤  (implements both)
    MontyWasm ─────┤                    │  (implements snapshot only)
    MontyNative ──┤────────────────────┤  (implements both)
    DartMontyWeb ──┤                       (implements snapshot only,
                                            deletes 3 UnsupportedError methods)

  Status: All 5 packages compile. No behavior change. Tests updated.


  COMMIT 2: MontyCoreBindings + BaseMontyPlatform + Adapters
  ═══════════════════════════════════════════════════════════

  NEW infrastructure added (no existing code modified):

  platform_interface/
    └─ core_bindings.dart         ◄── CoreRunResult, CoreProgressResult,
    └─ base_monty_platform.dart       MontyCoreBindings, BaseMontyPlatform

  ffi/
    └─ ffi_core_bindings.dart     ◄── NativeBindings → MontyCoreBindings

  wasm/
    └─ wasm_core_bindings.dart    ◄── WasmBindings → MontyCoreBindings

  Status: New code exists alongside old. Both old and new are tested.


  COMMIT 3: Migrate MontyFfi + MontyWasm to BaseMontyPlatform
  ════════════════════════════════════════════════════════════

  MontyFfi:  extends MontyPlatform → extends BaseMontyPlatform  (340→~60 lines)
  MontyWasm: extends MontyPlatform → extends BaseMontyPlatform  (274→~40 lines)

  DELETED from MontyFfi:
    _handle, run(), start(), resume(), resumeWithError(), dispose(),
    _handleProgress(), _decodeRunResult(), _applyLimits(), _freeHandle()

  DELETED from MontyWasm:
    _syntheticUsage, _initialized, initialize(), _ensureInitialized(),
    run(), start(), resume(), resumeWithError(), dispose(),
    _translateRunResult(), _translateProgress(), _encodeLimits(), _parseTraceback()

  Status: All deduplication complete. Ladder parity verified.


  COMMIT 4: Desktop Wrapper Removal
  ══════════════════════════════════

  DELETED: NativeRunResult, NativeProgressResult (26 lines)

  NativeIsolateBindings: returns MontyResult/MontyProgress directly
  MontyNative: removes .result/.progress unwrapping

  Status: Clean. All gates pass.
```

### 7.8 Full Stack — After All 4 Commits

```text
  ┌─────────────────────────────────────────────────────────────────────┐
  │                        Consumer Layer                               │
  │                                                                     │
  │   Flutter App / Agent / CLI                                         │
  │   ├── uses MontyPlatform for core ops (run, start, resume, dispose) │
  │   ├── checks: platform is MontySnapshotCapable?                     │
  │   ├── checks: platform is MontyFutureCapable?                       │
  │   └── future:  platform is MontyReplCapable? (M12)                  │
  └───────────────────────────────┬─────────────────────────────────────┘
                                  │
  ┌───────────────────────────────┴─────────────────────────────────────┐
  │                    MontyPlatform (5 abstract methods)                │
  │                    + MontySnapshotCapable (2 methods)                │
  │                    + MontyFutureCapable (3 methods)                  │
  └───────────────────────────────┬─────────────────────────────────────┘
                                  │ extends
  ┌───────────────────────────────┴─────────────────────────────────────┐
  │                    BaseMontyPlatform + MontyStateMixin               │
  │                    (~120 lines of SHARED logic)                      │
  │                                                                     │
  │   ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐ │
  │   │ State guards │  │  Translators │  │  Encoders                │ │
  │   │              │  │              │  │                          │ │
  │   │ assertIdle() │  │ RunResult    │  │ encodeLimits()           │ │
  │   │ assertActive│  │ → MontyResult│  │ encodeExternalFunctions()│ │
  │   │ assertNot   │  │              │  │                          │ │
  │   │  Disposed() │  │ Progress     │  │                          │ │
  │   │              │  │ → MontyProg  │  │                          │ │
  │   └──────────────┘  └──────────────┘  └──────────────────────────┘ │
  │                                                                     │
  │   Delegates to: MontyCoreBindings                                   │
  └───────────────────────────────┬─────────────────────────────────────┘
                                  │
       ┌──────────────────────────┼───────────────────────────┐
       │                          │                           │
  ┌────┴──────────┐    ┌──────────┴──────────┐    ┌───────────┴───────┐
  │  MontyFfi     │    │    MontyNative      │    │  MontyWasm        │
  │  ~60 lines    │    │    186 lines         │    │  ~40 lines        │
  │               │    │                      │    │                   │
  │  Snapshot ✓   │    │  Snapshot ✓          │    │  Snapshot ✓       │
  │  Future  ✓    │    │  Future  ✓           │    │  Future  ✗       │
  └───────┬───────┘    └──────────┬───────────┘    └────────┬──────────┘
          │                       │                         │
  ┌───────┴───────┐    ┌──────────┴───────────┐    ┌────────┴──────────┐
  │FfiCoreBindings│    │NativeIsolateBindings       │    │WasmCoreBindings   │
  │  (adapter)    │    │  (Isolate RPC)       │    │  (adapter)        │
  │  ~80 lines    │    │  returns domain types │    │  ~60 lines        │
  └───────┬───────┘    │  directly (no wrappers)│   └────────┬──────────┘
          │            └──────────┬───────────┘    │
  ┌───────┴───────┐               │ spawns  ┌────────┴──────────┐
  │NativeBindings │    ┌──────────┴───────┐  │ WasmBindings      │
  │ (UNTOUCHED)   │    │ MontyFfi         │  │ (UNTOUCHED)       │
  └───────┬───────┘    │ (in Isolate)     │  └────────┬──────────┘
          │            └──────────────────┘           │
  ┌───────┴───────┐                          ┌────────┴──────────┐
  │NativeBindsFfi │                          │ WasmBindingsJs    │
  │ (UNTOUCHED)   │                          │ (UNTOUCHED)       │
  │ dart:ffi      │                          │ dart:js_interop   │
  └───────┬───────┘                          └────────┬──────────┘
          │                                           │
  ┌───────┴───────┐                          ┌────────┴──────────┐
  │ Rust C FFI    │                          │ monty_glue.js     │
  │ (UNTOUCHED)   │                          │ → Web Worker      │
  │ native/src/   │                          │ → @pydantic/monty │
  └───────────────┘                          └───────────────────┘
```

### 7.9 Capability Check Pattern

```text
  // How consumers use capability interfaces:

  final MontyPlatform platform = MontyPlatform.instance;

  // Core ops — always available
  final result = await platform.run('2 + 2');
  final progress = await platform.start(code, externalFunctions: ['fetch']);

  // Snapshot — check first
  if (platform is MontySnapshotCapable) {
    final snap = await platform.snapshot();           // ✓ safe
    final restored = await platform.restore(snap);    // ✓ safe
  } else {
    // Graceful degradation — no UnsupportedError thrown
  }

  // Futures — check first
  if (platform is MontyFutureCapable) {
    await platform.resumeAsFuture();                  // ✓ safe
    await platform.resolveFutures({1: 'ok'});         // ✓ safe
  } else {
    // Web: skip async fixtures gracefully
    markTestSkipped('Backend does not support futures');
  }

  ┌────────────────────────┬───────────┬──────────┬─────────────┬──────────┐
  │ Implementation         │ Snapshot  │ Future   │ REPL (M12)  │ TypeCheck│
  ├────────────────────────┼───────────┼──────────┼─────────────┼──────────┤
  │ MontyFfi (native)      │    ✓      │    ✓     │   future    │  future  │
  │ MontyWasm (web)        │    ✓      │    ✗     │   future    │  future  │
  │ MontyNative (isolate) │    ✓      │    ✓     │   future    │  future  │
  │ MockMontyPlatform      │    ✓      │    ✓     │   future    │  future  │
  └────────────────────────┴───────────┴──────────┴─────────────┴──────────┘
```
