@Tags(['integration', 'ladder'])
library;

import 'dart:io';

import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_testing.dart';
import 'package:test/test.dart';

/// Python Compatibility Ladder — integration tests across all tiers.
///
/// Run with:
/// ```bash
/// cd native && cargo build --release && cd ..
/// cd packages/dart_monty_ffi
/// DYLD_LIBRARY_PATH=../../native/target/release dart test --tags=ladder
/// ```
void main() {
  late NativeBindingsFfi bindings;

  setUpAll(() {
    bindings = NativeBindingsFfi();
  });

  registerLadderTests(
    createPlatform: () => MontyFfi(bindings: bindings),
    fixtureDir: Directory('../../test/fixtures/python_ladder'),
  );
}
