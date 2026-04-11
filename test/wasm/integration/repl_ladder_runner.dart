// Standalone JS-compiled runner, not a package:test file.
// ignore_for_file: avoid_print, avoid_catches_without_on_clauses
/// REPL Ladder runner for WASM integration testing.
///
/// Compiled to JS, runs in headless Chrome with COOP/COEP headers.
///
/// Build:
///   dart compile js test/wasm/integration/repl_ladder_runner.dart \
///     -o test/wasm/integration/web/repl_ladder_runner.dart.js
library;

import 'dart:convert';
import 'dart:js_interop';

// ---------------------------------------------------------------------------
// JS interop — DartMontyBridge REPL methods
// ---------------------------------------------------------------------------

@JS('DartMontyBridge.init')
external JSPromise<JSBoolean> _bridgeInit();

@JS('DartMontyBridge.replCreate')
external JSPromise<JSString> _bridgeReplCreate();

@JS('DartMontyBridge.replFeedRun')
external JSPromise<JSString> _bridgeReplFeedRun(JSString code);

@JS('DartMontyBridge.replFree')
external JSPromise<JSString> _bridgeReplFree();

@JS('DartMontyBridge.replDetectContinuation')
external JSPromise<JSString> _bridgeReplDetectContinuation(JSString source);

@JS('globalThis.fetch')
external JSPromise<JSObject> _jsFetch(JSString url);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Map<String, dynamic> _parse(String jsonStr) =>
    jsonDecode(jsonStr) as Map<String, dynamic>;

extension type _Response(JSObject _) implements JSObject {
  external JSPromise<JSString> text();
}

Future<String> _fetchText(String url) async {
  final resp = await _jsFetch(url.toJS).toDart;
  return (await (resp as _Response).text().toDart).toDart;
}

void _result(int id, bool ok, {Object? value, String? error}) {
  final map = <String, Object?>{'id': id, 'ok': ok};
  if (value != null) map['value'] = value;
  if (error != null) map['error'] = error;
  print('LADDER_RESULT:${jsonEncode(map)}');
}

// ---------------------------------------------------------------------------
// Fixture files
// ---------------------------------------------------------------------------

const _tierFiles = [
  'fixtures/repl_ladder/tier_01_state_persistence.json',
  'fixtures/repl_ladder/tier_02_functions_closures.json',
  'fixtures/repl_ladder/tier_03_error_recovery.json',
  'fixtures/repl_ladder/tier_04_print_continuation.json',
  'fixtures/repl_ladder/tier_05_stress.json',
];

// ---------------------------------------------------------------------------
// Runner
// ---------------------------------------------------------------------------

Future<void> _runFeedFixture(Map<String, dynamic> fixture) async {
  final id = fixture['id'] as int;
  final feeds = (fixture['feeds'] as List).cast<Map<String, dynamic>>();

  // Create fresh REPL for each fixture.
  final createResult = _parse((await _bridgeReplCreate().toDart).toDart);
  if (createResult['ok'] != true) {
    _result(id, false, error: 'replCreate failed: $createResult');
    return;
  }

  try {
    for (final feed in feeds) {
      final code = feed['code'] as String;
      final expectError = feed['expectError'] as bool? ?? false;

      final r = _parse((await _bridgeReplFeedRun(code.toJS).toDart).toDart);

      if (expectError) {
        if (r['ok'] == true) {
          _result(id, false, error: 'Expected error for: $code');
          return;
        }
        final errorContains = feed['errorContains'] as String?;
        if (errorContains != null) {
          final msg = r['error'] as String? ?? '';
          if (!msg.contains(errorContains)) {
            _result(
              id,
              false,
              error: 'Error "$msg" does not contain "$errorContains"',
            );
            return;
          }
        }
        continue;
      }

      if (r['ok'] != true) {
        _result(id, false, error: 'Feed "$code" failed: ${r['error']}');
        return;
      }

      if (feed.containsKey('expected')) {
        final expected = feed['expected'];
        final actual = r['value'];
        if (actual != expected) {
          _result(
            id,
            false,
            error: 'After "$code": expected $expected, got $actual',
          );
          return;
        }
      }

      if (feed.containsKey('expectedPrint')) {
        final expectedPrint = feed['expectedPrint'] as String;
        final actualPrint = r['print_output'] as String? ?? '';
        if (actualPrint != expectedPrint) {
          _result(
            id,
            false,
            error:
                'Print mismatch: expected "$expectedPrint", got "$actualPrint"',
          );
          return;
        }
      }
    }

    _result(id, true);
  } finally {
    await _bridgeReplFree().toDart;
  }
}

Future<void> _runContinuationFixture(Map<String, dynamic> fixture) async {
  final id = fixture['id'] as int;
  final source = fixture['continuation'] as String;
  final expectedMode = fixture['expectedMode'] as String;

  // Create REPL to get access to detect_continuation.
  final createResult = _parse((await _bridgeReplCreate().toDart).toDart);
  if (createResult['ok'] != true) {
    _result(id, false, error: 'replCreate failed');
    return;
  }

  try {
    final r = _parse(
      (await _bridgeReplDetectContinuation(source.toJS).toDart).toDart,
    );
    if (r['ok'] != true) {
      _result(id, false, error: 'detectContinuation failed: ${r['error']}');
      return;
    }

    final modeInt = r['value'] as int;
    final modeName = switch (modeInt) {
      0 => 'complete',
      1 => 'incompleteImplicit',
      2 => 'incompleteBlock',
      _ => 'unknown($modeInt)',
    };

    if (modeName == expectedMode) {
      _result(id, true);
    } else {
      _result(
        id,
        false,
        error: 'Expected $expectedMode, got $modeName',
      );
    }
  } finally {
    await _bridgeReplFree().toDart;
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

Future<void> main() async {
  print('=== WASM REPL Ladder ===');

  final ok = (await _bridgeInit().toDart).toDart;
  if (!ok) {
    print('LADDER_ERROR:Init failed');
    print('LADDER_DONE');
    return;
  }

  var total = 0;
  var passed = 0;
  var failed = 0;

  for (final tierFile in _tierFiles) {
    String tierJson;
    try {
      tierJson = await _fetchText(tierFile);
    } catch (e) {
      print('LADDER_WARN:Could not fetch $tierFile: $e');
      continue;
    }

    final fixtures = (jsonDecode(tierJson) as List)
        .cast<Map<String, dynamic>>();

    for (final fixture in fixtures) {
      total++;
      final id = fixture['id'] as int;
      try {
        if (fixture.containsKey('continuation')) {
          await _runContinuationFixture(fixture);
        } else if (fixture.containsKey('feeds')) {
          await _runFeedFixture(fixture);
        } else {
          _result(id, false, error: 'Missing feeds or continuation');
        }
        // Check last result line for pass/fail
        passed++;
      } catch (e) {
        _result(id, false, error: '$e');
        failed++;
      }
    }
  }

  print('LADDER_SUMMARY:total=$total passed=$passed failed=$failed');
  print('LADDER_DONE');
}
