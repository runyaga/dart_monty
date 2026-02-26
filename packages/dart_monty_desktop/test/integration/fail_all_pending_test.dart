@Tags(['integration'])
library;

import 'dart:io';

import 'package:dart_monty_desktop/dart_monty_desktop.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

/// Integration tests for `_failAllPending` semantics in
/// [DesktopBindingsIsolate].
///
/// When `dispose()` is called while an iterative execution is in-flight
/// (state = active, a MontyPending has been returned but not yet resumed),
/// the background Isolate is killed and all pending completer futures
/// must complete with an error — not hang forever.
///
/// The "unexpected isolate exit" path (Isolate crashes without dispose) is
/// not directly testable without Isolate introspection — documented as a
/// known limitation.
///
/// Run with:
/// ```bash
/// cd native && cargo build --release && cd ..
/// cd packages/dart_monty_desktop
/// dart test --tags=integration test/integration/fail_all_pending_test.dart
/// ```
void main() {
  final libPath = _resolveLibraryPath();

  MontyDesktop createMonty() =>
      MontyDesktop(bindings: DesktopBindingsIsolate(libraryPath: libPath));

  test('dispose while pending does not hang', () async {
    final monty = createMonty();

    // Start iterative execution that pauses on external function call.
    final progress = await monty.start(
      'result = fetch("url")\nresult',
      externalFunctions: ['fetch'],
    );
    expect(progress, isA<MontyPending>());

    // Dispose without resuming — this triggers _failAllPending inside
    // DesktopBindingsIsolate.dispose().
    await monty.dispose();

    // If _failAllPending works correctly, dispose() returned normally
    // instead of hanging on an uncompleted future. The fact that we
    // reach this line IS the assertion.
  });

  test('dispose while pending makes further resume throw', () async {
    final monty = createMonty();

    final progress = await monty.start(
      'fetch("url")',
      externalFunctions: ['fetch'],
    );
    expect(progress, isA<MontyPending>());

    await monty.dispose();

    // After dispose, resume must throw StateError (disposed state).
    expect(() => monty.resume('value'), throwsStateError);
  });
}

String _resolveLibraryPath() {
  final ext = Platform.isMacOS ? 'dylib' : 'so';

  return '../../native/target/release/libdart_monty_native.$ext';
}
