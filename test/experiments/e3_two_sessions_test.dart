// E3: Can two MontyRuntime instances coexist on this platform?
// On FFI: two runtimes should be independent.
// On WASM: constructing a second interpreter is known to crash the parent.
//
// NOTE: This test only exercises construction + dispose, not execute().
// The crash on WASM may be deferred to the first execute() call or may
// occur at construction. This test documents whichever happens.
//
// Run: dart test -p vm   test/experiments/e3_two_sessions_test.dart
//      dart test -p chrome test/experiments/e3_two_sessions_test.dart
//      (WASM with Python runtime: bash tool/test_wasm.sh after adding @Tags)

import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

void main() {
  test('E3: construct two MontyRuntime instances simultaneously', () async {
    MontyRuntime? s1;
    MontyRuntime? s2;
    try {
      s1 = MontyRuntime();
      // Experiment test: output is the observable result.
      // ignore: avoid_print
      print('E3 RESULT: runtime 1 constructed OK');

      s2 = MontyRuntime();
      // Experiment test: output is the observable result.
      // ignore: avoid_print
      print('E3 RESULT: runtime 2 constructed OK — both alive simultaneously');
    } on Object catch (e, st) {
      // Experiment test: output is the observable result.
      // ignore: avoid_print
      print('E3 RESULT: second construction threw ${e.runtimeType}: $e');
      // Experiment test: output is the observable result.
      // ignore: avoid_print
      print('E3 STACK: $st');
    } finally {
      await s1?.dispose();
      await s2?.dispose();
    }
  });

  test('E3b: sequential sessions (dispose before constructing next)', () async {
    try {
      final s1 = MontyRuntime();
      // Experiment test: output is the observable result.
      // ignore: avoid_print
      print('E3b RESULT: runtime 1 constructed OK');
      await s1.dispose();
      // Experiment test: output is the observable result.
      // ignore: avoid_print
      print('E3b RESULT: runtime 1 disposed OK');

      final s2 = MontyRuntime();
      // Experiment test: output is the observable result.
      // ignore: avoid_print
      print('E3b RESULT: runtime 2 constructed OK after dispose');
      await s2.dispose();
    } on Object catch (e) {
      // Experiment test: output is the observable result.
      // ignore: avoid_print
      print('E3b RESULT: threw ${e.runtimeType}: $e');
    }
  });
}
