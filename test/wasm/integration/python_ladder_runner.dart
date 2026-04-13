// Standalone JS-compiled runner, not a package:test file.
// ignore_for_file: avoid_print, avoid_catches_without_on_clauses
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

import 'dart:convert';
import 'dart:js_interop';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';

// ---------------------------------------------------------------------------
// JS interop bindings for window.DartMontyBridge
// ---------------------------------------------------------------------------

@JS('DartMontyBridge.init')
external JSPromise<JSBoolean> _montyInit();

@JS('DartMontyBridge.run')
external JSPromise<JSString> _montyRun(JSString code);

@JS('DartMontyBridge.start')
external JSPromise<JSString> _montyStart(JSString code, [JSString? extFnsJson]);

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
  'fixtures/tier_10_math_module.json',
  'fixtures/tier_11_re_module.json',
  'fixtures/tier_12_monty_008_features.json',
  'fixtures/tier_13_async.json',
  'fixtures/tier_15_script_name.json',
  'fixtures/tier_16_memory_growth.json',
  'fixtures/tier_17_json_module.json',
  'fixtures/tier_18_datetime_module.json',
  'fixtures/tier_19_lifecycle_errors.json',
  'fixtures/tier_20_oscall.json',
  'fixtures/tier_21_fs_modes.json',
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
  try {
    await _runLadder();
  } catch (e, st) {
    print('LADDER_ERROR:Unhandled exception in main: $e');
    print('LADDER_STACKTRACE:$st');
    print('LADDER_DONE');
  }
}

Future<void> _runLadder() async {
  print('=== WASM Python Ladder Runner ===');

  late final bool ok;
  try {
    ok = (await _montyInit().toDart).toDart;
  } catch (e, st) {
    print('LADDER_ERROR:DartMontyBridge.init() threw: $e');
    print('LADDER_STACKTRACE:$st');
    print('LADDER_DONE');

    return;
  }

  if (!ok) {
    print('LADDER_ERROR:Monty Worker init returned false');
    print('LADDER_DONE');

    return;
  }

  print('LADDER_INFO:Worker initialized successfully');

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
    } catch (e, st) {
      print('LADDER_ERROR:Failed to load $tierFile: $e');
      print('LADDER_STACKTRACE:$st');
    }
  }

  print('LADDER_DONE');
}

