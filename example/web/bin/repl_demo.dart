// Standalone JS-compiled demo, not a package:test file.
// ignore_for_file: avoid_print, lines_longer_than_80_chars, avoid_catches_without_on_clauses, cast_nullable_to_non_nullable
/// Interactive REPL Session Demo — ReplSession + real plugins in the browser.
///
/// Compiled to JS, exposes window.ReplSessionDemo to HTML.
/// All host function dispatch (template, message bus, sandbox) runs in
/// compiled Dart — no JS host functions needed.
///
/// Build:
///   dart compile js test/wasm/integration/repl_session_demo.dart \
///     -o test/wasm/integration/web/repl_session_demo.dart.js
library;

import 'dart:convert';
import 'dart:js_interop';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty/src/wasm/monty_wasm.dart';

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

late ReplSession _session;

// ---------------------------------------------------------------------------
// API
// ---------------------------------------------------------------------------

/// Run Python code and return JSON result.
Future<String> _apiRun(String code) async {
  try {
    final result = await _session.run(code);
    return jsonEncode(_resultToJson(result));
  } catch (e) {
    return jsonEncode({'ok': false, 'error': e.toString()});
  }
}

/// Run Python code and return stream of BridgeEvents as JSON.
Future<String> _apiExecute(String code) async {
  try {
    final events = <Map<String, dynamic>>[];
    await for (final event in _session.execute(code)) {
      final map = _eventToJson(event);
      if (map != null) {
        events.add(map);
        // Notify HTML of tool calls in real-time
        if (event is BridgeToolCallStart || event is BridgeToolCallResult) {
          try {
            _jsOnToolCall(jsonEncode(map).toJS);
          } catch (_) {}
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

void _createSession() {
  final tmpl = JinjaTemplatePlugin();
  final msgBus = MessageBusPlugin();
  final sandbox = SandboxPlugin(
    platformFactory: () async => MontyWasm(),
    maxChildren: 8,
    maxDepth: 2,
  );

  _session = ReplSession(
    plugins: [tmpl, msgBus, sandbox],
  );
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

Map<String, dynamic> _resultToJson(MontyResult result) {
  if (result.isError) {
    return {
      'ok': false,
      'error': result.error?.message ?? 'Unknown error',
      'excType': result.error?.excType,
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
  if (event is BridgeToolCallStart) {
    return {
      'type': 'tool_call_start',
      'function': event.name,
    };
  }
  if (event is BridgeToolCallResult) {
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

  _createSession();

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
