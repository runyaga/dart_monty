@Tags(['integration', 'repl-ladder'])
library;

import 'dart:io';

import 'package:dart_monty/src/ffi/native_bindings_ffi.dart';
import 'package:dart_monty/src/repl/ffi_repl_bindings.dart';
import 'package:dart_monty/src/repl/testing/repl_ladder_runner.dart';
import 'package:test/test.dart';

/// REPL Ladder — fixture-driven integration tests for REPL state persistence.
///
/// Run with:
/// ```bash
/// dart test --run-skipped --tags=repl-ladder
/// ```
void main() {
  late NativeBindingsFfi bindings;

  setUpAll(() {
    bindings = NativeBindingsFfi();
  });

  registerReplLadderTests(
    createBindings: () => FfiReplBindings(bindings: bindings),
    fixtureDir: Directory('test/fixtures/repl_ladder'),
  );
}
