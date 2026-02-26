@Tags(['integration', 'ladder'])
library;

import 'dart:io';

import 'package:dart_monty_native/dart_monty_native.dart';
import 'package:dart_monty_platform_interface/dart_monty_testing.dart';
import 'package:test/test.dart';

/// Python Compatibility Ladder — integration tests across all tiers.
///
/// Run with:
/// ```bash
/// cd native && cargo build --release && cd ..
/// cd packages/dart_monty_native
/// dart test --tags=ladder
/// ```
void main() {
  registerLadderTests(
    createPlatform: () => MontyNative(
      bindings: NativeIsolateBindingsImpl(libraryPath: _resolveLibraryPath()),
    ),
    fixtureDir: Directory('../../test/fixtures/python_ladder'),
  );
}

String _resolveLibraryPath() {
  final ext = Platform.isMacOS ? 'dylib' : 'so';

  return '../../native/target/release/libdart_monty_native.$ext';
}
