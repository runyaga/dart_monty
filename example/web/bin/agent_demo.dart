// Standalone JS-compiled demo, not a package:test file.
// ignore_for_file: avoid_print, unnecessary_underscores
// ignore_for_file: use_null_aware_elements, unnecessary_ignore
/// Interactive MontyRuntime Demo — shows stateful Python execution with host
/// functions, filesystem access, and real-time bridge event streaming.
///
/// Compiled to JS, exposes functions to the HTML UI via window.AgentDemo.
///
/// Build:
///   dart compile js example/web/bin/agent_demo.dart \
///     -o example/web/web/agent_demo.dart.js
library;

import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:js_interop';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:web_example/demo_pool.dart';
import 'package:web_example/demo_ready.dart';

// ---------------------------------------------------------------------------
// JS interop — expose API to HTML
// ---------------------------------------------------------------------------

@JS('window.AgentDemo')
external set _agentDemo(JSObject obj);

@JS('window._onEvent')
external void _jsOnEvent(JSString jsonPayload);

@JS('window._onReady')
external void _jsOnReady();

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

Monty? _pool;
MontyRuntime? _session;
bool _initialized = false;
bool _suppressEvents = false;

// ---------------------------------------------------------------------------
// Host functions — demo tools callable from Python
// ---------------------------------------------------------------------------

final _demoHostFunctions = [
  HostFunction(
    schema: const HostFunctionSchema(
      name: 'echo',
      description: 'Returns the message uppercased.',
      params: [
        HostParam(
          name: 'msg',
          type: HostParamType.string,
          description: 'Message to echo back uppercased.',
        ),
      ],
    ),
    handler: (args, _) async {
      final msg = (args['msg']! as MontyString).value;

      return MontyValue.fromDart(msg.toUpperCase());
    },
  ),
  HostFunction(
    schema: const HostFunctionSchema(
      name: 'add_numbers',
      description: 'Returns the sum of two numbers.',
      params: [
        HostParam(
          name: 'a',
          type: HostParamType.number,
          description: 'First number.',
        ),
        HostParam(
          name: 'b',
          type: HostParamType.number,
          description: 'Second number.',
        ),
      ],
    ),
    handler: (args, _) async {
      final a = args['a']!.dartValue! as num;
      final b = args['b']!.dartValue! as num;

      return MontyValue.fromDart(a + b);
    },
  ),
  HostFunction(
    schema: const HostFunctionSchema(
      name: 'get_time',
      description: 'Returns the current time as an ISO 8601 string.',
    ),
    handler: (_, __) async {
      return MontyValue.fromDart(DateTime.now().toIso8601String());
    },
  ),

  // Key-value store — persistent memory across calls
  HostFunction(
    schema: const HostFunctionSchema(
      name: 'kv_set',
      description: 'Store a value in the key-value store.',
      params: [
        HostParam(name: 'key', type: HostParamType.string),
        HostParam(name: 'value', type: HostParamType.any),
      ],
    ),
    handler: (args, _) async {
      _kvStore[(args['key']! as MontyString).value] = args['value'];

      return const MontyNone();
    },
  ),
  HostFunction(
    schema: const HostFunctionSchema(
      name: 'kv_get',
      description: 'Retrieve a value from the key-value store.',
      params: [HostParam(name: 'key', type: HostParamType.string)],
    ),
    handler: (args, _) async {
      return MontyValue.fromDart(_kvStore[(args['key']! as MontyString).value]);
    },
  ),
  HostFunction(
    schema: const HostFunctionSchema(
      name: 'kv_list',
      description: 'List all keys in the key-value store.',
    ),
    handler: (_, __) async {
      return MontyValue.fromDart(_kvStore.keys.toList());
    },
  ),

  // Simulated HTTP fetch
  HostFunction(
    schema: const HostFunctionSchema(
      name: 'fetch_json',
      description: 'Fetch JSON data from a URL (simulated).',
      params: [HostParam(name: 'url', type: HostParamType.string)],
    ),
    handler: (args, _) async {
      final url = (args['url']! as MontyString).value;
      // Simulated API responses
      if (url.contains('users')) {
        return MontyValue.fromDart([
          {'name': 'Alice', 'age': 30, 'role': 'engineer'},
          {'name': 'Bob', 'age': 25, 'role': 'designer'},
          {'name': 'Charlie', 'age': 35, 'role': 'manager'},
        ]);
      }
      if (url.contains('weather')) {
        return MontyValue.fromDart(
          {'city': 'San Francisco', 'temp': 68, 'condition': 'sunny'},
        );
      }

      return MontyValue.fromDart({'error': 'Unknown endpoint', 'url': url});
    },
  ),

  // Log output
  HostFunction(
    schema: const HostFunctionSchema(
      name: 'log',
      description: 'Log a message to the events panel.',
      params: [HostParam(name: 'msg', type: HostParamType.string)],
    ),
    handler: (args, _) async {
      // The event will be visible in the bridge events panel
      return const MontyNone();
    },
  ),
];

