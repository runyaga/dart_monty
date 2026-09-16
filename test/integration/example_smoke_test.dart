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

import 'package:path/path.dart' as p;
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
          // RUN INSIDE example/, NOT THE REPO ROOT.
          //
          // `example/` is its own package, so dartdev publishes the native
          // asset into `example/.dart_tool/lib/` -- a file THIS process never
          // maps. Run from the repo root instead and each child republishes
          // `<root>/.dart_tool/lib/libdart_monty_core_native.so` by
          // delete-then-copy while the test runner has it mmap'd, which
          // invalidates the mapping and kills the runner with
          // SIGBUS/SIGSEGV/SIGABRT (dart_monty_core#161, dart-lang/sdk#62361).
          // Measured: 0/4 crashes from here against a 5/5 baseline from the
          // root, with all 15 examples producing identical exit codes and
          // output either way.
          //
          // These children need EXCLUSIVE use of `example/.dart_tool/lib`:
          // they must stay sequential with each other, and nothing else may
          // publish there concurrently.
          final result = await Process.run(
            'dart',
            ['run', p.basename(ex)],
            workingDirectory: p.join(Directory.current.path, 'example'),
          );
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
