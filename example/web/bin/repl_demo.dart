// Standalone JS-compiled demo, not a package:test file.
// ignore_for_file: avoid_print, lines_longer_than_80_chars, avoid_catches_without_on_clauses, cast_nullable_to_non_nullable
// ignore_for_file: prefer-async-await
// .then-chains in the JSFunction map below are the established JS-interop
// idiom across web demos (cf. agent_demo.dart). Rewriting to async/await
// would diverge from the project pattern.
/// Interactive REPL Session Demo — MontyRuntime in the browser.
///
/// Compiled to JS, exposes window.ReplSessionDemo to HTML.
/// All runtime dispatch runs in
/// compiled Dart — no JS host functions needed.
///
/// Build:
///   dart compile js example/web/bin/repl_demo.dart \
///     -o example/web/web/repl_demo.dart.js
library;

import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:js_interop';

import 'package:dart_monty/dart_monty.dart';
import 'package:web_example/demo_pool.dart';
import 'package:web_example/demo_ready.dart';

// ---------------------------------------------------------------------------
// JS interop — expose API to HTML
// ---------------------------------------------------------------------------

@JS('window.ReplSessionDemo')
external set _replSessionDemo(JSObject obj);

@JS('window._onReady')
external void _jsOnReady();

@JS('window._onToolCall')
external void _jsOnToolCall(JSString jsonPayload);

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

late final MontyRuntime _session;

Future<MontyRuntime> _newSession() async =>
    MontyRuntime.start(pool: await startDemoPool());

// ---------------------------------------------------------------------------
// API
// ---------------------------------------------------------------------------

/// Run Python code and return JSON result.
///
/// Printed text arrives on the execution's terminal event; the value, or
/// the Python error, on its result.
Future<String> _apiRun(String code) async {
  final handle = _session.execute(code);
  String? printOutput;
  final events = handle.events.listen((event) {
    switch (event) {
      case BridgeRunFinished(printOutput: final text?):
      case BridgeRunError(printOutput: final text?):
        printOutput = text;
      default:
    }
  });
  try {
    final value = await handle.result;
    await events.asFuture<void>();

    return jsonEncode({
      'ok': true,
      'value': value.dartValue,
      'print_output': printOutput,
    });
  } on MontyError catch (e) {
    await events.asFuture<void>();

    return jsonEncode({
      'ok': false,
      'error': '${e.exception.excType}: ${e.exception.message ?? ''}',
      'excType': e.exception.excType,
      'print_output': printOutput,
    });
  } catch (e) {
    await events.cancel();

    return jsonEncode({'ok': false, 'error': e.toString()});
  }
}

/// Run Python code and return stream of BridgeEvents as JSON.
Future<String> _apiExecute(String code) async {
  try {
    final events = <Map<String, dynamic>>[];
    await for (final event in _session.execute(code).events) {
      final map = _eventToJson(event);
      if (map != null) {
        events.add(map);
        // Notify HTML of tool calls in real-time
        if (event is BridgeFunctionCallStart ||
            event is BridgeFunctionCallResult) {
          try {
            _jsOnToolCall(jsonEncode(map).toJS);
          } on Object catch (_) {}
        }
      }
    }

    // Extract final result from events
    for (final event in events.reversed) {
      if (event['type'] == 'run_finished') {
        return jsonEncode({
          'ok': true,
          'value': event['value'],
          'print_output': event['print_output'],
          'events': events,
        });
      }
      if (event['type'] == 'run_error') {
        return jsonEncode({
          'ok': false,
          'error': event['message'],
          'events': events,
        });
      }
    }

    return jsonEncode({'ok': true, 'value': null, 'events': events});
  } catch (e) {
    return jsonEncode({'ok': false, 'error': e.toString()});
  }
}

/// Reset the session: clears every Python global and re-attaches the
/// extensions on the next run.
Future<String> _apiReset() async {
  try {
    await _session.clearState();

    return jsonEncode({'ok': true});
  } catch (e) {
    return jsonEncode({'ok': false, 'error': e.toString()});
  }
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

Map<String, dynamic>? _eventToJson(BridgeEvent event) {
  if (event is BridgeRunStarted) {
    return {'type': 'run_started'};
  }
  if (event is BridgeRunFinished) {
    return {
      'type': 'run_finished',
      'value': event.value,
      'print_output': event.printOutput,
    };
  }
  if (event is BridgeRunError) {
    return {
      'type': 'run_error',
      'message': event.message,
      'print_output': event.printOutput,
    };
  }
  if (event is BridgeFunctionCallStart) {
    return {'type': 'tool_call_start', 'function': event.name};
  }
  if (event is BridgeFunctionCallResult) {
    return {
      'type': 'tool_call_result',
      'callId': event.callId,
      'result': event.result.length > 80
          ? '${event.result.substring(0, 80)}...'
          : event.result,
    };
  }

  return null;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

Future<void> main() async {
  print('[ReplSessionDemo] Starting...');

  try {
    _session = await _newSession();
  } on Object catch (e) {
    montyDemoFailed('repl_demo', 'could not start the runtime: $e');

    return;
  }

  // Expose API to window
  final api = <String, JSFunction>{
    'run': ((JSString code) => _apiRun(
          code.toDart,
        ).then((r) => r.toJS).toJS).toJS,
    'execute': ((JSString code) => _apiExecute(
          code.toDart,
        ).then((r) => r.toJS).toJS).toJS,
    'reset': (() => _apiReset().then((r) => r.toJS).toJS).toJS,
  }.jsify();
  _replSessionDemo = api as JSObject;

  print('[ReplSessionDemo] API exposed on window.ReplSessionDemo');

  // Signal ready
  try {
    _jsOnReady();
  } catch (_) {
    print('[ReplSessionDemo] Ready (no _onReady callback)');
  }

  // The boot signal is raised behind ONE real evaluation, so the gate's
  // green means Python evaluated, not merely that main() returned. It is
  // unawaited and touches no DOM, so the page behaves the same for a human.
  unawaited(_signalBootReady());
}

/// Runs one Python expression so the boot signal means the engine works.
Future<void> _signalBootReady() async {
  try {
    final value = (await _session.execute('2 + 2').result).dartValue;
    if (value == 4) {
      montyDemoReady('repl_demo');
    } else {
      montyDemoFailed('repl_demo', 'boot probe 2 + 2 evaluated to $value');
    }
  } on Object catch (e) {
    montyDemoFailed('repl_demo', 'boot probe threw: $e');
  }
}
