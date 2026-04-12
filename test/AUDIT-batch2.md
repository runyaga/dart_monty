# Test Audit -- Batch 2: Bridge Unit Tests, OS Call Tests, Plugin Tests

**Auditor:** Claude Opus 4.6 (1M context)
**Date:** 2026-04-11
**Files audited:** 25
**Scope:** test/bridge/src/bridge/, test/bridge/src/os_call/, test/bridge/src/plugins/, test/bridge/integration/

---

## File-by-File Findings

### 1. bridge_event_test.dart (131 lines)

**Hollowness:**
- Line 11: `expect(event, isA<BridgeEvent>())` -- type-only check alongside real field assertions (tolerable).
- Line 100-103: `BridgeEventLoopWaiting is constructible` -- only checks `isA<BridgeEvent>()` with no field assertions. This is the hollow test in this file.

**Quality:**
- No equality/hashCode tests for the event value classes. If these are used in collections or compared, missing coverage.
- No test for BridgeRunFinished with non-null value AND non-null printOutput simultaneously being accessed.
- These are pure data classes -- the tests are appropriate in scope for their simplicity.

**Verdict:** Mostly solid. One borderline hollow test (line 100). Low priority.

---

### 2. default_monty_bridge_test.dart (~1469 lines)

**Hollowness:** None. Every test has meaningful behavioral assertions (event streams, error messages, mock interactions, middleware ordering).

