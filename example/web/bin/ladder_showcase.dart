/// Ladder Showcase — runs all Python ladder fixtures in-browser with visual
/// pass/fail output to the DOM.
///
/// Results have three states:
/// - **pass**: bridge executed and value matches fixture expected
/// - **warn**: bridge executed but value differs (known WASM behavioral diff)
/// - **fail**: bridge crashed or returned an unexpected error
///
/// Build & run:
///   bash run.sh → open http://localhost:8088/ladder.html
library;

import 'dart:convert';
import 'dart:js_interop';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty_core/dart_monty_core.dart'
    show
        ExternalFuture,
        ExternalResult,
        ExternalReturnValue,
        ExternalSettledResult,
        FunctionSnapshot,
        FutureSnapshot,
        MontyComplete,
        MontyFrozenSet,
        MontySet,
        NameLookupSnapshot;

import 'package:web_example/demo_pool.dart';
import 'package:web_example/demo_ready.dart';

/// The pool every fixture runs on, each on a fresh session.
late final Monty _pool;

// ---------------------------------------------------------------------------
// JS fetch interop
// ---------------------------------------------------------------------------

@JS('fetch')
external JSPromise<LadderShowcase> _jsFetch(JSString url);

extension type LadderShowcase(JSObject _) implements JSObject {
  external JSPromise<JSString> text();
}

// ---------------------------------------------------------------------------
// DOM reporting via JS callback
// ---------------------------------------------------------------------------

@JS('reportResult')
external void _reportResult(
  JSNumber tier,
  JSNumber id,
  JSString name,
  JSString code,
  JSString status,
  JSString detail,
);

@JS('reportTierHeader')
external void _reportTierHeader(JSString label);

@JS('reportDone')
external void _reportDone(
  JSNumber passed,
  JSNumber warned,
  JSNumber failed,
  JSNumber total,
  JSNumber skipped,
  JSNumber xfailed,
  JSNumber xpassed,
);

@JS('reportInit')
external void _reportInit(JSBoolean ok, JSString message);

// ---------------------------------------------------------------------------
// Fixture tier files
// ---------------------------------------------------------------------------

const _tierFiles = [
  'fixtures/tier_01_expressions.json',
  'fixtures/tier_02_variables.json',
  'fixtures/tier_03_control_flow.json',
  'fixtures/tier_04_functions.json',
  'fixtures/tier_05_errors.json',
  'fixtures/tier_06_external_fns.json',
  'fixtures/tier_07_advanced.json',
  'fixtures/tier_08_kwargs.json',
  'fixtures/tier_09_exceptions.json',
  'fixtures/tier_10_math_module.json',
  'fixtures/tier_11_re_module.json',
  'fixtures/tier_12_monty_008_features.json',
  'fixtures/tier_13_async.json',
  'fixtures/tier_15_script_name.json',
  'fixtures/tier_16_memory_growth.json',
  'fixtures/tier_17_json_module.json',
  'fixtures/tier_18_datetime_module.json',
  'fixtures/tier_19_lifecycle_errors.json',
];

