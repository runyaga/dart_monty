// Printing to stdout is expected in an example.
// ignore_for_file: avoid_print
/// Static type checking — a session checked out with `typeCheck: true`.
///
/// Such a session type-checks each snippet before running it. A snippet
/// the check rejects throws [MontyTypingError] and does not run.
/// `typeCheckStubs` declares names the host provides (external functions,
/// inputs) so the checker knows their types.
///
/// Run:
///   dart run example/type_check_demo.dart
library;

import 'dart:io';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty_core/dart_monty_core.dart'
    show MontyHostFunction, MontyString, MontyTypingError;

Future<void> main() async {
  final worker = Platform.environment['DART_MONTY_WORKER'];
  await Monty.withPool(
    workerLocation: worker == null || worker.isEmpty ? null : worker,
    (monty) async {
      print('── Clean code ──');
      await _check(monty, 'x: int = 1\ny: str = "hello"');

      print('\n── Type error ──');
      await _check(monty, 'x: int = "not an int"');

      // typeCheckStubs declares types that exist in the runtime environment
      // but not in the snippet being checked — e.g. external functions
      // injected by the host.
      const fetchStub = 'def fetch(url: str) -> str: ...';

      print('\n── typeCheckStubs: declare external function shape ──');
      await _check(
        monty,
        'result: str = fetch("https://example.com")',
        stubs: fetchStub,
      );

      print('\n── typeCheckStubs mismatch: result typed as int, not str ──');
      await _check(
        monty,
        'result: int = fetch("https://example.com")',
        stubs: fetchStub,
      );
    },
  );
}

/// Type-checks [code] on a fresh session; a clean snippet also runs, with
/// `fetch` answered by the host.
Future<void> _check(Monty monty, String code, {String? stubs}) =>
    monty.withSession(
      (session) async {
        try {
          await session.feedRun(
            code,
            externalLookup: {
              'fetch': MontyHostFunction(
                'fetch',
                (_, _) => const MontyString('<html>'),
              ),
            },
          );
          print('  OK — no diagnostics.');
        } on MontyTypingError catch (e) {
          print('  ${e.display().trim().replaceAll('\n', '\n  ')}');
        }
      },
      typeCheck: true,
      typeCheckStubs: stubs,
      typeCheckFormat: 'concise',
    );
