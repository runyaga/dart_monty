/// Web Python Ladder Runner — compiled to JS, runs in headless Chrome.
///
/// Fetches fixture JSON from the HTTP server, runs each through montyBridge,
/// and prints JSONL results prefixed with LADDER_RESULT: for extraction.
///
/// Build:
///   dart compile js bin/ladder_runner.dart -o web/ladder_runner.dart.js
library;

import 'dart:convert';
import 'dart:js_interop';

// ---------------------------------------------------------------------------
// JS interop bindings for window.montyBridge
// ---------------------------------------------------------------------------

@JS('montyBridge.init')
external JSPromise<JSBoolean> _montyInit();

@JS('montyBridge.run')
external JSPromise<JSString> _montyRun(JSString code);

@JS('montyBridge.start')
external JSPromise<JSString> _montyStart(JSString code, JSString extFnsJson);

@JS('montyBridge.resume')
external JSPromise<JSString> _montyResume(JSString valueJson);

@JS('montyBridge.resumeWithError')
external JSPromise<JSString> _montyResumeWithError(JSString errorJson);

// ---------------------------------------------------------------------------
// JS fetch interop
// ---------------------------------------------------------------------------

@JS('fetch')
external JSPromise<_Response> _jsFetch(JSString url);

extension type _Response(JSObject _) implements JSObject {
  external JSPromise<JSString> text();
}

// ---------------------------------------------------------------------------
// Fixture tier files (hardcoded since we can't list directories via HTTP)
// ---------------------------------------------------------------------------

const _tierFiles = [
  'fixtures/tier_01_expressions.json',
  'fixtures/tier_02_variables.json',
  'fixtures/tier_03_control_flow.json',
  'fixtures/tier_04_functions.json',
  'fixtures/tier_05_errors.json',
  'fixtures/tier_06_external_fns.json',
  'fixtures/tier_07_advanced.json',
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Map<String, dynamic> _parseResult(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

Future<String> _fetchText(String url) async {
  final response = await _jsFetch(url.toJS).toDart;
  return (await response.text().toDart).toDart;
}

void _output(Map<String, dynamic> result) {
  print('LADDER_RESULT:${jsonEncode(result)}');
}

// ---------------------------------------------------------------------------
// Runner logic
// ---------------------------------------------------------------------------

Future<void> main() async {
  print('=== Web Python Ladder Runner ===');

  // Initialize Monty Worker
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
      result = await _runSimple(id, code);
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

Future<Map<String, dynamic>> _runSimple(int id, String code) async {
  final result = _parseResult((await _montyRun(code.toJS).toDart).toDart);
  if (result['ok'] == true) {
    return {'id': id, 'ok': true, 'value': result['value']};
  }
  return {'id': id, 'ok': false, 'error': result['error']};
}

Future<Map<String, dynamic>> _runExpectError(int id, String code) async {
  final result = _parseResult((await _montyRun(code.toJS).toDart).toDart);
  if (result['ok'] == false) {
    // Expected an error — report success with the error message
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

  // Start iterative execution
  var resultJson = _parseResult(
    (await _montyStart(code.toJS, jsonEncode(extFns).toJS).toDart).toDart,
  );

  if (resultJson['ok'] != true) {
    return {'id': id, 'ok': false, 'error': resultJson['error']};
  }

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
    return {'id': id, 'ok': false, 'error': resultJson['error']};
  }
  return {'id': id, 'ok': true, 'value': resultJson['value']};
}
