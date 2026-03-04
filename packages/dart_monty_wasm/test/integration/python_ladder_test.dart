/// Web Python Ladder Runner for dart_monty_wasm.
///
/// Compiled to JS, runs in headless Chrome with COOP/COEP headers.
/// Fetches fixture JSON from the HTTP server, runs each through
/// DartMontyBridge, and prints JSONL results prefixed with LADDER_RESULT:
/// This is a standalone executable, not a package:test file.
///
/// Build:
///   dart compile js test/integration/python_ladder_test.dart \
///     -o test/integration/web/ladder_runner.dart.js
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

// ---------------------------------------------------------------------------
// JS interop bindings for window.DartMontyBridge
// ---------------------------------------------------------------------------

@JS('DartMontyBridge.init')
external JSPromise<JSBoolean> _montyInit();

@JS('DartMontyBridge.run')
external JSPromise<JSString> _montyRun(JSString code, [JSString? limitsJson]);

@JS('DartMontyBridge.start')
external JSPromise<JSString> _montyStart(
  JSString code, [
  JSString? extFnsJson,
  JSString? limitsJson,
]);

@JS('DartMontyBridge.resume')
external JSPromise<JSString> _montyResume(JSString valueJson);

@JS('DartMontyBridge.resumeWithError')
external JSPromise<JSString> _montyResumeWithError(JSString errorJson);

@JS('DartMontyBridge.resumeAsFuture')
external JSPromise<JSString> _montyResumeAsFuture();

@JS('DartMontyBridge.resolveFutures')
external JSPromise<JSString> _montyResolveFutures(
  JSString resultsJson,
  JSString errorsJson,
);

// ---------------------------------------------------------------------------
// JS fetch interop
// ---------------------------------------------------------------------------

@JS('fetch')
external JSPromise<_Response> _jsFetch(JSString url);

extension type _Response(JSObject _) implements JSObject {
  external JSPromise<JSString> text();
}

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
  'fixtures/tier_13_async.json',
  'fixtures/tier_14_async_stress.json',
  'fixtures/tier_15_script_name.json',
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const _fixtureTimeout = Duration(seconds: 30);