final _kvStore = <String, Object?>{};

// ---------------------------------------------------------------------------
// Initialization
// ---------------------------------------------------------------------------

/// The most children the demo's sandbox runs at once.
const _maxChildren = 4;

Future<bool> _init() async {
  if (_initialized) return true;

  try {
    // Room for the held session, a sub-execution and every child.
    final pool = await startDemoPool(maxProcesses: _maxChildren + 2);
    _pool = pool;
    final session = await MontyRuntime.start(
      pool: pool,
      osHandlers: {'Path.': OSAccess().call},
      extensions: [SandboxExtension(maxChildren: _maxChildren)],
    );
    _demoHostFunctions.forEach(session.register);
    _session = session;

    _initialized = true;

    return true;
  } on Object catch (e) {
    print('AgentDemo init error: $e');

    return false;
  }
}

// ---------------------------------------------------------------------------
// Execute Python code with event streaming
// ---------------------------------------------------------------------------

Future<String> _execute(String code) async {
  if (_session == null) {
    return jsonEncode({'ok': false, 'error': 'Session not initialized'});
  }

  final events = <Map<String, dynamic>>[];

  try {
    final handle = _session!.execute(code);
    // Prevent unhandled Future errors — the result future may complete with
    // an error if the bridge encounters an infrastructure fault. We extract
    // results from the event stream instead.
    handle.result.ignore();
    final eventStream = handle.events;
    Object? resultValue;
    String? resultError;
    String? printOutput;

    await for (final event in eventStream) {
      final eventMap = _eventToMap(event);
      events.add(eventMap);

      // Notify HTML UI in real-time.
      if (!_suppressEvents) {
        try {
          _jsOnEvent(jsonEncode(eventMap).toJS);
        } on Object catch (_) {
          // _onEvent not defined — OK in headless mode.
        }
      }

      // Capture terminal events.
      if (event is BridgeRunFinished) {
        resultValue = event.value;
        printOutput = event.printOutput;
      } else if (event is BridgeRunError) {
        resultError = event.message;
        printOutput = event.printOutput;
      }
    }

    if (resultError == null) _learnNames(code);
    await _refreshState();

    return jsonEncode({
      'ok': resultError == null,
      if (resultValue != null) 'value': resultValue,
      if (resultError != null) 'error': resultError,
      if (printOutput != null) 'printOutput': printOutput,
      'events': events,
    });
  } on Object catch (e) {
    return jsonEncode({'ok': false, 'error': e.toString(), 'events': events});
  }
}

Map<String, dynamic> _eventToMap(BridgeEvent event) {
  return switch (event) {
    BridgeRunStarted(:final threadId, :final runId) => {
        'type': 'RunStarted',
        'threadId': threadId,
        'runId': runId,
      },
    BridgeRunFinished(
      :final threadId,
      :final runId,
      :final value,
      :final printOutput,
    ) =>
      {
        'type': 'RunFinished',
        'threadId': threadId,
        'runId': runId,
        if (value != null) 'value': '$value',
        if (printOutput != null) 'printOutput': printOutput,
      },
    BridgeRunError(:final message, :final printOutput) => {
        'type': 'RunError',
        'message': message,
        if (printOutput != null) 'printOutput': printOutput,
      },
    BridgeCallStarted(:final callId) => {
        'type': 'CallStarted',
        'callId': callId,
      },
    BridgeCallFinished(:final callId) => {
        'type': 'CallFinished',
        'callId': callId,
      },
    BridgeFunctionCallStart(:final callId, :final name) => {
        'type': 'FunctionCallStart',
        'callId': callId,
        'name': name,
      },
    BridgeFunctionCallArgs(:final callId, :final delta) => {
        'type': 'FunctionCallArgs',
        'callId': callId,
        'delta': delta,
      },
    BridgeFunctionCallEnd(:final callId) => {
        'type': 'FunctionCallEnd',
        'callId': callId,
      },
    BridgeFunctionCallResult(:final callId, :final result) => {
        'type': 'FunctionCallResult',
        'callId': callId,
        'result': result,
      },
    BridgeOsCallStart(
      :final callId,
      :final operationName,
      :final argumentSummary,
    ) =>
      {
        'type': 'OsCallStart',
        'callId': callId,
        'operationName': operationName,
        if (argumentSummary != null) 'argumentSummary': argumentSummary,
      },
    BridgeOsCallResult(:final callId, :final result, :final durationMs) => {
        'type': 'OsCallResult',
        'callId': callId,
        'result': result,
        if (durationMs != null) 'durationMs': durationMs,
      },
    BridgeFunctionEmit(:final callId, :final text) => {
        'type': 'FunctionEmit',
        'callId': callId,
        'text': text,
      },
    BridgeChildEvent(:final childHandle, :final inner) => {
        'type': 'ChildEvent',
        'childHandle': childHandle,
        'inner': _eventToMap(inner),
      },
  };
}