**Quality:** Excellent. Covers:
- Preamble line offset adjustment (P0)
- Deferred async error logging (P0)
- Sync throw safety (#101)
- BridgeMiddleware onion chain, role handling, short-circuiting, throwing
- `__role__` kwarg stripping and precedence
- MontyOsCall handling with registered/missing/failing handlers
- invokeHostFunction routing, validation, coercion
- Error handling in _run (MontyError, generic Object, print-before-error)
- Dispose safety (register/unregister/execute after dispose)
- Console write edge cases, print output flushing
- Unknown function handling, argument validation
- ResolveFutures without futures-capable platform
- resume() failure recovery (#274 regression)

**Gaps:**
- No test for middleware modifying args before passing to next (transform pattern).
- No test for registering the same function name twice (overwrite behavior).

**Verdict:** This is the strongest test file in the batch. No action needed.

---

### 3. event_loop_bridge_test.dart (728 lines)

**Hollowness:** None. Tests verify state transitions, event dispatch ordering, FIFO behavior, orphaned completer cleanup, WASM fallback path.

**Quality:** Very thorough. Covers:
- wait_for_event + dispatchUiEvent full lifecycle
- Queued events delivered in FIFO order
- Multiple sequential wait/dispatch cycles
- render_ui schema storage and callback
- Dispose while waiting, dispose after dispatch
- State transitions (idle -> executing -> waitingForEvent -> completed -> disposed)
- eventLoopEvents stream (BridgeEventLoopWaiting, BridgeEventLoopResumed, BridgeUiRendered)
- Host function registration verification
- Error paths: execute after dispose, double execute, orphaned completer on error
- WASM fallback (sync-only platform)

**Gaps:**
- No test for dispatchUiEvent with invalid/null data.
- No test for render_ui with empty or invalid schema.

**Verdict:** High quality. No action needed.

---

### 4. host_function_schema_test.dart (298 lines)

**Hollowness:** None. All assertions check specific schema output, parameter mappings, validation errors.

**Quality:** Covers:
- HostParam.toJsonSchema: all types, null description, any type, jsonSchemaOverride
- HostFunctionSchema.toJsonSchema: empty params, required/optional, all-optional
- HostFunctionSchema.mapAndValidate: positional args, defaults, extras, kwargs overlay, unknown kwargs, missing required, type validation, empty params

**Gaps:**
- No test for mapAndValidate with kwargs that duplicate a positional arg.
- No test for toJsonSchema with empty string description (is it omitted?).

**Verdict:** Solid. Minor gaps only.

---

### 5. host_param_test.dart (155 lines)

**Hollowness:** None. Every test checks validate() behavior with specific input/output pairs.

**Quality:** Thorough validation coverage:
- String, boolean, integer (with coercion from num and numeric string), number (with coercion), list, map, any
- Error paths for wrong types
- isRequired/defaultValue behavior

**Overlap with #4:** host_function_schema_test.dart also tests HostParam.toJsonSchema and jsonSchemaType. The validate() logic is cleanly separated here. The jsonSchemaType test at line 140-153 partially overlaps with the "maps all HostParamType values" test in file #4 (both enumerate the mapping).

**Verdict:** Good quality. Minor duplication with file #4 on type mapping enumeration -- not worth merging.

---

### 6. introspection_functions_test.dart (185 lines)

**Hollowness:** None. Tests verify JSON output structure, disambiguation, bare name resolution, error strings.

**Quality:** Covers:
- Full function listing (no args)
- Introspection section with only `help`
- Param inclusion in schemas
- Exact match, bare name unambiguous/ambiguous, disambiguation sorting
- Fully-qualified when bare would be ambiguous
- Unknown name error
- Self-resolution (`help` resolves itself)
- Underscore namespace resolution
- Only one function registered (no list_functions)

**Gaps:**
- No test for empty schemas map (edge case).
- No test for help with numeric or special-character input.

**Verdict:** Solid. No action needed.

---

### 7. monty_plugin_test.dart (153 lines)

**Hollowness: MEDIUM.**
- Lines 25-28: "concrete implementation can be constructed" -- only checks `isA<MontyPlugin>()`. The very next test also constructs one and checks namespace, making this redundant.
- Lines 30-37: "namespace is accessible" -- trivial getter test.
- Lines 39-46: "systemPromptContext is accessible" -- trivial getter test.
- Lines 48-56: "functions list is accessible" -- trivial getter test.
- Lines 74-83: "onRegister default implementation is a no-op" -- tests a no-op. Correct but low value.
- Lines 85-88: "systemPromptContext defaults to null" -- trivial default test.
- Lines 91-95: "createChildInstance defaults to null" -- trivial default test.
- Lines 97-105: "createChildInstance accepts optional context" -- also trivial.
- Lines 107-115: "onDispose default implementation is a no-op" -- tests a no-op.

**Quality:** These tests verify abstract class contract but are almost entirely trivial getter/default-value checks. The _NoOpBridge helper (30 lines) is boilerplate for a single no-op test.

**Verdict:** LOW VALUE. Most tests are testing Dart field access on a test subclass. Consider reducing to 2-3 tests covering construction, lifecycle hooks, and createChildInstance.

---

### 8. plugin_registry_test.dart (716 lines)

**Hollowness:** None. All tests verify specific validation errors, collision detection, lifecycle ordering, system prompt generation.

**Quality:** Excellent. Covers:
- Empty registry
- Registration, multiple plugins
- Unmodifiable plugins list
- Namespace validation (empty, uppercase, spaces, special chars, digit prefix, length, reserved)
- Function prefix enforcement
- Collision detection (duplicate namespace, function name collision, partial registration rollback)
- attachTo (function registration, onRegister ordering, extraFunctions, error collection)
- disposeAll (reverse order, idempotency, error collection, multi-error)
- generateSystemPrompt (empty, single plugin, optional params, prefix, multiple plugins ordering)

**Gaps:**
- No test for generateSystemPrompt with a plugin that has null systemPromptContext (should it be omitted or shown?).

**Verdict:** One of the strongest test files. No action needed.

---

### 9. env_os_provider_test.dart (71 lines)

**Hollowness:** None. All tests verify actual resolution behavior.

**Quality:** Covers:
- getenv with hit, miss, default
- environ returns full map
- Does not leak host Platform.environment
- Unknown os.* operation throws

**Gaps:**
- No test for empty env map.
- No test for getenv with empty string key.

**Verdict:** Good quality, appropriately scoped.

---

### 10. memory_fs_contract_test.dart (11 lines)

**Hollowness:** None (just a contract runner invocation).

**Quality:** Delegates to shared_fs_handler_contract.dart. Correctly wires MemoryFsProvider with /sandbox root.

**Verdict:** Proper use of contract pattern.

---

### 11. memory_fs_provider_test.dart (348 lines)

**Hollowness:** None. All tests do real write/read round-trips and state checks.

**Quality:** Covers:
- write_text/read_text, write_bytes/read_bytes round-trips
- Missing file throws
- Intermediate directory creation
- mkdir, mkdir with parents, exist_ok, without exist_ok on existing
- iterdir listing and missing dir
- exists, is_file, is_dir queries
- unlink, rmdir, rename
- Path.resolve, Path.absolute
- Return type contracts (write_text returns int, write_bytes returns int, read_bytes returns List<int>, iterdir returns List<MontyPath>)
- Dart-side API (writeFile, readFile, exists)

**Overlap:** Significant overlap with shared_fs_handler_contract.dart (file #17). Tests like write_text/read_text round-trip, write_bytes/read_bytes round-trip, mkdir, iterdir, exists, unlink, rmdir, rename are all duplicated between this file and the contract. The contract-specific tests (memory_fs_contract_test.dart, #10) already run these against MemoryFsProvider.

**Verdict: CONSOLIDATION OPPORTUNITY.** This file duplicates ~60% of the contract suite. The Dart-side API tests (writeFile, readFile, exists) and return-type contract tests are unique and should stay. The overlapping FS operation tests should be removed since memory_fs_contract_test.dart already runs them.

---

### 12. os_provider_test.dart (147 lines)

**Hollowness:** None. Tests verify routing, fallback, dispose, longest-prefix-match, providerFor.

**Quality:** Covers:
- Path.* routing to filesystem provider
- os.* routing to environment provider
- Unknown prefix throws
- Custom fallback provider
- dispose() disposes all child providers
- date./datetime.* routing
- Multiple prefixes mapping to same provider (dedup on dispose)
- Empty prefix map
- Longest prefix match wins
- providerFor lookup
- Dispose with empty providers

**Verdict:** Solid. No issues.

---

### 13. overlay_fs_provider_test.dart (207 lines)

**Hollowness:** None. Tests verify overlay semantics (read-through, write-to-scratch, merge on iterdir).

**Quality:** Covers:
- Read from base layer
- Write goes to scratch, base unchanged
- Read after write returns scratch version
- Write new file to scratch
- iterdir merges base and scratch
- Delete semantics (unlink scratch file, unlink base-only throws PermissionError, rmdir base-only throws)
- Non-path operations delegate to base
- dispose both layers

**Gaps:**
- No test for rename across layers (rename a base file -- should it go to scratch?).
- No test for write_bytes (only write_text tested).

**Verdict:** Good quality with minor gaps.

---

### 14. readonly_fs_provider_test.dart (140 lines)

**Hollowness:** None. Tests verify read pass-through and write blocking.

**Quality:** Covers:
- Read pass-through: read_text, exists, is_file, is_dir, iterdir
- Write blocked: write_text, write_bytes, mkdir, unlink, rmdir, rename
- dispose delegates

**Gaps:**
- No test for read_bytes pass-through (only write_bytes blocked, read_bytes not tested).
- No test for Path.resolve or Path.absolute pass-through.

**Verdict:** Good. Missing read_bytes and path operation pass-through tests.

---

### 15. sandboxed_fs_provider_contract_test.dart (22 lines)

**Hollowness:** None (just a contract runner invocation).

**Quality:** Correctly wires SandboxedFsProvider with a temp directory for the contract suite.

**Verdict:** Proper use of contract pattern.

---

### 16. sandboxed_fs_provider_test.dart (290 lines)

**Hollowness:** None. Real filesystem operations with security validation.

**Quality:** Covers:
- Basic FS operations (write_text+read_text, write_text creates file, return type, write_bytes+read_bytes, mkdir+iterdir, exists, unlink, rename)
- Security tests: path traversal (../), mid-path traversal, absolute path outside root, prefix-but-different-dir attack, symlink inside pointing outside, symlink chain escape, Path.resolve on symlink outside, normalize double slashes, write outside sandbox, rename target outside sandbox

**Overlap:** The basic FS operations duplicate shared_fs_handler_contract.dart (which sandboxed_fs_provider_contract_test.dart already runs). The security tests are unique and critical.

**Verdict: CONSOLIDATION OPPORTUNITY.** The basic FS operations (lines 33-143) overlap with the contract suite. Keep only the security tests in this file. The contract already validates behavioral parity.

---

### 17. shared_fs_handler_contract.dart (330 lines)

**Hollowness:** None. This is a shared contract that both MemoryFsProvider and SandboxedFsProvider must pass.

**Quality:** Covers:
- File CRUD: write_text/read_text, write_bytes/read_bytes, return types
- Directory: mkdir, mkdir with parents, exist_ok, iterdir
- Queries: exists, is_file, is_dir
- Mutations: unlink, rmdir, rename
- Path operations: resolve, absolute

**Gaps:**
- No error path in contract (read missing file, unlink missing file, iterdir missing dir). These are tested in memory_fs_provider_test.dart but not in the shared contract.

**Verdict:** Well-structured contract. Consider adding error-path tests to the contract so both providers verify consistent error behavior.

---

### 18. time_os_provider_test.dart (99 lines)

**Hollowness:** Some type-only checks are necessary here (checking field types of time maps).

**Quality:** Covers:
- date.today returns correct structure
- datetime.now returns correct structure with all fields
- Injected clock (frozen time)
- Unknown operation throws
- Default clock uses DateTime.now (time-range check)
- Timezone offset populated correctly

**Verdict:** Good quality. No issues.

---

### 19. message_bus_plugin_test.dart (290 lines)

**Hollowness:** None. All tests verify actual message passing behavior.

**Quality:** Excellent. Covers:
- Metadata: namespace, function count, naming convention, systemPromptContext, createChildInstance shares bus
- msg_send/msg_recv: FIFO order, recv-before-send blocking, multiple producers/consumers
- Timeout: success, expiry, timed-out recv cleanup
- msg_peek: empty, non-destructive, closed channel
- msg_close: unblocks receivers, send-after-close throws, drain before null, idempotent
- msg_stats: send/recv counts, peak queue depth
- Disposal: pending receivers get StateError, sibling instance survives
- Parent/child integration: bidirectional communication via shared bus

**Verdict:** Top-quality test file. No action needed.

---

### 20. sandbox_plugin_test.dart (~1878 lines)

**Hollowness:** None. This is the largest test file in the batch and every test verifies meaningful behavior.

**Quality:** Comprehensive. Covers:
- Metadata: namespace, prompt, function count, naming, registry compatibility
- sandbox_spawn: handles, incrementing IDs, code pass-through, platform disposal, limits, disposed state
- sandbox_await: null return, child return value, ChildSandboxException, structured field preservation, unknown handle
- sandbox_await_all: results for all, failure propagation, unknown handle
- sandbox_is_alive: running vs completed, unknown handle
- sandbox_get_output: print output, null output, still-running error, unknown handle
- sandbox_gather: attributed results, handle order, null output, failure, unknown handle, single handle
- sandbox_free: removes child, still-running error, unknown handle, double free
- Failed child print output
- Depth limiting, concurrency limiting
- ChildSandboxException: toString, null exception field, infrastructure error
- onDispose: teardown, idempotent, completed children
- Child plugin wiring: factory, factory precedence over parentPlugins
- createChildInstance inheritance: opt-in, opt-out (returns null), SandboxPlugin never inherited, empty parents, guard against returning SandboxPlugin, cleanup on factory failure
- ChildSpawnContext threading: correct childId, null/non-null workingDirectory, incrementing paths, factory receives context
- Child system prompt injection: param schema, runtime prompt, builder prompt, builder+runtime concatenation, null builder, builder returning null, no prompts, inheritance path
- Structured logging: spawn, bridge creation, completion, failure, free, dispose, depth/concurrency rejection, factory/inheritance/attachTo failure, cleanup error, plugin attachment, error truncation, platform failure, default logger

**Verdict:** Exceptionally thorough. No action needed.

---

### 21. template_plugin_test.dart (146 lines)

**Hollowness:** None. Tests verify actual template rendering output.

**Quality:** Covers:
- Metadata: namespace, function count, systemPromptContext, createChildInstance
- tmpl_render: variable substitution, for loop, if true/false, nested context, empty template, missing variable, oversized input, custom maxInputSize, loop over list of maps

**Gaps:**
- No test for invalid template syntax (e.g., unclosed `{% for %}`).
- No test for context with deeply nested structures beyond 2 levels.
- `handles missing variable gracefully` (line 97-104) only checks `isA<String>()` -- could be more specific about what "graceful" means.

**Verdict:** Good quality with minor gaps.

---

### 22. agent_session_test.dart (373 lines, integration)

**Hollowness:** None. Tests execute real Python code and verify results.

**Quality:** Covers:
- Stateful execution: simple expression, variable persistence (int, string, list, dict), clearState
- Host functions: callable from Python, result persists, schemas include registered
- Filesystem: write/read via pathlib, state persistence, date.today
- Error handling: Python error returns error result, error doesn't break state, execute after dispose
- Sandbox mode: simple expression, isSandboxMode flag, persistence, host functions, clearState, error recovery, executeStream throws, sequential calls
- Event streaming: executeStream emits events

**Gaps:**
- No test for host function error propagation to Python (what does the Python side see?).
- No test for large state persistence.

**Verdict:** Good integration coverage.

---

### 23. message_bus_integration_test.dart (159 lines, integration)

**Hollowness:** None. Real FFI execution with parent/child communication.

**Quality:** Covers:
- Parent sends, child receives and returns
- Bidirectional: child processes task and sends structured reply
- Fan-out to 2 workers and gather results

**Verdict:** Good integration coverage of the key use cases.

---

### 24. sandbox_error_structure_test.dart (101 lines, integration)

**Hollowness:** None. Verifies error structure preservation through real FFI.

**Quality:** Covers:
- ChildSandboxException preserves excType from NameError
- Preserves info from SyntaxError

**Gaps:**
- Only 2 error types tested. Could add TypeError, IndexError, etc.

**Verdict:** Adequate but could be expanded.

---

### 25. sandbox_gather_test.dart (238 lines, integration)

**Hollowness:** None. Real FFI execution verifying gather semantics.

**Quality:** Covers:
- Attributed output to correct worker (handle, value, output)
- Handle order preservation
- Silent worker null output
- Child failure propagation
- Machine-parseable result format

**Verdict:** Good integration coverage.

---

## Summary

| Metric | Count |
|---|---|
| Total files audited | 25 |
| Hollow/low-value tests found | 1 file (monty_plugin_test.dart -- ~8 trivial getter tests) |
| Consolidation opportunities | 2 (memory_fs_provider + sandboxed_fs_provider overlap with contract) |
| Quality gaps identified | 8 minor across all files |
| High-quality files (no action) | 20 |
| Integration test files | 4 (all tagged, require native lib) |

---

## Prioritized Action Items

### P1: Consolidation -- Remove duplicate FS tests

**Files:** memory_fs_provider_test.dart (#11), sandboxed_fs_provider_test.dart (#16)

Both files duplicate test cases already covered by shared_fs_handler_contract.dart (via memory_fs_contract_test.dart and sandboxed_fs_provider_contract_test.dart). Estimated ~40 redundant test cases across the two files.

**Action:**
- In memory_fs_provider_test.dart: remove tests that duplicate the contract (write_text/read_text round-trip, write_bytes/read_bytes, mkdir, iterdir, exists, is_file, is_dir, unlink, rmdir, rename, Path.resolve, Path.absolute). Keep: Dart-side API tests (writeFile, readFile, exists), return type contracts, intermediate directory creation, mkdir edge cases (exist_ok, without exist_ok on existing dir), iterdir on missing dir, read_text on missing file, unlink on missing file.
- In sandboxed_fs_provider_test.dart: remove basic FS operations (lines 33-143). Keep: ALL security tests (lines 145-287). These are unique and critical.

**Impact:** Eliminates ~40 duplicate tests, reduces maintenance burden, makes it clear what each file is responsible for.

### P2: Reduce monty_plugin_test.dart

**File:** monty_plugin_test.dart (#7)

8 of 9 tests are trivial getter/default checks on a test subclass. The file also includes a 30-line _NoOpBridge mock used for a single no-op lifecycle test.

**Action:** Collapse to 3 tests:
1. Construction with all fields
2. Default values (null systemPromptContext, null createChildInstance)
3. Lifecycle hooks are no-ops (onRegister, onDispose)

**Impact:** Removes 6 low-value tests and 30 lines of mock boilerplate.

### P3: Add error paths to shared FS contract

**File:** shared_fs_handler_contract.dart (#17)

The contract does not test error paths (read missing file, unlink missing file, iterdir missing dir, mkdir on existing without exist_ok). These are tested per-provider but should be in the contract to ensure consistent error behavior across providers.

**Action:** Add 4-5 error-path tests to the contract. Remove corresponding tests from memory_fs_provider_test.dart (they'll now run via the contract).

**Impact:** Ensures both MemoryFsProvider and SandboxedFsProvider have identical error behavior guarantees.

### P4: Minor quality gaps (low priority)

- **readonly_fs_provider_test.dart:** Add read_bytes pass-through test.
- **overlay_fs_provider_test.dart:** Add test for write_bytes, rename across layers.
- **template_plugin_test.dart:** Add test for invalid template syntax.
- **bridge_event_test.dart:** Remove or strengthen "BridgeEventLoopWaiting is constructible" test (line 100).

---

## Overall Assessment

This is a high-quality test suite. The bridge and plugin tests are thorough, well-structured, and cover both happy paths and error paths extensively. The main issue is FS test duplication between provider-specific files and the shared contract -- a natural result of the contract being introduced after the initial tests. The monty_plugin_test.dart hollowness is a minor nuisance. No stale tests for removed APIs were found. No misleading test names were found.
