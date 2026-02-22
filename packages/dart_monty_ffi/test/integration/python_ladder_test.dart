@Tags(['integration', 'ladder'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

/// Python Compatibility Ladder — integration tests across 6 tiers.
///
/// Loads JSON fixtures from `test/fixtures/python_ladder/` and runs each
/// fixture through MontyFfi, asserting expected results.
///
/// Run with:
/// ```bash
/// cd native && cargo build --release && cd ..
/// cd packages/dart_monty_ffi
/// DYLD_LIBRARY_PATH=../../native/target/release dart test --tags=ladder
/// ```
void main() {
  late NativeBindingsFfi bindings;

  setUpAll(() {
    bindings = NativeBindingsFfi();
  });

  final fixtureDir = Directory('../../test/fixtures/python_ladder');
  final tierFiles = fixtureDir
      .listSync()
      .whereType<File>()
      .where(
        (f) => f.path.endsWith('.json'),
      )
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final file in tierFiles) {
    final tierName = file.uri.pathSegments.last.replaceAll('.json', '');
    final fixtures = (jsonDecode(file.readAsStringSync()) as List)
        .cast<Map<String, dynamic>>();

    group(tierName, () {
      for (final fixture in fixtures) {
        final id = fixture['id'] as int;
        final name = fixture['name'] as String;
        final code = fixture['code'] as String;
        final expectError = fixture['expectError'] as bool? ?? false;

        final xfail = fixture['xfail'] as String?;

        test('#$id: $name', () async {
          final monty = MontyFfi(bindings: bindings);

          try {
            if (xfail != null) {
              var passed = false;
              try {
                if (fixture['externalFunctions'] != null) {
                  await _runIterativeFixture(monty, fixture);
                } else if (expectError) {
                  await _runErrorFixture(monty, code, fixture);
                } else {
                  await _runSimpleFixture(monty, code, fixture);
                }
                passed = true;
              } on Object catch (_) {
                // Expected failure — xfail working as intended
              }
              if (passed) {
                fail(
                  'XPASS: #$id "$name" unexpectedly passed '
                  '(xfail: $xfail)',
                );
              }
            } else {
              if (fixture['externalFunctions'] != null) {
                await _runIterativeFixture(monty, fixture);
              } else if (expectError) {
                await _runErrorFixture(monty, code, fixture);
              } else {
                await _runSimpleFixture(monty, code, fixture);
              }
            }
          } finally {
            await monty.dispose();
          }
        });
      }
    });
  }
}

Future<void> _runSimpleFixture(
  MontyFfi monty,
  String code,
  Map<String, dynamic> fixture,
) async {
  final result = await monty.run(code);
  _assertResult(result.value, fixture);
}

Future<void> _runErrorFixture(
  MontyFfi monty,
  String code,
  Map<String, dynamic> fixture,
) async {
  try {
    await monty.run(code);
    fail('Expected MontyException but run() succeeded');
  } on MontyException catch (e) {
    final errorContains = fixture['errorContains'] as String?;
    if (errorContains != null) {
      final fullError = e.toString();
      expect(
        fullError.contains(errorContains),
        isTrue,
        reason: 'Expected error to contain "$errorContains", '
            'got: "$fullError"',
      );
    }
  }
}

Future<void> _runIterativeFixture(
  MontyFfi monty,
  Map<String, dynamic> fixture,
) async {
  final code = fixture['code'] as String;
  final extFns = (fixture['externalFunctions'] as List).cast<String>();
  final resumeValues = (fixture['resumeValues'] as List?)?.cast<Object>();
  final resumeErrors = (fixture['resumeErrors'] as List?)?.cast<String>();

  var progress = await monty.start(code, externalFunctions: extFns);

  if (resumeErrors != null) {
    for (final errorMsg in resumeErrors) {
      expect(progress, isA<MontyPending>());
      progress = await monty.resumeWithError(errorMsg);
    }
  } else if (resumeValues != null) {
    for (final value in resumeValues) {
      expect(progress, isA<MontyPending>());
      progress = await monty.resume(value);
    }
  }

  expect(progress, isA<MontyComplete>());
  final complete = progress as MontyComplete;
  _assertResult(complete.result.value, fixture);
}

void _assertResult(Object? actual, Map<String, dynamic> fixture) {
  final expectedContains = fixture['expectedContains'] as String?;
  if (expectedContains != null) {
    expect(
      actual.toString(),
      contains(expectedContains),
      reason: 'Fixture #${fixture['id']}: expected value to contain '
          '"$expectedContains", got: "$actual"',
    );

    return;
  }

  var expected = fixture['expected'];
  final expectedSorted = fixture['expectedSorted'] as bool? ?? false;

  var sortedActual = actual;
  if (expectedSorted) {
    if (actual is List) {
      sortedActual = [...actual]..sort((a, b) => '$a'.compareTo('$b'));
    }
    if (expected is List) {
      expected = [...expected]..sort((a, b) => '$a'.compareTo('$b'));
    }
  }

  expect(
    jsonEncode(sortedActual),
    jsonEncode(expected),
    reason: 'Fixture #${fixture['id']}: '
        'expected ${jsonEncode(expected)}, '
        'got ${jsonEncode(sortedActual)}',
  );
}
