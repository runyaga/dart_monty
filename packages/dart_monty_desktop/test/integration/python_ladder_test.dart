@Tags(['integration', 'ladder'])
library;

import 'dart:io';

import 'package:dart_monty_desktop/dart_monty_desktop.dart';
import 'package:dart_monty_platform_interface/dart_monty_testing.dart';
import 'package:test/test.dart';

/// Python Compatibility Ladder — integration tests across all tiers.
///
/// Run with:
/// ```bash
/// cd native && cargo build --release && cd ..
/// cd packages/dart_monty_desktop
/// dart test --tags=ladder
/// ```
void main() {
  registerLadderTests(
    createPlatform: () => MontyDesktop(
      bindings: DesktopBindingsIsolate(libraryPath: _resolveLibraryPath()),
    ),
    fixtureDir: Directory('../../test/fixtures/python_ladder'),
  );
}

String _resolveLibraryPath() {
  final ext = Platform.isMacOS ? 'dylib' : 'so';
  return '../../native/target/release/libdart_monty_native.$ext';
}