// ---------------------------------------------------------------------------
// State & schemas accessors
// ---------------------------------------------------------------------------

// Monty's Python doesn't expose globals()/dir()/vars(), so we track names
// assigned at the top level of executed code ourselves and probe their
// current repr() with a per-name try/except dict-build expression.
final _trackedNames = <String>{};
String _stateCache = '{}';

// Top-level `name = expr` lines (no leading whitespace, single LHS, not `==`).
final _assignmentPattern = RegExp(r'^([a-zA-Z_]\w*)\s*=(?!=)', multiLine: true);

void _learnNames(String code) {
  for (final m in _assignmentPattern.allMatches(code)) {
    _trackedNames.add(m.group(1)!);
  }
}

// Returns the cached snapshot synchronously so the State Panel can render
// without awaiting. The cache is refreshed after every [_execute] call and
// after [_clearState].
String _getState() => _stateCache;

Future<void> _refreshState() async {
  if (_session == null || _trackedNames.isEmpty) {
    _stateCache = '{}';

    return;
  }
  final lines = ['_st = {}'];
  for (final name in _trackedNames) {
    lines
      ..add('try: _st[${jsonEncode(name)}] = repr($name)')
      ..add('except: pass');
  }
  lines.add('_st');
  final probe = lines.join('\n');
  _suppressEvents = true;
  try {
    final handle = _session!.execute(probe);
    handle.result.ignore();
    Object? value;
    await for (final ev in handle.events) {
      if (ev is BridgeRunFinished) value = ev.value;
    }
    if (value is Map) {
      // Drop names that no longer resolve so the panel stays accurate.
      _trackedNames.retainAll(value.keys.cast<String>());
      _stateCache = jsonEncode(value);
    } else {
      _stateCache = '{}';
    }
  } on Object catch (_) {
    _stateCache = '{}';
  } finally {
    _suppressEvents = false;
  }
}

String _getSchemas() {
  if (_session == null) return '[]';
  final schemas = _session!.schemas
      .map(
        (s) => {
          'name': s.name,
          'description': s.description,
          'inputSchema': s.toJsonSchema(),
        },
      )
      .toList();

  return jsonEncode(schemas);
}

void _clearState() {
  final session = _session;
  if (session != null) unawaited(session.clearState());
  _trackedNames.clear();
  _stateCache = '{}';
}

Future<void> _dispose() async {
  await _session?.dispose();
  await _pool?.close();
  _session = null;
  _pool = null;
  _initialized = false;
}

// ---------------------------------------------------------------------------
// Main — wire up JS API and initialize
// ---------------------------------------------------------------------------

Future<void> main() async {
  // Expose API to HTML.
  final api = <String, JSFunction>{
    'init': (() => _init().then((ok) => ok.toJS).toJS).toJS,
    'execute': ((JSString code) => _execute(
          code.toDart,
        ).then((r) => r.toJS).toJS).toJS,
    'getState': (() => _getState().toJS).toJS,
    'getSchemas': (() => _getSchemas().toJS).toJS,
    'clearState': _clearState.toJS,
    'dispose': (() => _dispose().then((_) => null).toJS).toJS,
  }.jsify();
  // jsify() returns JSObject? but we know our non-empty map produces one.
  _agentDemo = api! as JSObject;

  // Auto-initialize session.
  final ok = await _init();
  if (!ok) {
    print('AGENT_DEMO_ERROR: init failed');
    montyDemoFailed('agent_demo', 'session init failed');

    return;
  }

  print('AgentDemo ready');
  // The session above already booted the WASM worker, so reaching here means
  // the engine came up — not merely that main() was entered.
  montyDemoReady('agent_demo');
  try {
    _jsOnReady();
  } on Object catch (_) {
    // _onReady not defined — OK in headless mode.
  }
}
