# State Persistence Slices

Fine-grained implementation plan for the `MontySession` class described
in `docs/state-persistence-design.md`.

**Total slices:** 5
**New files:** 3 (implementation + unit tests + integration tests)
**Modified files:** 1 (barrel export)

---

## Slice 1: MontySession + `run()` + Core Unit Tests

**Depends on:** none

### S1 Goal

Create `MontySession` with `run()`, `clearState()`, `state` getter,
and `dispose()`. The `run()` method wraps user code with
restore/persist preamble/postamble and handles the internal
start/resume loop.

### S1 Files Changed

- `.../lib/src/monty_session.dart` — **created**.
  Core class with `run()`, `clearState()`, `state`, `dispose()`.
- `.../test/monty_session_test.dart` — **created**.
  7 unit tests using `MockMontyPlatform`.

### S1 Acceptance Criteria

- [ ] `MontySession` wraps any `MontyPlatform` instance
- [ ] `run()` prepends restore preamble, appends persist postamble
- [ ] `run()` handles `__restore_state__` and
  `__persist_state__` internally
- [ ] `run()` handles `MontyResolveFutures` by resuming with null
- [ ] `run()` rejects unexpected external functions via
  `resumeWithError`
- [ ] Multiple types persist (int, str, bool, list, dict, None)
- [ ] Non-serializable values silently dropped
- [ ] `clearState()` resets persisted JSON to `{}`
- [ ] `state` returns decoded JSON map (empty if no state)
- [ ] `dispose()` clears state, does NOT dispose underlying platform
- [ ] 7 unit tests pass

### S1 Gate

```bash
cd packages/dart_monty_platform_interface \
  && dart analyze --fatal-infos \
  && dart test test/monty_session_test.dart
```

---

## Slice 2: `start()` Mode + Resume Interception

**Depends on:** Slice 1

### S2 Goal

Add `start()`, `resume()`, `resumeWithError()` methods that support
iterative execution with external functions. Internal state functions
(`__restore_state__`, `__persist_state__`) are handled transparently;
user external functions are returned to the caller.

**Design deviation:** The design doc states callers resume via
`_platform.resume()` directly, but this would bypass
`MontySession`'s `__persist_state__` interception. Instead, callers
must resume through `MontySession.resume()` / `resumeWithError()`
so the session can intercept internal functions on completion.

### S2 Files Changed

- `.../lib/src/monty_session.dart` — add `start()`, `resume()`,
  `resumeWithError()`, `_interceptProgress()`.
- `.../test/monty_session_test.dart` — 5 tests for start/resume
  with mixed ext fns.

### S2 Acceptance Criteria

- [ ] `start()` wraps code and registers internal + user ext fns
- [ ] `start()` intercepts `__restore_state__` before returning
  first user-visible progress
- [ ] `resume()` and `resumeWithError()` delegate to platform and
  intercept `__persist_state__`
- [ ] User `MontyPending` events pass through to caller
- [ ] `MontyComplete` triggers persist interception before returning
- [ ] 5 new tests pass

### S2 Gate

```bash
cd packages/dart_monty_platform_interface \
  && dart analyze --fatal-infos \
  && dart test test/monty_session_test.dart
```

---

## Slice 3: Edge Cases + Error Handling Tests

**Depends on:** Slice 2

### S3 Goal

Add tests for edge cases: error recovery, session isolation,
limits/scriptName forwarding, `MontyResolveFutures` handling,
large state round-trip, dunder variable exclusion, and empty
first-run state.

### S3 Files Changed

- `.../test/monty_session_test.dart` — 7+ new tests.

### S3 Acceptance Criteria

- [ ] Error preserves previous state (persist postamble skipped)
- [ ] Sessions are isolated (separate instances don't share state)
- [ ] `limits` and `scriptName` forwarded to `platform.start()`
- [ ] `MontyResolveFutures` during start/resume handled correctly
- [ ] Large state (100 variables) round-trips correctly
- [ ] Dunder and `_underscore` vars excluded from state
- [ ] First run sends `{}` to `__restore_state__`
- [ ] All tests pass

### S3 Gate

```bash
cd packages/dart_monty_platform_interface \
  && dart analyze --fatal-infos \
  && dart test test/monty_session_test.dart
```

---

## Slice 4: Native Integration Tests

**Depends on:** Slice 1

### S4 Goal

End-to-end tests using real `MontyNative` to verify state
persistence works through the full native stack.

### S4 Files Changed

- `.../test/integration/session_test.dart` — **created**.
  `@Tags(['integration'])`, 5+ end-to-end tests.

### S4 Acceptance Criteria

- [ ] Real state persistence across calls
- [ ] Multi-type persistence (int, str, bool, list, dict)
- [ ] Error recovery (error preserves previous state)
- [ ] Session isolation (separate sessions don't share state)
- [ ] Concurrent sessions work independently
- [ ] All integration tests pass with real native library

### S4 Gate

```bash
cd packages/dart_monty_native \
  && dart test --tags=integration \
       test/integration/session_test.dart
```

---

## Slice 5: Barrel Export + Full Gate

**Depends on:** Slice 1-4

### S5 Goal

Export `MontySession` from the barrel file. Run full Dart gate to
verify nothing is broken.

### S5 Files Changed

- `.../dart_monty_platform_interface.dart` — add
  `export 'src/monty_session.dart';`

### S5 Acceptance Criteria

- [ ] `MontySession` importable from `dart_monty_platform_interface`
- [ ] `dart format .` produces no changes
- [ ] `python3 tool/analyze_packages.py` reports zero issues
- [ ] `bash tool/gate.sh --dart-only` passes

### S5 Gate

```bash
bash tool/gate.sh --dart-only
```

---

## Dependency Graph

```text
Slice 1 (MontySession + run() + unit tests)
  |
  +--> Slice 2 (start/resume interception)
  |      |
  |      v
  |    Slice 3 (edge cases + error tests)
  |
  +--> Slice 4 (native integration tests)
  |
  +----+----+
       |
       v
     Slice 5 (barrel export + full gate)
```

## Commit Mapping

| Commit | Slice | Theme |
|--------|-------|-------|
| **1** | 1 | Core `MontySession` + `run()` + unit tests |
| **2** | 2 | `start()` mode + resume interception |
| **3** | 3 | Edge cases + error handling tests |
| **4** | 4 | Native integration tests |
| **5** | 5 | Barrel export + full gate |
