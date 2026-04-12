# Test Audit Summary

84 files, ~1385 tests, 4 batches audited.

## Overall: tests are solid

The vast majority of tests are substantive and well-structured. The
issues are concentrated in a few areas: coverage padding, FS test
duplication, and a handful of files to delete/merge.

---

## Priority actions

### P0: Fix broken/missing (3 items)

1. **`test/monty_test.dart:109-114`** — `Monty.exec()` test has empty
   body, always passes. Implement or delete.

2. **`test/ffi/ffi_core_bindings_finalizer_test.dart`** — missing
   `@Tags(['integration'])`. Will fail in unit-only CI.

3. **`test/repl/repl_session_test.dart`** — missing
   `@Tags(['integration'])`. Same issue.

### P1: Delete/merge files (4 items, ~200 lines removed)

4. **Delete `test/platform/monty_error_test.dart`** — strict subset
   of `error_hierarchy_test.dart`. Every test is duplicated.

5. **Delete `test/repl/repl_session_unit_test.dart`** — 51 lines,
   4 tests, all trivial or duplicated in `repl_session_test.dart`.

6. **Delete `test/bridge/integration/ffi_single_session_http_test.dart`**
   — fully subsumed by `ffi_plugin_matrix_test.dart`.

7. **Dissolve `test/platform/monty_value_coverage_test.dart`** — move
   any useful round-trip tests to individual type files, delete the
   rest. Coverage booster that creates false confidence.

### P2: Fix hollow tests (~25 tests)

8. **MontyValue toString tests** — across `monty_value_scalars_test`,
   `monty_value_collections_test`, `monty_value_datetime_test`,
   `monty_value_structured_test`. Change `isNotEmpty` to exact string
   assertions (~18 tests).

9. **`monty_plugin_test.dart`** — reduce 9 trivial getter tests to 3
   meaningful ones (~8 tests).

### P3: Consolidate duplicates (~40 tests)

10. **FS provider tests** — `memory_fs_provider_test.dart` and
    `sandboxed_fs_provider_test.dart` duplicate ~60% of
    `shared_fs_handler_contract.dart`. Remove the duplicated test
    cases, keep unique ones (Dart-side API, security tests).

11. **FFI HTTP integration tests** — extract shared host function
    factories from `ffi_mixed_mode_test.dart`,
    `ffi_plugin_matrix_test.dart`, `ffi_raw_bridge_http_test.dart`,
    `ffi_async_host_fn_test.dart` into a shared helper.

### P4: Minor cleanup (4 items)

12. **Remove dead `_syncChild` helper** in
    `sandbox_plugin_inheritance_test.dart`.

13. **Fix `vfs_demo.dart` async bug** — `_listDir()` returns before
    `.resolve()` Future completes.

14. **Add `asyncResumeMap` handling** to
    `test/ffi/integration/python_ladder_runner.dart` (parity with
    WASM runner).

15. **Hardcoded `demo.toughserv.com`** in 6 integration test files —
    low priority, note for future env var extraction.

---

## By the numbers

| Metric | Count |
|--------|-------|
| Files audited | 84 |
| Tests total | ~1385 |
| Files to delete | 3 |
| Files to dissolve | 1 |
| Hollow tests to fix | ~25 |
| Duplicate tests to remove | ~40 |
| Broken tests to fix | 1 |
| Missing tags to add | 2 |
| Minor cleanups | 4 |
| **Estimated lines removed** | **~300** |
| **Estimated time** | **2-3 hours** |

## Files that are excellent (no changes needed)

- `default_monty_bridge_test.dart` (1469 lines)
- `sandbox_plugin_test.dart` (1878 lines)
- `plugin_registry_test.dart` (716 lines)
- `monty_session_test.dart` (68 tests)
- `monty_wasm_test.dart` (1055 lines)
- `smoke_test.dart`, `readme_doctest.dart`
- `sandbox_gather_test.dart`, `sandbox_error_structure_test.dart`
- All ladder tests (python + repl, FFI + WASM)
