// ignore_for_file: avoid_print
library;

import 'dart:convert';
import 'dart:js_interop';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:signals_core/signals_core.dart';

// ---------------------------------------------------------------------------
// JS interop — expose API to HTML
// ---------------------------------------------------------------------------

@JS('window.SignalsDemo')
external set _signalsDemo(JSObject obj);

@JS('window._onStateSignal')
external void _jsOnStateSignal(JSString state);

@JS('window._onSessionStateSignal')
external void _jsOnSessionStateSignal(JSString jsonState);

@JS('window._onChannelStateSignal')
external void _jsOnChannelStateSignal(JSString state);

@JS('window._onLastEmittedSignal')
external void _jsOnLastEmittedSignal(JSString jsonValue);

@JS('window._onReady')
external void _jsOnReady();

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

AgentSession? _session;
bool _initialized = false;
final _disposers = <void Function()>[];

// ---------------------------------------------------------------------------
// Initialization
// ---------------------------------------------------------------------------

Future<bool> _init() async {
  if (_initialized) return true;

  try {
    final os = OsProvider.compose({
      'Path.': MemoryFsProvider(),
      'date.': TimeOsProvider(),
      'datetime.': TimeOsProvider(),
    });

    final eventLoop = EventLoopPlugin();
    final plugins = <MontyPlugin>[eventLoop, MessageBusPlugin(), SandboxPlugin(platformFactory: () async => Monty(os: os).platform)];

    _session = AgentSession(os: os, plugins: plugins);

    // Subscribe to signals and notify JS
    _disposers.add(effect(() {
      final state = _session!.stateSignal.value;
      _jsOnStateSignal(state.name.toJS);
    }));

    _disposers.add(effect(() {
      final state = _session!.sessionStateSignal.value;
      _jsOnSessionStateSignal(jsonEncode(state).toJS);
    }));

    _disposers.add(effect(() {
      final state = eventLoop.channelStateSignal.value;
      _jsOnChannelStateSignal(_channelStateToString(state).toJS);
    }));

    _disposers.add(effect(() {
      final value = eventLoop.lastEmittedSignal.value;
      _jsOnLastEmittedSignal(jsonEncode(value ?? {}).toJS);
    }));

    _initialized = true;
    return true;
  } on Object catch (e) {
    print('SignalsDemo init error: $e');
    return false;
  }
}

String _channelStateToString(BridgeChannelState state) {
  return switch (state) {
    BridgeChannelIdle() => 'idle',
    BridgeChannelExecuting() => 'executing',
    BridgeChannelWaiting() => 'waiting',
    BridgeChannelCompleted() => 'completed',
    BridgeChannelDisposed() => 'disposed',
  };
}

// ---------------------------------------------------------------------------
// Execute Python code
// ---------------------------------------------------------------------------

Future<String> _execute(String code) async {
  if (_session == null) {
    return jsonEncode({'ok': false, 'error': 'Session not initialized'});
  }

  try {
    final result = await _session!.execute(code);
    return jsonEncode({
      'ok': true,
      'value': result.value,
      'printOutput': result.printOutput,
    });
  } on Object catch (e) {
    return jsonEncode({
      'ok': false,
      'error': e.toString(),
    });
  }
}

Future<void> _dispose() async {
  for (final dispose in _disposers) {
    dispose();
  }
  _disposers.clear();
  await _session?.dispose();
  _session = null;
  _initialized = false;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

Future<void> main() async {
  final Map<String, JSFunction> apiMap = {
    'init': (() => _init().then((ok) => ok.toJS).toJS).toJS,
    'execute': ((JSString code) => _execute(code.toDart).then((r) => r.toJS).toJS).toJS,
    'dispose': (() => _dispose().then((_) => null).toJS).toJS,
    'reset': (() {
      final s = _session;
      if (s != null) s.clearState();
      return null.toJS;
    }).toJS,
  };
  final jsApi = apiMap.jsify();
  if (jsApi != null) {
    _signalsDemo = jsApi as JSObject;
  }

  final ok = await _init();
  if (ok) {
    print('SignalsDemo ready');
    try {
      _jsOnReady();
    } on Object catch (_) {}
  }
}
