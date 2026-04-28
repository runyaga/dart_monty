// Printing to stdout is expected in an example.
// ignore_for_file: avoid_print
/// Static type-checking example — Monty.typeCheck on the FFI backend.
///
/// Run:
///   dart run bin/type_check_demo.dart
library;

import 'package:dart_monty/dart_monty.dart';

Future<void> main() async {
  print('── Clean code ──');
  await _check('x: int = 1\ny: str = "hello"');

  print('\n── Type error ──');
  await _check('x: int = "not an int"');

  // prefixCode lets you declare types that exist in the runtime
  // environment but not in the snippet you're checking — e.g. external
  // functions injected by the host.
  const fetchStub = 'def fetch(url: str) -> str: return ""';

  print('\n── prefixCode: declare external function shape ──');
  await _check(
    'result: str = fetch("https://example.com")',
    prefixCode: fetchStub,
  );

  print('\n── prefixCode mismatch: result typed as int instead of str ──');
  await _check(
    'result: int = fetch("https://example.com")',
    prefixCode: fetchStub,
  );
}

Future<void> _check(String code, {String? prefixCode}) async {
  final errors = await Monty.typeCheck(code, prefixCode: prefixCode);
  if (errors.isEmpty) {
    print('  OK — no diagnostics.');

    return;
  }
  for (final e in errors) {
    print('  ${e.path}:${e.line}:${e.column} ${e.code}: ${e.message}');
  }
}
