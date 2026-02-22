/// Ladder Showcase — runs all Python ladder fixtures in-browser with visual
/// pass/fail output to the DOM.
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
  JSBoolean passed,
  JSString detail,
);

@JS('reportTierHeader')
external void _reportTierHeader(JSString label);

@JS('reportDone')
external void _reportDone(JSNumber passed, JSNumber total, JSNumber skipped);

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
  final jsTrue = true.toJS;
  final ok = (await _montyInit().toDart).toDart;
  if (!ok) {
    _reportInit(false.toJS, 'Failed to initialize Monty WASM Worker'.toJS);

    return;
  }
  _reportInit(jsTrue, 'Worker initialized'.toJS);

  var totalPassed = 0;
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
          _reportResult(
            (tierIdx + 1).toJS,
            id.toJS,
            name.toJS,
            code.toJS,
            jsTrue,
            'Skipped (native only)'.toJS,
          );
          totalPassed++;
          continue;
        }

        final verifyResult = await _runAndVerify(fixture);
        final passed = verifyResult['passed'] as bool;
        final detail = verifyResult['detail'] as String;

        if (passed) totalPassed++;
        _reportResult(
          (tierIdx + 1).toJS,
          id.toJS,
          name.toJS,
          code.toJS,
          passed.toJS,
          detail.toJS,
        );
      }
    } catch (e) {
      _reportResult(
        (tierIdx + 1).toJS,
        0.toJS,
        'Tier load error'.toJS,
        ''.toJS,
        false.toJS,
        'Failed to load ${_tierFiles[tierIdx]}: $e'.toJS,
      );
    }
  }

  _reportDone(totalPassed.toJS, totalTests.toJS, totalSkipped.toJS);
}

Future<Map<String, dynamic>> _runAndVerify(
  Map<String, dynamic> fixture,
) async {
  final expected = fixture['expected'];
  final expectedContains = fixture['expectedContains'] as String?;
  final expectedSorted = fixture['expectedSorted'] as bool? ?? false;
  final expectError = fixture['expectError'] as bool? ?? false;
  final errorContains = fixture['errorContains'] as String?;

  try {
    if (fixture['externalFunctions'] != null) {
      return _runIterative(fixture);
    } else if (expectError) {
      return _verifyError(fixture);
    } else {
      return _verifySimple(
        fixture,
        expected,
        expectedContains,
        expectedSorted,
      );
    }
  } catch (e) {
    if (expectError) {
      final errStr = '$e';
      if (errorContains != null && !errStr.contains(errorContains)) {
        return {
          'passed': false,
          'detail': 'Expected error containing "$errorContains", got: $errStr',
        };
      }

      return {'passed': true, 'detail': 'Error (expected): $errStr'};
    }

    return {'passed': false, 'detail': 'Exception: $e'};
  }
}

Future<Map<String, dynamic>> _verifySimple(
  Map<String, dynamic> fixture,
  Object? expected,
  String? expectedContains,
  bool expectedSorted,
) async {
  final code = fixture['code'] as String;
  final result = _parse((await _montyRun(code.toJS).toDart).toDart);

  if (result['ok'] != true) {
    return {
      'passed': false,
      'detail': 'Run failed: ${result['error']}',
    };
  }

  final actual = result['value'];

  return _checkValue(actual, expected, expectedContains, expectedSorted);
}

Future<Map<String, dynamic>> _verifyError(
  Map<String, dynamic> fixture,
) async {
  final code = fixture['code'] as String;
  final errorContains = fixture['errorContains'] as String?;
  final result = _parse((await _montyRun(code.toJS).toDart).toDart);

  if (result['ok'] == false) {
    final errMsg = '${result['error']}';
    if (errorContains != null && !errMsg.contains(errorContains)) {
      return {
        'passed': false,
        'detail': 'Error did not contain "$errorContains". Got: $errMsg',
      };
    }

    return {'passed': true, 'detail': 'Error (expected): $errMsg'};
  }

  return {
    'passed': false,
    'detail': 'Expected error but got value: ${result['value']}',
  };
}

Future<Map<String, dynamic>> _runIterative(
  Map<String, dynamic> fixture,
) async {
  final code = fixture['code'] as String;
  final expected = fixture['expected'];
  final expectedContains = fixture['expectedContains'] as String?;
  final expectedSorted = fixture['expectedSorted'] as bool? ?? false;
  final expectError = fixture['expectError'] as bool? ?? false;
  final errorContains = fixture['errorContains'] as String?;
  final extFns = (fixture['externalFunctions'] as List).cast<String>();
  final resumeValues = (fixture['resumeValues'] as List?)?.cast<Object>();
  final resumeErrors = (fixture['resumeErrors'] as List?)?.cast<String>();

  var result = _parse(
    (await _montyStart(code.toJS, jsonEncode(extFns).toJS).toDart).toDart,
  );

  if (result['ok'] != true) {
    if (expectError) {
      final errMsg = '${result['error']}';
      if (errorContains != null && !errMsg.contains(errorContains)) {
        return {
          'passed': false,
          'detail': 'Error did not contain "$errorContains". Got: $errMsg',
        };
      }

      return {'passed': true, 'detail': 'Error (expected): $errMsg'};
    }

    return {'passed': false, 'detail': 'Start failed: ${result['error']}'};
  }

  if (resumeErrors != null) {
    for (final errorMsg in resumeErrors) {
      if (result['state'] != 'pending') {
        return {'passed': false, 'detail': 'Expected pending state'};
      }
      result = _parse(
        (await _montyResumeWithError(jsonEncode(errorMsg).toJS).toDart).toDart,
      );
    }
  } else if (resumeValues != null) {
    for (final value in resumeValues) {
      if (result['state'] != 'pending') {
        return {'passed': false, 'detail': 'Expected pending state'};
      }
      result = _parse(
        (await _montyResume(jsonEncode(value).toJS).toDart).toDart,
      );
    }
  }

  if (result['ok'] != true) {
    if (expectError) {
      final errMsg = '${result['error']}';
      if (errorContains != null && !errMsg.contains(errorContains)) {
        return {
          'passed': false,
          'detail': 'Error did not contain "$errorContains". Got: $errMsg',
        };
      }

      return {'passed': true, 'detail': 'Error (expected): $errMsg'};
    }

    return {'passed': false, 'detail': 'Run failed: ${result['error']}'};
  }

  final actual = result['value'];

  return _checkValue(actual, expected, expectedContains, expectedSorted);
}

Map<String, dynamic> _checkValue(
  Object? actual,
  Object? expected,
  String? expectedContains,
  bool expectedSorted,
) {
  if (expectedContains != null) {
    final str = '$actual';
    if (str.contains(expectedContains)) {
      return {'passed': true, 'detail': 'Contains "$expectedContains": $str'};
    }

    return {
      'passed': false,
      'detail': 'Expected to contain "$expectedContains". Got: $str',
    };
  }

  if (expectedSorted && actual is List && expected is List) {
    final sortedActual = List<Object?>.from(actual)..sort(_compareObjects);
    final sortedExpected = List<Object?>.from(expected)..sort(_compareObjects);
    if (_valuesMatch(sortedActual, sortedExpected)) {
      return {'passed': true, 'detail': '$actual (sorted match)'};
    }

    return {
      'passed': false,
      'detail': 'Expected (sorted): $expected, got: $actual',
    };
  }

  if (_valuesMatch(actual, expected)) {
    return {'passed': true, 'detail': '$actual'};
  }

  return {
    'passed': false,
    'detail': 'Expected: $expected, got: $actual',
  };
}

int _compareObjects(Object? a, Object? b) => '$a'.compareTo('$b');
