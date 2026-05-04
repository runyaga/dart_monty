// Smoke test: every example/*.dart compiles and exits 0.
//
// `dart analyze` checks types but does not execute examples. This test fills
// the runtime-rot gap by running each file via `dart run` and asserting exit 0.
// stdout / stderr surface in the failure reason so regressions are debuggable.
//
// Tagged 'example' — skipped in default `dart test` runs because each example
// boots an FFI dylib + interpreter (slow for fast-loop unit testing).
//
// Run: dart test -p vm --run-skipped --tags=example

@Tags(['integration', 'example'])
library;

import 'dart:io';

import 'package:test/test.dart';

/// Examples that currently fail or hang on `main`. Add entries here for known
/// regressions with a TODO reason; remove the entry once the example is fixed.
const _skipReasons = <String, String>{};

void main() {
  final examples =
      Directory('example')
          .listSync()
          .whereType<File>()
          .where(
            (f) =>
                f.path.endsWith('.dart') &&
                !f.path.contains('/native/') &&
                !f.path.contains('/web/'),
          )
          .map((f) => f.path)
          .toList()
        ..sort();

  group('example smoke', () {
    for (final ex in examples) {
      test(
        ex,
        () async {
          final skipReason = _skipReasons[ex];
          if (skipReason != null) {
            markTestSkipped(skipReason);
            return;
          }
          final result = await Process.run('dart', ['run', ex]);
          expect(
            result.exitCode,
            equals(0),
            reason:
                'exit=${result.exitCode}\n'
                '--- stdout ---\n${result.stdout}\n'
                '--- stderr ---\n${result.stderr}',
          );
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }
  });
}
