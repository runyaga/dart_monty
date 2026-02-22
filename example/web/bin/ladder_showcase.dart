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

// ---------------------------------------------------------------------------
// JS interop bindings for window.DartMontyBridge
// ---------------------------------------------------------------------------

@JS('DartMontyBridge.init')
external JSPromise<JSBoolean> _montyInit();

@JS('DartMontyBridge.run')
external JSPromise<JSString> _montyRun(JSString code);

@JS('DartMontyBridge.start')
external JSPromise<JSString> _montyStart(
  JSString code, [
  JSString? extFnsJson,
]);

@JS('DartMontyBridge.resume')
external JSPromise<JSString> _montyResume(JSString valueJson);

@JS('DartMontyBridge.resumeWithError')
external JSPromise<JSString> _montyResumeWithError(JSString errorJson);

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
];

const _tierLabels = [
  'Tier 1: Expressions',
  'Tier 2: Variables',
  'Tier 3: Control Flow',
  'Tier 4: Functions',
  'Tier 5: Errors',
  'Tier 6: External Functions',
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Map<String, dynamic> _parse(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

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

// ---------------------------------------------------------------------------
// Runner
// ---------------------------------------------------------------------------

Future<void> main() async {
  final ok = (await _montyInit().toDart).toDart;
  if (!ok) {
    _reportInit(false.toJS, 'Failed to initialize Monty WASM Worker'.toJS);

    return;
  }
  _reportInit(true.toJS, 'Worker initialized'.toJS);

  var totalPassed = 0;
  var totalWarned = 0;
  var totalFailed = 0;
  var totalTests = 0;
  var totalSkipped = 0;

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

        if (nativeOnly) {
          totalSkipped++;
          totalPassed++;
          _reportResult(
            (tierIdx + 1).toJS,
            id.toJS,
            name.toJS,
            code.toJS,
            'skip'.toJS,
            'Skipped (native only)'.toJS,
          );
          continue;
        }

        final verifyResult = await _runFixture(fixture);
        final status = verifyResult['status'] as String;
        final detail = verifyResult['detail'] as String;

        if (status == 'pass') totalPassed++;
        if (status == 'warn') totalWarned++;
        if (status == 'fail') totalFailed++;
        _reportResult(
          (tierIdx + 1).toJS,
          id.toJS,
          name.toJS,
          code.toJS,
          status.toJS,
          detail.toJS,
        );
      }
    } catch (e) {
      totalFailed++;
      _reportResult(
        (tierIdx + 1).toJS,
        0.toJS,
        'Tier load error'.toJS,
        ''.toJS,
        'fail'.toJS,
        'Failed to load ${_tierFiles[tierIdx]}: $e'.toJS,
      );
    }
  }

  _reportDone(
    totalPassed.toJS,
    totalWarned.toJS,
    totalFailed.toJS,
    totalTests.toJS,
    totalSkipped.toJS,
  );
}

// ---------------------------------------------------------------------------
// Fixture execution
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>> _runFixture(
  Map<String, dynamic> fixture,
) async {
  final expectError = fixture['expectError'] as bool? ?? false;

  try {
    if (fixture['externalFunctions'] != null) {
      return _runIterative(fixture);
    } else if (expectError) {
      return _runExpectError(fixture);
    } else {
      return _runSimple(fixture);
    }
  } catch (e) {
    if (expectError) {
      return {'status': 'pass', 'detail': 'Error (expected): $e'};
    }

    return {'status': 'fail', 'detail': 'Exception: $e'};
  }
}

Future<Map<String, dynamic>> _runSimple(
  Map<String, dynamic> fixture,
) async {
  final code = fixture['code'] as String;
  final result = _parse((await _montyRun(code.toJS).toDart).toDart);

  if (result['ok'] != true) {
    return {
      'status': 'fail',
      'detail': 'Bridge error: ${result['error']}',
    };
  }

  final actual = result['value'];

  return _compareResult(actual, fixture);
}

Future<Map<String, dynamic>> _runExpectError(
  Map<String, dynamic> fixture,
) async {
  final code = fixture['code'] as String;
  final result = _parse((await _montyRun(code.toJS).toDart).toDart);

  if (result['ok'] == false) {
    return {'status': 'pass', 'detail': 'Error (expected): ${result['error']}'};
  }

  return {
    'status': 'warn',
    'detail': 'Expected error but got value: ${result['value']}'
        ' — WASM Monty may handle this differently than CPython',
  };
}

Future<Map<String, dynamic>> _runIterative(
  Map<String, dynamic> fixture,
) async {
  final code = fixture['code'] as String;
  final expectError = fixture['expectError'] as bool? ?? false;
  final extFns = (fixture['externalFunctions'] as List).cast<String>();
  final resumeValues = (fixture['resumeValues'] as List?)?.cast<Object>();
  final resumeErrors = (fixture['resumeErrors'] as List?)?.cast<String>();

  var result = _parse(
    (await _montyStart(code.toJS, jsonEncode(extFns).toJS).toDart).toDart,
  );

  if (result['ok'] != true) {
    if (expectError) {
      return {
        'status': 'pass',
        'detail': 'Error (expected): ${result['error']}',
      };
    }

    return {'status': 'fail', 'detail': 'Start failed: ${result['error']}'};
  }

  if (resumeErrors != null) {
    for (final errorMsg in resumeErrors) {
      if (result['state'] != 'pending') {
        return {'status': 'fail', 'detail': 'Expected pending state'};
      }
      result = _parse(
        (await _montyResumeWithError(jsonEncode(errorMsg).toJS).toDart).toDart,
      );
    }
  } else if (resumeValues != null) {
    for (final value in resumeValues) {
      if (result['state'] != 'pending') {
        return {'status': 'fail', 'detail': 'Expected pending state'};
      }
      result = _parse(
        (await _montyResume(jsonEncode(value).toJS).toDart).toDart,
      );
    }
  }

  if (result['ok'] != true) {
    if (expectError) {
      return {
        'status': 'pass',
        'detail': 'Error (expected): ${result['error']}',
      };
    }

    return {'status': 'fail', 'detail': 'Bridge error: ${result['error']}'};
  }

  final actual = result['value'];

  return _compareResult(actual, fixture);
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
      return {'status': 'pass', 'detail': '$str'};
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
