// E1: Does Isolate.spawn work on this platform?
// Run on both: dart test -p vm test/experiments/e1_isolate_spawn_test.dart
//              dart test -p chrome test/experiments/e1_isolate_spawn_test.dart

import 'dart:isolate';

import 'package:test/test.dart';

void main() {
  test('E1: Isolate.spawn — reports result, does not fail the suite', () async {
    try {
      final port = ReceivePort();
      await Isolate.spawn(_echo, port.sendPort);
      final result = await port.first as String;
      port.close();
      // Experiment test: output is the observable result.
      // ignore: avoid_print
      print('E1 RESULT: Isolate.spawn WORKS — got "$result"');
      expect(result, 'pong');
    } on Object catch (e) {
      // Experiment test: output is the observable result.
      // ignore: avoid_print
      print('E1 RESULT: Isolate.spawn THREW ${e.runtimeType} — $e');
    }
  });
}

void _echo(SendPort port) => port.send('pong');
