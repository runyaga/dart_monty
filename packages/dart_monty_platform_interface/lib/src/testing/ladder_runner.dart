import 'dart:convert';
import 'dart:io';

import 'package:dart_monty_platform_interface/src/monty_exception.dart';
import 'package:dart_monty_platform_interface/src/monty_future_capable.dart';
import 'package:dart_monty_platform_interface/src/monty_platform.dart';
import 'package:dart_monty_platform_interface/src/monty_progress.dart';
import 'package:dart_monty_platform_interface/src/testing/ladder_assertions.dart';
import 'package:test/test.dart';

/// Loads ladder fixture files from [dir], returning sorted tier entries.
///
/// Each entry is a record of `(tierName, fixtures)` where fixtures is the
/// decoded JSON list from that tier file.
List<(String, List<Map<String, dynamic>>)> loadLadderFixtures(Directory dir) {
  final tierFiles = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  return [
    for (final file in tierFiles)
      (
        file.uri.pathSegments.last.replaceAll('.json', ''),
        (jsonDecode(file.readAsStringSync()) as List)
            .cast<Map<String, dynamic>>(),
      ),
  ];
}

/// Runs a simple (non-error, non-iterative) fixture through [platform].
Future<void> runSimpleFixture(
  MontyPlatform platform,
  String code,
  Map<String, dynamic> fixture,
) async {
  final scriptName = fixture['scriptName'] as String?;
  final result = await platform.run(code, scriptName: scriptName);
  assertLadderResult(result.value, fixture);
}

/// Runs an error fixture through [platform], expecting [MontyException].
Future<void> runErrorFixture(
  MontyPlatform platform,
  String code,
  Map<String, dynamic> fixture,
) async {
  final scriptName = fixture['scriptName'] as String?;
  try {
    await platform.run(code, scriptName: scriptName);
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

    assertExceptionFields(e, fixture);
  }
}

/// Runs an iterative (external functions) fixture through [platform].
///
/// Handles resumeValues, resumeErrors, and async/futures paths.
Future<void> runIterativeFixture(
  MontyPlatform platform,
  Map<String, dynamic> fixture,
) async {
  final code = fixture['code'] as String;
  final extFns = (fixture['externalFunctions'] as List).cast<String>();
  final resumeValues = (fixture['resumeValues'] as List?)?.cast<Object>();
  final resumeErrors = (fixture['resumeErrors'] as List?)?.cast<String>();
  final asyncResumeMap = fixture['asyncResumeMap'] as Map<String, dynamic>?;
  final asyncErrorMap = fixture['asyncErrorMap'] as Map<String, dynamic>?;
  final scriptName = fixture['scriptName'] as String?;
  final expectError = fixture['expectError'] as bool? ?? false;

  var progress = await platform.start(
    code,
    externalFunctions: extFns,
    scriptName: scriptName,
  );

  final callIds = <int>[];

  if (asyncResumeMap != null) {
    if (platform is! MontyFutureCapable) {
      markTestSkipped('Platform does not support MontyFutureCapable');

      return;
    }
    final futurePlatform = platform as MontyFutureCapable;
    try {
      while (progress is! MontyComplete) {
        if (progress is MontyPending) {
          callIds.add(progress.callId);
          progress = await futurePlatform.resumeAsFuture();
        } else if (progress is MontyResolveFutures) {
          final pending = progress.pendingCallIds;
          final results = <int, Object?>{};
          final errors = <int, String>{};
          for (final id in pending) {
            final key = id.toString();
            if (asyncErrorMap != null && asyncErrorMap.containsKey(key)) {
              errors[id] = asyncErrorMap[key] as String;
            } else if (asyncResumeMap.containsKey(key)) {
              results[id] = asyncResumeMap[key];
            }
          }
          progress = await futurePlatform.resolveFutures(
            results,
            errors: errors.isNotEmpty ? errors : null,
          );
        } else {
          fail('Unexpected progress type: $progress');
        }
      }
    } on MontyException catch (e) {
      if (expectError) {
        final errorContains = fixture['errorContains'] as String?;
        if (errorContains != null) {
          expect(
            e.message.contains(errorContains),
            isTrue,
            reason: 'Expected error containing "$errorContains", '
                'got: "${e.message}"',
          );
        }

        return;
      }
      rethrow;
    }

    if (expectError) {
      final errorContains = fixture['errorContains'] as String?;
      final completeResult = progress.result;
      expect(
        completeResult.error,
        isNotNull,
        reason: 'Fixture #${fixture['id']}: expected error result',
      );
      if (errorContains != null) {
        final errorMessage = completeResult.error?.message ?? '';
        expect(
          errorMessage.contains(errorContains),
          isTrue,
          reason: 'Expected error containing "$errorContains", '
              'got: "$errorMessage"',
        );
      }

      return;
    }
  } else if (resumeErrors != null) {
    for (var i = 0; i < resumeErrors.length; i++) {
      expect(progress, isA<MontyPending>());
      if (i == 0) assertPendingFields(progress as MontyPending, fixture);
      callIds.add((progress as MontyPending).callId);
      progress = await platform.resumeWithError(resumeErrors[i]);
    }
  } else if (resumeValues != null) {
    for (var i = 0; i < resumeValues.length; i++) {
      expect(progress, isA<MontyPending>());
      if (i == 0) assertPendingFields(progress as MontyPending, fixture);
      callIds.add((progress as MontyPending).callId);
      progress = await platform.resume(resumeValues[i]);
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
  assertLadderResult(complete.result.value, fixture);
}

/// Registers ladder test groups for all tiers in [fixtureDir].
///
/// Call this from a backend's ladder test file:
/// ```dart
/// void main() {
///   registerLadderTests(
///     createPlatform: () => MyPlatform(),
///     fixtureDir: Directory('../../test/fixtures/python_ladder'),
///   );
/// }
/// ```
///
/// Each fixture is run through the appropriate runner (simple, error, or
/// iterative) based on its fixture keys. xfail fixtures are expected to
/// fail and will XPASS-fail if they unexpectedly pass.
void registerLadderTests({
  required MontyPlatform Function() createPlatform,
  required Directory fixtureDir,
}) {
  final tiers = loadLadderFixtures(fixtureDir);

  for (final (tierName, fixtures) in tiers) {
    group(tierName, () {
      for (final fixture in fixtures) {
        final id = fixture['id'] as int;
        final name = fixture['name'] as String;
        final code = fixture['code'] as String;
        final expectError = fixture['expectError'] as bool? ?? false;
        final xfail = fixture['xfail'] as String?;

        test('#$id: $name', () async {
          final monty = createPlatform();

          try {
            if (xfail != null) {
              var passed = false;
              try {
                if (fixture['externalFunctions'] != null) {
                  await runIterativeFixture(monty, fixture);
                } else if (expectError) {
                  await runErrorFixture(monty, code, fixture);
                } else {
                  await runSimpleFixture(monty, code, fixture);
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
                await runIterativeFixture(monty, fixture);
              } else if (expectError) {
                await runErrorFixture(monty, code, fixture);
              } else {
                await runSimpleFixture(monty, code, fixture);
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
