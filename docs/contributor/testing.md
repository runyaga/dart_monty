# Testing Guide

This guide covers the testing strategy for `dart_monty`, which ensures
consistent behavior across both native (FFI) and web (WASM) platforms.

## Running Tests

The simplest way to run all tests is to use the standard Dart test runner.

### VM Tests
These are fast unit tests that run in the Dart VM. They cover core logic,
the bridge, extensions, and any components that can be tested with mocks.

```bash
# Run all VM-based unit and integration tests
dart test
```

### Browser Tests
To validate the WASM backend, run the tests on the `chrome` platform. This
will automatically build and serve the necessary files to run in headless Chrome.

```bash
# Run all tests, including browser-based WASM tests
dart test -p chrome
```

**Note:** The previous requirement for a special web server with COOP/COEP
headers has been **removed**. The standard `dart test` server is sufficient.

## Test Categories

- **Unit Tests (`/test`)**: Fast, focused tests that use mocks to isolate
  components.
- **Integration Tests (`/test/integration`)**: Tests that use the real native
  library (`.dylib`/`.so`) or WASM module to verify end-to-end behavior
  for a specific platform.
- **Python Ladder Fixtures (`/test/fixtures`)**: A shared suite of JSON-based
  test cases that define expected Python behavior. These are the foundation of
  our cross-platform parity strategy.

## Cross-Platform Parity: Oracle-Based Testing

To guarantee that `dart_monty` behaves identically to the upstream reference implementation, we use an **oracle-based testing model**.

1.  **The Oracle:** The `pydantic/monty` Python library serves as the ground-truth "oracle."
2.  **Fixture Generation:** A script (`tool/generate_ladder_fixtures.py`) runs a comprehensive suite of Python snippets (the "Python Ladder") against the `pydantic/monty` oracle. It records the precise outputs (values, stdout, errors) as JSON files.
3.  **Validation:** These JSON files become our test fixtures. The `dart_monty_core` test suite executes the *same* Python snippets on both the FFI and WASM backends.
4.  **Assertion:** The tests pass only if the output from our implementations exactly matches the pre-recorded results from the oracle.

This rigorous process ensures that `dart_monty` is a faithful and reliable implementation of the `pydantic/monty` behavior on every platform.

Running `dart test -p chrome` executes this entire validation suite automatically.
