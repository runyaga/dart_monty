@Tags(['integration', 'ladder'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

/// Python Compatibility Ladder — integration tests across all tiers.
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
  final scriptName = fixture['scriptName'] as String?;
  final result = await monty.run(code, scriptName: scriptName);
  _assertResult(result.value, fixture);
}

Future<void> _runErrorFixture(
  MontyFfi monty,
  String code,
  Map<String, dynamic> fixture,
) async {
  final scriptName = fixture['scriptName'] as String?;
  try {
    await monty.run(code, scriptName: scriptName);
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

    _assertExceptionFields(e, fixture);
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
  final scriptName = fixture['scriptName'] as String?;

  var progress = await monty.start(
    code,
    externalFunctions: extFns,
    scriptName: scriptName,
  );

  final callIds = <int>[];

  if (resumeErrors != null) {
    for (var i = 0; i < resumeErrors.length; i++) {
      expect(progress, isA<MontyPending>());
      if (i == 0) _assertPendingFields(progress as MontyPending, fixture);
      callIds.add((progress as MontyPending).callId);
      progress = await monty.resumeWithError(resumeErrors[i]);
    }
  } else if (resumeValues != null) {
    for (var i = 0; i < resumeValues.length; i++) {
      expect(progress, isA<MontyPending>());
      if (i == 0) _assertPendingFields(progress as MontyPending, fixture);
      callIds.add((progress as MontyPending).callId);
      progress = await monty.resume(resumeValues[i]);
    }
  }

  if (fixture['expectedDistinctCallIds'] == true && callIds.length > 1) {
    expect(
      callIds.toSet().length,
      callIds.length,
      reason: 'Fixture #${fixture['id']}: expected distinct call_ids, '
          'got: $callIds',
    );
  }

  expect(progress, isA<MontyComplete>());
  final complete = progress as MontyComplete;
  _assertResult(complete.result.value, fixture);
}

void _assertPendingFields(MontyPending pending, Map<String, dynamic> fixture) {
  final expectedFnName = fixture['expectedFnName'] as String?;
  if (expectedFnName != null) {
    expect(
      pending.functionName,
      expectedFnName,
      reason: 'Fixture #${fixture['id']}: expected functionName '
          '"$expectedFnName", got: "${pending.functionName}"',
    );
  }

  final expectedArgs = fixture['expectedArgs'] as List?;
  if (expectedArgs != null) {
    expect(
      jsonEncode(pending.arguments),
      jsonEncode(expectedArgs),
      reason: 'Fixture #${fixture['id']}: expected args '
          '${jsonEncode(expectedArgs)}, got: ${jsonEncode(pending.arguments)}',
    );
  }

  final expectedKwargs = fixture['expectedKwargs'];
  if (fixture.containsKey('expectedKwargs')) {
    if (expectedKwargs == null) {
      expect(
        pending.kwargs,
        isNull,
        reason: 'Fixture #${fixture['id']}: expected null kwargs, '
            'got: ${pending.kwargs}',
      );
    } else {
      final expectedMap = Map<String, Object?>.from(
        expectedKwargs as Map<String, dynamic>,
      );
      expect(
        pending.kwargs,
        expectedMap,
        reason: 'Fixture #${fixture['id']}: expected kwargs '
            '$expectedMap, got: ${pending.kwargs}',
      );
    }
  }

  if (fixture['expectedCallIdNonZero'] == true) {
    expect(
      pending.callId,
      isNot(0),
      reason: 'Fixture #${fixture['id']}: expected nonzero callId, '
          'got: ${pending.callId}',
    );
  }

  final expectedMethodCall = fixture['expectedMethodCall'] as bool?;
  if (expectedMethodCall != null) {
    expect(
      pending.methodCall,
      expectedMethodCall,
      reason: 'Fixture #${fixture['id']}: expected methodCall '
          '$expectedMethodCall, got: ${pending.methodCall}',
    );
  }
}

void _assertExceptionFields(
  MontyException e,
  Map<String, dynamic> fixture,
) {
  final expectedExcType = fixture['expectedExcType'] as String?;
  if (expectedExcType != null) {
    expect(
      e.excType,
      expectedExcType,
      reason: 'Fixture #${fixture['id']}: expected excType '
          '"$expectedExcType", got: "${e.excType}"',
    );
  }

  final expectedMinFrames = fixture['expectedTracebackMinFrames'] as int?;
  if (expectedMinFrames != null) {
    expect(
      e.traceback.length,
      greaterThanOrEqualTo(expectedMinFrames),
      reason: 'Fixture #${fixture['id']}: expected >= $expectedMinFrames '
          'traceback frames, got: ${e.traceback.length}',
    );
  }

  if (fixture['expectedTracebackFrameHasFilename'] == true &&
      e.traceback.isNotEmpty) {
    expect(
      e.traceback.first.filename,
      isNotEmpty,
      reason: 'Fixture #${fixture['id']}: expected traceback frame '
          'to have non-empty filename',
    );
  }

  final expectedErrorFilename = fixture['expectedErrorFilename'] as String?;
  if (expectedErrorFilename != null) {
    expect(
      e.filename,
      expectedErrorFilename,
      reason: 'Fixture #${fixture['id']}: expected error filename '
          '"$expectedErrorFilename", got: "${e.filename}"',
    );
  }

  final expectedTracebackFilename =
      fixture['expectedTracebackFilename'] as String?;
  if (expectedTracebackFilename != null && e.traceback.isNotEmpty) {
    final hasFilename = e.traceback.any(
      (f) => f.filename == expectedTracebackFilename,
    );
    expect(
      hasFilename,
      isTrue,
      reason: 'Fixture #${fixture['id']}: expected traceback to contain '
          'frame with filename "$expectedTracebackFilename"',
    );
  }
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
