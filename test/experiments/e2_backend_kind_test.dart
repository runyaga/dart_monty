// E2/E4: Confirm which backend is active and what library conditionals resolve.
// Run on both: dart test -p vm test/experiments/e2_backend_kind_test.dart
//              dart test -p chrome test/experiments/e2_backend_kind_test.dart

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

void main() {
  test('E2: currentBackendKind reports correct backend', () {
    final kind = currentBackendKind;
    // Experiment test: output is the observable result.
    // ignore: avoid_print
    print('E2 RESULT: currentBackendKind = $kind');
    expect(
      [MontyBackendKind.ffi, MontyBackendKind.wasm],
      contains(kind),
    );
  });

  test('E4: dart:js_interop availability via backend kind', () {
    final kind = currentBackendKind;
    // Experiment test: output is the observable result.
    // ignore: avoid_print
    print(
      'E4 RESULT: dart:js_interop '
      'expected=${kind == MontyBackendKind.wasm}',
    );
    // On WASM: dart.library.js_interop resolves → MontyBackendKind.wasm
    // On FFI:  dart.library.ffi resolves       → MontyBackendKind.ffi
  });

  test('E2b: defaultOsHandler — which os.* ops are available', () async {
    final handler = defaultOsHandler();
    final kind = currentBackendKind;

    if (kind == MontyBackendKind.ffi) {
      // FFI: os.getenv should work
      final result = await handler('os.getenv', ['PATH'], {});
      // Experiment test: output is the observable result.
      // ignore: avoid_print
      print(
        'E2b RESULT FFI: os.getenv(PATH) = '
        '${result != null ? "<set>" : "null"}',
      );
      expect(result, isNotNull);
    } else {
      // WASM: os.getenv should throw or return PermissionError to Python
      // (the handler has no 'os.' prefix — will throw UnsupportedError)
      try {
        await handler('os.getenv', ['PATH'], {});
        // Experiment test: output is the observable result.
        // ignore: avoid_print
        print('E2b RESULT WASM: os.getenv unexpectedly succeeded');
      } on Object catch (e) {
        // Experiment test: output is the observable result.
        // ignore: avoid_print
        print('E2b RESULT WASM: os.getenv threw ${e.runtimeType} — expected');
      }
    }
  });
}
