// Standalone JS-compiled demo, not a package:test file.
// ignore_for_file: avoid_print, use_null_aware_elements
/// Interactive MontyRuntime Demo — shows stateful Python execution with host
/// functions, filesystem access, and real-time bridge event streaming.
///
/// Compiled to JS, exposes functions to the HTML UI via window.AgentDemo.
///
/// Build:
///   dart compile js example/web/bin/agent_demo.dart \
///     -o example/web/web/agent_demo.dart.js
library;

import 'dart:convert';
import 'dart:js_interop';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:file/memory.dart';

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

MontyRuntime? _session;
bool _initialized = false;

// ---------------------------------------------------------------------------
// Host functions — demo tools callable from Python
// ---------------------------------------------------------------------------

final _demoHostFunctions = <HostFunction>[
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
    handler: (args) async {
      final msg = args['msg']! as String;
      return msg.toUpperCase();
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
    handler: (args) async {
      final a = args['a']! as num;
      final b = args['b']! as num;
      return a + b;
    },
  ),
  HostFunction(
    schema: const HostFunctionSchema(
      name: 'get_time',
      description: 'Returns the current time as an ISO 8601 string.',
    ),
    handler: (_) async {
      return DateTime.now().toIso8601String();
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
    handler: (args) async {
      _kvStore[args['key']! as String] = args['value'];
      return null;
    },
  ),
  HostFunction(
    schema: const HostFunctionSchema(
      name: 'kv_get',
      description: 'Retrieve a value from the key-value store.',
      params: [
        HostParam(name: 'key', type: HostParamType.string),
      ],
    ),
    handler: (args) async {
      return _kvStore[args['key']! as String];
    },
  ),
  HostFunction(
    schema: const HostFunctionSchema(
      name: 'kv_list',
      description: 'List all keys in the key-value store.',
    ),
    handler: (_) async {
      return _kvStore.keys.toList();
    },
  ),

  // Simulated HTTP fetch
  HostFunction(
    schema: const HostFunctionSchema(
      name: 'fetch_json',
      description: 'Fetch JSON data from a URL (simulated).',
      params: [
        HostParam(name: 'url', type: HostParamType.string),
      ],
    ),
    handler: (args) async {
      final url = args['url']! as String;
      // Simulated API responses
      if (url.contains('users')) {
        return [
          {'name': 'Alice', 'age': 30, 'role': 'engineer'},
          {'name': 'Bob', 'age': 25, 'role': 'designer'},
          {'name': 'Charlie', 'age': 35, 'role': 'manager'},
        ];
      }
      if (url.contains('weather')) {
        return {'city': 'San Francisco', 'temp': 68, 'condition': 'sunny'};
      }
      return {'error': 'Unknown endpoint', 'url': url};
    },
  ),

  // Log output
  HostFunction(
    schema: const HostFunctionSchema(
      name: 'log',
      description: 'Log a message to the events panel.',
      params: [
        HostParam(name: 'msg', type: HostParamType.string),
      ],
    ),
    handler: (args) async {
      // The event will be visible in the bridge events panel
      return null;
    },
  ),
];

final _kvStore = <String, Object?>{};

/// Shared bus — accessible to Python via MessageBusPlugin and to Dart directly.
MessageBus? _msgBus;

// ---------------------------------------------------------------------------
// Initialization
// ---------------------------------------------------------------------------

Future<bool> _init() async {
  if (_initialized) return true;

  try {
    final os = composeOsHandlers({
      'Path.': fsHandler(MemoryFileSystem()),
      'date.': timeHandler(),
      'datetime.': timeHandler(),
    });

    final tmplPlugin = JinjaTemplatePlugin();
    final msgPlugin = MessageBusPlugin();
    _msgBus = msgPlugin.bus;

    final plugins = <MontyPlugin>[tmplPlugin, msgPlugin];
    final sandboxPlugin = SandboxPlugin(
      platformFactory: () async => ReplPlatform(repl: MontyRepl()),
    );
    plugins.add(sandboxPlugin);

    _session = MontyRuntime(os: os, plugins: plugins);

    _demoHostFunctions.forEach(_session!.register);

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
    final eventStream = _session!.execute(code).events;
    Object? resultValue;
    String? resultError;
    String? printOutput;

    await for (final event in eventStream) {
      final eventMap = _eventToMap(event);
      events.add(eventMap);

      // Notify HTML UI in real-time.
      try {
        _jsOnEvent(jsonEncode(eventMap).toJS);
      } on Object catch (_) {
        // _onEvent not defined — OK in headless mode.
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

    return jsonEncode({
      'ok': resultError == null,
      if (resultValue != null) 'value': resultValue,
      if (resultError != null) 'error': resultError,
      if (printOutput != null) 'printOutput': printOutput,
      'events': events,
    });
  } on Object catch (e) {
    return jsonEncode({
      'ok': false,
      'error': e.toString(),
      'events': events,
    });
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
    BridgeStepStarted(:final stepId) => {
      'type': 'StepStarted',
      'stepId': stepId,
    },
    BridgeStepFinished(:final stepId) => {
      'type': 'StepFinished',
      'stepId': stepId,
    },
    BridgeToolCallStart(:final callId, :final name) => {
      'type': 'ToolCallStart',
      'callId': callId,
      'name': name,
    },
    BridgeToolCallArgs(:final callId, :final delta) => {
      'type': 'ToolCallArgs',
      'callId': callId,
      'delta': delta,
    },
    BridgeToolCallEnd(:final callId) => {
      'type': 'ToolCallEnd',
      'callId': callId,
    },
    BridgeToolCallResult(:final callId, :final result) => {
      'type': 'ToolCallResult',
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
  };
}

// ---------------------------------------------------------------------------
// State & schemas accessors
// ---------------------------------------------------------------------------

String _getState() {
  if (_session == null) return '{}';
  return jsonEncode(_session!.state);
}

String _getSchemas() {
  if (_session == null) return '[]';
  final schemas = _session!.schemas
      .where(
        (s) => s.name != '__restore_state__' && s.name != '__persist_state__',
      )
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
  _session?.clearState();
}

Future<void> _dispose() async {
  await _session?.dispose();
  _session = null;
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
    // Dart-side MessageBus access — push data to any channel from JS.
    // Python code calling msg_recv() on the same channel will unblock
    // immediately when Dart pushes, because they share the same MessageBus.
    'dartPush': ((JSString channel, JSString messageJson) {
      try {
        final msg = jsonDecode(messageJson.toDart);
        _msgBus?.send(channel.toDart, msg);
        return true.toJS;
      } on Object catch (e) {
        print('dartPush error: $e');
        return false.toJS;
      }
    }).toJS,
    // Returns current ChannelSnapshot as JSON for the given channel.
    'dartChannelStats': ((JSString channel) {
      final ch = _msgBus?.channelOrNull(channel.toDart);
      if (ch == null) return 'null'.toJS;
      final s = ch.snapshot;
      return jsonEncode({
        'isClosed': s.isClosed,
        'queueDepth': s.queueDepth,
        'sendCount': s.sendCount,
        'recvCount': s.recvCount,
        'peakQueueDepth': s.peakQueueDepth,
      }).toJS;
    }).toJS,
  }.jsify();
  // jsify() returns JSObject? but we know our non-empty map produces one.
  _agentDemo = api! as JSObject;

  // Auto-initialize session.
  final ok = await _init();
  if (!ok) {
    print('AGENT_DEMO_ERROR: init failed');
    return;
  }

  print('AgentDemo ready');
  try {
    _jsOnReady();
  } on Object catch (_) {
    // _onReady not defined — OK in headless mode.
  }
}
