// Standalone JS-compiled demo, not a package:test file.
// ignore_for_file: avoid_print, lines_longer_than_80_chars, avoid_catches_without_on_clauses, cast_nullable_to_non_nullable, invalid_null_aware_operator
// ignore_for_file: prefer-async-await
// .then-chains in the JSFunction map below are the established JS-interop
// idiom across web demos (cf. agent_demo.dart). Rewriting to async/await
// would diverge from the project pattern.
/// Interactive REPL Session Demo — MontyRuntime + real plugins in the browser.
///
/// Compiled to JS, exposes window.ReplSessionDemo to HTML.
/// All host function dispatch (template, message bus) runs in
/// compiled Dart — no JS host functions needed.
///
/// Build:
///   dart compile js example/web/bin/repl_demo.dart \
///     -o example/web/web/repl_demo.dart.js
library;

import 'dart:convert';
import 'dart:js_interop';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';

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

MontyRuntime _session = _newSession();

MontyRuntime _newSession() => MontyRuntime(
      extensions: [JinjaTemplateExtension(), MessageBusExtension()],
    );

// ---------------------------------------------------------------------------
// API
// ---------------------------------------------------------------------------

/// Run Python code and return JSON result.
Future<String> _apiRun(String code) async {
  try {
    final result = await _session.execute(code).result;

    return jsonEncode(_resultToJson(result));
  } catch (e) {
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

/// Reset the session (dispose + recreate).
Future<String> _apiReset() async {
  try {
    await _session.dispose();
    _createSession();

    return jsonEncode({'ok': true});
  } catch (e) {
    return jsonEncode({'ok': false, 'error': e.toString()});
  }
}

// ---------------------------------------------------------------------------
// Session factory
// ---------------------------------------------------------------------------

// SandboxExtension is FFI-only and cannot be used in a web build.
void _createSession() {
  _session = _newSession();
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

Map<String, dynamic> _resultToJson(MontyResult result) {
  if (!result.ok) {
    return {
      'ok': false,
      'error': result.error?.message ?? 'Unknown error',
      'excType': result.excType,
      'print_output': result.printOutput,
    };
  }

  return {
    'ok': true,
    'value': result.value?.dartValue,
    'print_output': result.printOutput,
  };
}

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
    return {
      'type': 'tool_call_start',
      'function': event.name,
    };
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

void main() {
  print('[ReplSessionDemo] Starting...');

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
}