Map<String, dynamic> _parseResult(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

/// Call a bridge function with a wall-clock timeout.
/// Prevents indefinite hangs if the Worker deadlocks.
Future<String> _withTimeout(JSPromise<JSString> Function() fn) async {
  final result = await fn().toDart.timeout(
        _fixtureTimeout,
        onTimeout: () => throw TimeoutException(
          'Worker did not respond within ${_fixtureTimeout.inSeconds}s',
        ),
      );
  return result.toDart;
}

Future<String> _fetchText(String url) async {
  final response = await _jsFetch(url.toJS).toDart;
  return (await response.text().toDart).toDart;
}

void _output(Map<String, dynamic> result) {
  print('LADDER_RESULT:${jsonEncode(result)}');
}

/// Validate actual value against fixture expectations.
/// Returns null if valid, or an error string if mismatched.
String? _validateValue(Object? actual, Map<String, dynamic> fixture) {
  final expectedContains = fixture['expectedContains'] as String?;
  if (expectedContains != null) {
    if (!actual.toString().contains(expectedContains)) {
      return 'expected value containing "$expectedContains", '
          'got: "$actual"';
    }
    return null;
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

  final actualJson = jsonEncode(sortedActual);
  final expectedJson = jsonEncode(expected);
  if (actualJson != expectedJson) {
    return 'expected $expectedJson, got $actualJson';
  }
  return null;
}

// ---------------------------------------------------------------------------
// Runner logic
// ---------------------------------------------------------------------------

Future<void> main() async {
  print('=== WASM Python Ladder Runner ===');

  final ok = (await _montyInit().toDart).toDart;
  if (!ok) {
    print('LADDER_ERROR:Monty Worker init failed');
    print('LADDER_DONE');
    return;
  }

  for (final tierFile in _tierFiles) {
    try {
      final json = await _fetchText(tierFile);
      final fixtures = (jsonDecode(json) as List).cast<Map<String, dynamic>>();

      for (final fixture in fixtures) {
        final nativeOnly = fixture['nativeOnly'] as bool? ?? false;
        if (nativeOnly) {
          _output({
            'id': fixture['id'],
            'ok': true,
            'skipped': true,
            'reason': 'nativeOnly',
          });
          continue;
        }

        final result = await _runFixture(fixture);
        _output(result);
      }
    } catch (e) {
      print('LADDER_ERROR:Failed to load $tierFile: $e');
    }
  }

  print('LADDER_DONE');
}

Future<Map<String, dynamic>> _runFixture(
  Map<String, dynamic> fixture,
) async {
  final id = fixture['id'] as int;
  final code = fixture['code'] as String;
  final expectError = fixture['expectError'] as bool? ?? false;
  final xfail = fixture['xfail'] as String?;

  Map<String, dynamic> result;
  try {
    if (fixture['externalFunctions'] != null) {
      result = await _runIterative(fixture);
    } else if (expectError) {
      result = await _runExpectError(id, code);
    } else {
      result = await _runSimple(id, code, fixture);
    }
  } catch (e) {
    result = {'id': id, 'ok': false, 'error': '$e'};
  }

  if (xfail != null) {
    if (result['ok'] == true) {
      return {'id': id, 'ok': true, 'xpass': true};
    } else {
      return {'id': id, 'ok': true, 'xfail': true};
    }
  }
  return result;
}

Future<Map<String, dynamic>> _runSimple(
  int id,
  String code,
  Map<String, dynamic> fixture,
) async {
  final result = _parseResult((await _montyRun(code.toJS).toDart).toDart);
  if (result['ok'] == true) {
    final mismatch = _validateValue(result['value'], fixture);
    if (mismatch != null) {
      return {'id': id, 'ok': false, 'error': 'VALUE_MISMATCH: $mismatch'};
    }
    return {'id': id, 'ok': true, 'value': result['value']};
  }
  return {'id': id, 'ok': false, 'error': result['error']};
}

Future<Map<String, dynamic>> _runExpectError(int id, String code) async {
  final result = _parseResult((await _montyRun(code.toJS).toDart).toDart);
  if (result['ok'] == false) {
    return {'id': id, 'ok': true, 'error': result['error']};
  }
  return {'id': id, 'ok': false, 'error': 'Expected error but succeeded'};
}

Future<Map<String, dynamic>> _runIterative(
  Map<String, dynamic> fixture,
) async {
  final id = fixture['id'] as int;
  final code = fixture['code'] as String;
  final extFns = (fixture['externalFunctions'] as List).cast<String>();
  final resumeValues = (fixture['resumeValues'] as List?)?.cast<Object>();
  final resumeErrors = (fixture['resumeErrors'] as List?)?.cast<String>();
  final asyncResumeMap = fixture['asyncResumeMap'] as Map<String, dynamic>?;
  final asyncErrorMap = fixture['asyncErrorMap'] as Map<String, dynamic>?;
  final expectError = fixture['expectError'] as bool? ?? false;

  var resultJson = _parseResult(
    (await _montyStart(code.toJS, jsonEncode(extFns).toJS).toDart).toDart,
  );

  if (resultJson['ok'] != true) {
    return {'id': id, 'ok': false, 'error': resultJson['error']};
  }

  // Async/futures path: resumeAsFuture + resolveFutures loop
  if (asyncResumeMap != null) {
    const maxIterations = 500;
    var iterations = 0;
    while (resultJson['state'] != 'complete') {
      if (++iterations > maxIterations) {
        return {'id': id, 'ok': false, 'error': 'Exceeded max iterations'};
      }

      if (resultJson['state'] == 'pending') {
        resultJson = _parseResult(
          await _withTimeout(() => _montyResumeAsFuture()),
        );
      } else if (resultJson['state'] == 'resolve_futures') {
        final pendingIds = (resultJson['pendingCallIds'] as List).cast<int>();
        final results = <String, Object?>{};
        final errors = <String, String>{};
        for (final callId in pendingIds) {
          final key = callId.toString();
          if (asyncErrorMap != null && asyncErrorMap.containsKey(key)) {
            errors[key] = asyncErrorMap[key] as String;
          } else if (asyncResumeMap.containsKey(key)) {
            results[key] = asyncResumeMap[key];
          }
        }
        final rJson = jsonEncode(results).toJS;
        final eJson = jsonEncode(errors).toJS;
        resultJson = _parseResult(
          await _withTimeout(() => _montyResolveFutures(rJson, eJson)),
        );
      } else {
        return {
          'id': id,
          'ok': false,
          'error': 'Unexpected state: ${resultJson['state']}',
        };
      }

      if (resultJson['ok'] != true) {
        if (expectError) {
          return {'id': id, 'ok': true, 'error': resultJson['error']};
        }
        return {'id': id, 'ok': false, 'error': resultJson['error']};
      }
    }

    if (expectError) {
      return {
        'id': id,
        'ok': false,
        'error': 'Expected error but completed successfully',
      };
    }
    final mismatch = _validateValue(resultJson['value'], fixture);
    if (mismatch != null) {
      return {'id': id, 'ok': false, 'error': 'VALUE_MISMATCH: $mismatch'};
    }
    return {'id': id, 'ok': true, 'value': resultJson['value']};
  }

  // Synchronous resume paths
  if (resumeErrors != null) {
    for (final errorMsg in resumeErrors) {
      if (resultJson['state'] != 'pending') {
        return {'id': id, 'ok': false, 'error': 'Expected pending state'};
      }
      resultJson = _parseResult(
        (await _montyResumeWithError(
          jsonEncode(errorMsg).toJS,
        ).toDart)
            .toDart,
      );
    }
  } else if (resumeValues != null) {
    for (final value in resumeValues) {
      if (resultJson['state'] != 'pending') {
        return {'id': id, 'ok': false, 'error': 'Expected pending state'};
      }
      resultJson = _parseResult(
        (await _montyResume(jsonEncode(value).toJS).toDart).toDart,
      );
    }
  }

  if (resultJson['ok'] != true) {
    if (expectError) {
      final errorContains = fixture['errorContains'] as String?;
      final error = resultJson['error'] as String? ?? '';
      if (errorContains != null && !error.contains(errorContains)) {
        return {
          'id': id,
          'ok': false,
          'error': 'ERROR_MISMATCH: expected "$errorContains" in "$error"',
        };
      }
      return {'id': id, 'ok': true, 'error': resultJson['error']};
    }
    return {'id': id, 'ok': false, 'error': resultJson['error']};
  }
  if (expectError) {
    return {
      'id': id,
      'ok': false,
      'error': 'Expected error but completed successfully',
    };
  }
  final syncMismatch = _validateValue(resultJson['value'], fixture);
  if (syncMismatch != null) {
    return {'id': id, 'ok': false, 'error': 'VALUE_MISMATCH: $syncMismatch'};
  }
  return {'id': id, 'ok': true, 'value': resultJson['value']};
}
