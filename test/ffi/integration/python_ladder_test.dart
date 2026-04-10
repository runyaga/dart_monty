@Tags(['integration', 'ladder'])
library;

import 'dart:io';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty/dart_monty_ffi.dart';
import 'package:dart_monty/dart_monty_testing.dart';
import 'package:test/test.dart';

/// Python Compatibility Ladder — integration tests across all tiers.
///
/// Run with:
/// ```bash
/// cd packages/dart_monty_ffi
/// dart test --run-skipped --tags=ladder
/// ```
void main() {
  late NativeBindingsFfi bindings;

  setUpAll(() {
    bindings = NativeBindingsFfi();
  });

  registerLadderTests(
    createPlatform: () => MontyFfi(bindings: bindings),
    fixtureDir: Directory('../../test/fixtures/python_ladder'),
    osCallHandler: createDefaultOsCallHandler(),
  );
}