Future<Map<String, dynamic>> _runFixture(Map<String, dynamic> fixture) async {
  final id = fixture['id'] as int;
  final code = fixture['code'] as String;
  final expectError = fixture['expectError'] as bool? ?? false;
  final osCall = fixture['osCall'] as bool? ?? false;
  final xfail = fixture['xfail'] as String?;

  Map<String, dynamic> result;
  try {
    if (osCall) {
      result = await _runOsCall(fixture);
    } else if (fixture['externalFunctions'] != null) {
      result = await _runIterative(fixture);
      // Iterative path returns ok/error directly — flip for expectError.
      if (expectError) {
        if (result['ok'] == false) {
          result = {'id': id, 'ok': true, 'error': result['error']};
        } else {
          result = {
            'id': id,
            'ok': false,
            'error': 'Expected error but succeeded',
          };
        }
      }
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

/// Handles OsCall fixtures using start/resume with the appropriate provider.
Future<Map<String, dynamic>> _runOsCall(Map<String, dynamic> fixture) async {
  final id = fixture['id'] as int;
  final code = fixture['code'] as String;
  final expectError = fixture['expectError'] as bool? ?? false;
  final provider = _buildFixtureProvider(fixture);

  var state = _parseResult((await _montyStart(code.toJS).toDart).toDart);

  if (state['ok'] != true) {
    if (expectError) return {'id': id, 'ok': true, 'error': state['error']};

    return {'id': id, 'ok': false, 'error': state['error']};
  }

  while (state['state'] != 'complete') {
    if (state['ok'] != true) {
      if (expectError) return {'id': id, 'ok': true, 'error': state['error']};

      return {'id': id, 'ok': false, 'error': state['error']};
    }

    if (state['state'] == 'os_call') {
      final fnName = state['functionName'] as String;
      final rawArgs = state['args'] as List? ?? [];
      final rawKwargs = state['kwargs'] as Map<String, dynamic>?;
      final callId = state['callId'] as int? ?? 0;
      final osCall = MontyOsCall(
        operationName: fnName,
        arguments: rawArgs.map(MontyValue.fromJson).toList(),
        kwargs: rawKwargs?.map(
          (k, v) => MapEntry(k, MontyValue.fromJson(v)),
        ),
        callId: callId,
      );
      try {
        final result = await provider.resolve(osCall);
        state = _parseResult(
          (await _montyResume(jsonEncode(result).toJS).toDart).toDart,
        );
      } on Object catch (e) {
        state = _parseResult(
          (await _montyResumeWithError(
            jsonEncode(e.toString()).toJS,
          ).toDart).toDart,
        );
      }
    } else if (state['state'] == 'pending') {
      state = _parseResult(
        (await _montyResumeWithError(
          jsonEncode('Unexpected external function').toJS,
        ).toDart).toDart,
      );
    } else {
      return {
        'id': id,
        'ok': false,
        'error': 'Unexpected state: ${state['state']}',
      };
    }
  }

  if (expectError) {
    if (state['ok'] == false || state['error'] != null) {
      return {'id': id, 'ok': true, 'error': state['error']};
    }

    return {'id': id, 'ok': false, 'error': 'Expected error but succeeded'};
  }

  if (state['ok'] != true) {
    return {'id': id, 'ok': false, 'error': state['error']};
  }

  return {'id': id, 'ok': true, 'value': state['value']};
}

/// Builds the appropriate OsProvider for a fixture based on `fsMode`.
OsProvider _buildFixtureProvider(Map<String, dynamic> fixture) {
  final fsMode = fixture['fsMode'] as String? ?? 'memory';
  final prePopulate = fixture['prePopulate'] as Map<String, dynamic>?;
  final time = TimeOsProvider();

  switch (fsMode) {
    case 'readonly':
      final vfs = MemoryFsProvider();
      prePopulate?.forEach((k, v) => vfs.writeFile(k, v as String));

      return OsProvider.compose({
        'Path.': ReadOnlyFsProvider(vfs),
        'date.': time,
        'datetime.': time,
      });

    case 'overlay':
      final base = MemoryFsProvider();
      prePopulate?.forEach((k, v) => base.writeFile(k, v as String));

      return OsProvider.compose({
        'Path.': OverlayFsProvider(base: base, scratch: MemoryFsProvider()),
        'date.': time,
        'datetime.': time,
      });

    default: // 'memory'
      return OsProvider.compose({
        'Path.': MemoryFsProvider(),
        'date.': time,
        'datetime.': time,
      });
  }
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
    return {'id': id, 'ok': true, 'error': result['error']};
  }
  return {'id': id, 'ok': false, 'error': 'Expected error but succeeded'};
}

Future<Map<String, dynamic>> _runIterative(Map<String, dynamic> fixture) async {
  final id = fixture['id'] as int;
  final code = fixture['code'] as String;
  final extFns = (fixture['externalFunctions'] as List).cast<String>();
  final resumeValues = (fixture['resumeValues'] as List?)?.cast<Object>();
  final resumeErrors = (fixture['resumeErrors'] as List?)?.cast<String>();
  final asyncResumeMap = fixture['asyncResumeMap'] as Map<String, dynamic>?;
  final asyncErrorMap = fixture['asyncErrorMap'] as Map<String, dynamic>?;

  var resultJson = _parseResult(
    (await _montyStart(code.toJS, jsonEncode(extFns).toJS).toDart).toDart,
  );

  if (resultJson['ok'] != true) {
    return {'id': id, 'ok': false, 'error': resultJson['error']};
  }

  // Async futures path: resumeAsFuture + resolveFutures loop.
  if (asyncResumeMap != null) {
    return _runAsyncFutures(id, resultJson, asyncResumeMap, asyncErrorMap);
  }

  if (resumeErrors != null) {
    for (final errorMsg in resumeErrors) {
      if (resultJson['state'] != 'pending') {
        return {'id': id, 'ok': false, 'error': 'Expected pending state'};
      }
      resultJson = _parseResult(
        (await _montyResumeWithError(jsonEncode(errorMsg).toJS).toDart).toDart,
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

/// Drives the resumeAsFuture / resolveFutures state machine for async
/// fixtures, mirroring the ladder_runner.dart logic in platform_interface.
Future<Map<String, dynamic>> _runAsyncFutures(
  int id,
  Map<String, dynamic> resultJson,
  Map<String, dynamic> asyncResumeMap,
  Map<String, dynamic>? asyncErrorMap,
) async {
  var state = resultJson;

  while (state['state'] != 'complete') {
    if (state['ok'] != true) {
      return {'id': id, 'ok': false, 'error': state['error']};
    }

    if (state['state'] == 'pending') {
      // External function call — tell runtime to treat it as a future.
      state = _parseResult((await _montyResumeAsFuture().toDart).toDart);
    } else if (state['state'] == 'resolve_futures') {
      // Resolve pending futures with values/errors from the fixture maps.
      final pendingIds =
          (state['pendingCallIds'] as List?)?.cast<num>() ?? <num>[];
      final results = <String, Object?>{};
      final errors = <String, String>{};
      for (final callId in pendingIds) {
        final key = callId.toInt().toString();
        if (asyncErrorMap != null && asyncErrorMap.containsKey(key)) {
          errors[key] = asyncErrorMap[key] as String;
        } else if (asyncResumeMap.containsKey(key)) {
          results[key] = asyncResumeMap[key];
        }
      }
      state = _parseResult(
        (await _montyResolveFutures(
          jsonEncode(results).toJS,
          jsonEncode(errors).toJS,
        ).toDart).toDart,
      );
    } else {
      return {
        'id': id,
        'ok': false,
        'error': 'Unexpected state: ${state['state']}',
      };
    }
  }

  if (state['ok'] != true) {
    return {'id': id, 'ok': false, 'error': state['error']};
  }
  return {'id': id, 'ok': true, 'value': state['value']};
}