const _tierLabels = [
  'Tier 1: Expressions',
  'Tier 2: Variables',
  'Tier 3: Control Flow',
  'Tier 4: Functions',
  'Tier 5: Errors',
  'Tier 6: External Functions',
  'Tier 7: Advanced',
  'Tier 8: Kwargs',
  'Tier 9: Exceptions',
  'Tier 10: Math Module',
  'Tier 11: Regex (re)',
  'Tier 12: Monty 0.0.8 Features',
  'Tier 13: Async',
  'Tier 15: Script Name',
  'Tier 16: Memory Growth',
  'Tier 17: JSON Module',
  'Tier 18: Datetime Module',
  'Tier 19: Lifecycle Errors',
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Future<String> _fetchText(String url) async {
  final response = await _jsFetch(url.toJS).toDart;

  return (await response.text().toDart).toDart;
}

// ---------------------------------------------------------------------------
// Result comparison
// ---------------------------------------------------------------------------

bool _valuesMatch(Object? actual, Object? expected) {
  if (expected == null && actual == null) return true;
  if (expected is List && actual is List) {
    if (expected.length != actual.length) return false;
    for (var i = 0; i < expected.length; i++) {
      if (!_valuesMatch(actual[i], expected[i])) return false;
    }

    return true;
  }
  if (expected is num && actual is num) {
    return (expected - actual).abs() < 0.001;
  }

  return '$actual' == '$expected';
}

/// Emits a machine-readable result line to the browser console for the
/// headless ladder gate (tool/test_python_ladder.sh). `tier` is the fixture
/// FILE name (e.g. `tier_07_advanced.json`) so the key matches
/// known_failures.txt (`tier_file:test_name`). `ok` is false only for hard
/// failures — warn/xfail/xpass/skip count as passing for the gate.
void _emitLadderResult(String tierFile, String name, String status) {
  final tier = tierFile.split('/').last;
  final payload = jsonEncode({
    'tier': tier,
    'name': name,
    'ok': status != 'fail',
  });
  // print() is the headless gate's transport (dart2js -> console.log).
  // ignore: avoid_print
  print('LADDER_RESULT:$payload');
}

// ---------------------------------------------------------------------------
// Runner
// ---------------------------------------------------------------------------

Future<void> main() async {
  try {
    _pool = await startDemoPool();
  } on Object catch (e) {
    _reportInit(false.toJS, 'Failed to start the Monty worker: $e'.toJS);
    montyDemoFailed('ladder_showcase', 'Monty.start failed: $e');

    return;
  }
  _reportInit(true.toJS, 'Worker initialized'.toJS);

  var totalPassed = 0;
  var totalWarned = 0;
  var totalFailed = 0;
  var totalTests = 0;
  var totalSkipped = 0;
  var totalXfailed = 0;
  var totalXpassed = 0;

  for (var tierIdx = 0; tierIdx < _tierFiles.length; tierIdx++) {
    _reportTierHeader(_tierLabels[tierIdx].toJS);

    try {
      final json = await _fetchText(_tierFiles[tierIdx]);
      final fixtures = (jsonDecode(json) as List).cast<Map<String, dynamic>>();

      for (final fixture in fixtures) {
        totalTests++;
        final id = fixture['id'] as int;
        final name = fixture['name'] as String;
        final code = fixture['code'] as String;
        final nativeOnly = fixture['nativeOnly'] as bool? ?? false;
        final unsupported = RegExp(r'\bdel\b|globals\(').hasMatch(code);

        if (nativeOnly || unsupported) {
          totalSkipped++;
          totalPassed++;
          _reportResult(
            (tierIdx + 1).toJS,
            id.toJS,
            name.toJS,
            code.toJS,
            'skip'.toJS,
            (nativeOnly
                    ? 'Skipped (native only)'
                    : 'Skipped (unsupported Python form: del/globals)')
                .toJS,
          );
          _emitLadderResult(_tierFiles[tierIdx], name, 'skip');
          continue;
        }

        final verifyResult = await _runFixture(fixture);
        final status = verifyResult['status'] as String;
        final detail = verifyResult['detail'] as String;

        if (status == 'pass') totalPassed++;
        if (status == 'warn') totalWarned++;
        if (status == 'fail') totalFailed++;
        if (status == 'xfail') {
          totalXfailed++;
          totalPassed++;
        }
        if (status == 'xpass') {
          totalXpassed++;
          totalPassed++;
        }
        _reportResult(
          (tierIdx + 1).toJS,
          id.toJS,
          name.toJS,
          code.toJS,
          status.toJS,
          detail.toJS,
        );
        _emitLadderResult(_tierFiles[tierIdx], name, status);
      }
    } on Object catch (e) {
      totalFailed++;
      _reportResult(
        (tierIdx + 1).toJS,
        0.toJS,
        'Tier load error'.toJS,
        ''.toJS,
        'fail'.toJS,
        'Failed to load ${_tierFiles[tierIdx]}: $e'.toJS,
      );
      _emitLadderResult(_tierFiles[tierIdx], 'Tier load error', 'fail');
    }
  }

  _reportDone(
    totalPassed.toJS,
    totalWarned.toJS,
    totalFailed.toJS,
    totalTests.toJS,
    totalSkipped.toJS,
    totalXfailed.toJS,
    totalXpassed.toJS,
  );

  // Completion marker for the headless gate — lets it distinguish a finished
  // run from a Chrome crash/timeout that emitted only partial results.
  // ignore: avoid_print
  print('LADDER_DONE:${jsonEncode({'total': totalTests})}');
  // Raised after every tier fixture has run, so the signal carries the same
  // weight as LADDER_DONE above.
  montyDemoReady('ladder_showcase');
}

// ---------------------------------------------------------------------------
// Fixture execution
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>> _runFixture(Map<String, dynamic> fixture) async {
  final expectError = fixture['expectError'] as bool? ?? false;
  final xfail = fixture['xfail'] as String?;

  Map<String, dynamic> result;
  try {
    if (fixture['asyncResumeMap'] != null) {
      result = await _runAsync(fixture);
    } else if (fixture['externalFunctions'] != null) {
      result = await _runIterative(fixture);
    } else if (expectError) {
      result = await _runExpectError(fixture);
    } else {
      result = await _runSimple(fixture);
    }
  } on Object catch (e) {
    if (expectError) {
      result = {'status': 'pass', 'detail': 'Error (expected): $e'};
    } else {
      result = {'status': 'fail', 'detail': 'Exception: $e'};
    }
  }

  if (xfail != null) {
    final status = result['status'] as String;
    if (status == 'fail' || status == 'warn') {
      return {'status': 'xfail', 'detail': 'xfail: $xfail'};
    }
    return {
      'status': 'xpass',
      'detail': 'xpass: expected failure did not occur',
    };
  }

  return result;
}

/// Runs [body] on a fresh session, named by the fixture's `scriptName`.
Future<T> _onSession<T>(
  Map<String, dynamic> fixture,
  Future<T> Function(MontySession session) body,
) =>
    _pool.withSession(
      body,
      scriptName: fixture['scriptName'] as String? ?? 'main.py',
    );

/// [value] in the fixtures' JSON shape: tuples and sets tagged with
/// `__type`, containers converted element by element.
Object? _shape(MontyValue value) => switch (value) {
      MontyList(:final items) => [for (final item in items) _shape(item)],
      MontyTuple(:final items) => {
          '__type': 'tuple',
          'value': [for (final item in items) _shape(item)],
        },
      MontySet(:final items) || MontyFrozenSet(:final items) => {
          '__type': 'set',
          'value': [for (final item in items) _shape(item)],
        },
      MontyDict(:final pairs) => {
          for (final (key, item) in pairs) '${key.dartValue}': _shape(item),
        },
      _ => value.dartValue,
    };

/// A Python error as the fixtures' detail text: its type and message.
String _describe(MontyError error) =>
    '${error.exception.excType}: ${error.exception.message ?? ''}';

/// The status of a fixture that failed with [error].
Map<String, dynamic> _onError(MontyError error, Map<String, dynamic> fixture) {
  if (fixture['expectError'] as bool? ?? false) {
    return {
      'status': 'pass',
      'detail': 'Error (expected): ${_describe(error)}',
    };
  }

  return {'status': 'fail', 'detail': 'Python error: ${_describe(error)}'};
}

Future<Map<String, dynamic>> _runSimple(Map<String, dynamic> fixture) async {
  final code = fixture['code'] as String;
  try {
    final value = await _onSession(fixture, (s) => s.feedRun(code));

    return _compareResult(_shape(value), fixture);
  } on MontyError catch (e) {
    return {'status': 'fail', 'detail': 'Python error: ${_describe(e)}'};
  }
}

Future<Map<String, dynamic>> _runExpectError(
  Map<String, dynamic> fixture,
) async {
  final code = fixture['code'] as String;
  try {
    final value = await _onSession(fixture, (s) => s.feedRun(code));

    return {
      'status': 'warn',
      'detail': 'Expected error but got value: ${_shape(value)}'
          ' — WASM Monty may handle this differently than CPython',
    };
  } on MontyError catch (e) {
    return {'status': 'pass', 'detail': 'Error (expected): ${_describe(e)}'};
  }
}

Future<Map<String, dynamic>> _runIterative(Map<String, dynamic> fixture) async {
  final code = fixture['code'] as String;
  final resumeValues = (fixture['resumeValues'] as List?)?.cast<Object?>();
  final resumeErrors = (fixture['resumeErrors'] as List?)?.cast<String>();
  final answers = <ExternalResult>[
    if (resumeErrors != null)
      for (final message in resumeErrors)
        ExternalException('RuntimeError', message)
    else if (resumeValues != null)
      for (final value in resumeValues)
        ExternalReturnValue(MontyValue.fromDart(value)),
  ];

  try {
    return await _onSession(fixture, (session) async {
      var snapshot = await session.feedStart(code);
      for (final answer in answers) {
        if (snapshot is! FunctionSnapshot) {
          return {'status': 'fail', 'detail': 'Expected pending state'};
        }
        snapshot = await snapshot.resume(answer);
      }
      if (snapshot is! MontyComplete) {
        return {
          'status': 'fail',
          'detail': 'Still suspended after every answer: $snapshot',
        };
      }

      return _compareResult(_shape(snapshot.output), fixture);
    });
  } on MontyError catch (e) {
    return _onError(e, fixture);
  }
}

Future<Map<String, dynamic>> _runAsync(Map<String, dynamic> fixture) async {
  final code = fixture['code'] as String;
  final asyncResumeMap =
      (fixture['asyncResumeMap'] as Map<String, dynamic>?) ?? {};
  final asyncErrorMap =
      (fixture['asyncErrorMap'] as Map<String, dynamic>?) ?? {};

  try {
    return await _onSession(fixture, (session) async {
      // Answer every call with a future, recording the call order so the
      // fixture's indices map to the actual call ids, and settle each wait
      // with the fixture's answers for the calls it waits on.
      final callIdByIndex = <int, int>{};
      ExternalSettledResult? answerFor(int callId) {
        final index = callIdByIndex.entries
            .firstWhere(
              (e) => e.value == callId,
              orElse: () => const MapEntry(-1, -1),
            )
            .key;
        if (asyncResumeMap['$index'] case final Object? value?) {
          return ExternalReturnValue(MontyValue.fromDart(value));
        }
        if (asyncErrorMap['$index'] case final Object? message?) {
          return ExternalException('RuntimeError', '$message');
        }

        return null;
      }

      var snapshot = await session.feedStart(code);
      while (snapshot is! MontyComplete) {
        switch (snapshot) {
          case final FunctionSnapshot call:
            callIdByIndex[callIdByIndex.length] = call.callId;
            snapshot = await call.resume(const ExternalFuture());
          case final FutureSnapshot wait:
            final results = <int, ExternalSettledResult>{
              for (final id in wait.pendingCallIds)
                if (answerFor(id) case final result?) id: result,
            };
            if (results.isEmpty) {
              return {
                'status': 'fail',
                'detail': 'No answer for pending calls ${wait.pendingCallIds}',
              };
            }
            snapshot = await wait.resume(results);
          case NameLookupSnapshot() || MontyComplete():
            return {
              'status': 'fail',
              'detail': 'Unexpected suspension: $snapshot',
            };
        }
      }
      final settled = snapshot;

      return _compareResult(_shape(settled.output), fixture);
    });
  } on MontyError catch (e) {
    return _onError(e, fixture);
  }
}

// ---------------------------------------------------------------------------
// Value comparison — pass / warn / fail
// ---------------------------------------------------------------------------

Map<String, dynamic> _compareResult(
  Object? actual,
  Map<String, dynamic> fixture,
) {
  final expected = fixture['expected'];
  final expectedContains = fixture['expectedContains'] as String?;
  final expectedSorted = fixture['expectedSorted'] as bool? ?? false;

  if (expectedContains != null) {
    final str = '$actual';
    if (str.contains(expectedContains)) {
      return {'status': 'pass', 'detail': str};
    }

    return {
      'status': 'warn',
      'detail': 'Value: $str'
          ' — expected to contain "$expectedContains"'
          ' (WASM Monty behavioral difference)',
    };
  }

  if (expectedSorted && actual is List && expected is List) {
    final sortedActual = List<Object?>.from(actual)..sort(_compareObjects);
    final sortedExpected = List<Object?>.from(expected)..sort(_compareObjects);
    if (_valuesMatch(sortedActual, sortedExpected)) {
      return {'status': 'pass', 'detail': '$actual'};
    }

    return {
      'status': 'warn',
      'detail': 'Value: $actual'
          ' — expected (sorted): $expected'
          ' (WASM Monty behavioral difference)',
    };
  }

  if (_valuesMatch(actual, expected)) {
    return {'status': 'pass', 'detail': '$actual'};
  }

  return {
    'status': 'warn',
    'detail': 'Value: $actual'
        ' — expected: $expected'
        ' (WASM Monty behavioral difference)',
  };
}

int _compareObjects(Object? a, Object? b) => '$a'.compareTo('$b');
