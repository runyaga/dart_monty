import 'dart:async';

import 'package:dart_monty/src/bridge/bridge/bridge_event.dart';
import 'package:dart_monty/src/bridge/bridge/default_monty_bridge.dart';
import 'package:dart_monty/src/bridge/bridge/host_function.dart';
import 'package:dart_monty/src/bridge/bridge/host_function_schema.dart';
import 'package:dart_monty/src/bridge/bridge/host_param.dart';
import 'package:dart_monty/src/bridge/bridge/host_param_type.dart';
import 'package:dart_monty/src/bridge/bridge/monty_bridge.dart';
import 'package:dart_monty/src/bridge/bridge/monty_plugin.dart';
import 'package:dart_monty/src/bridge/bridge/plugin_registry.dart';
import 'package:dart_monty/src/bridge/os_call/os_provider.dart';
import 'package:dart_monty/src/monty.dart';
import 'package:dart_monty/src/platform/bridge_logger.dart';
import 'package:dart_monty/src/platform/code_capture.dart' as code_capture;
import 'package:dart_monty/src/platform/monty_exception.dart';
import 'package:dart_monty/src/platform/monty_resource_usage.dart';
import 'package:dart_monty/src/platform/monty_result.dart';
import 'package:dart_monty/src/platform/monty_value.dart';

const _restoreFn = '__restore_state__';
const _persistFn = '__persist_state__';

/// High-level agent session — stateful Python execution with tools and plugins.
///
/// Combines `MontyBridge`, `PluginRegistry`, OS providers, and variable
/// persistence into a single API. Variables persist across `execute()` calls.
/// All registered plugins and host functions are available to Python code.
///
/// ```dart
/// final session = AgentSession(
///   os: OsProvider(),
///   plugins: [SandboxPlugin(), MessageBusPlugin()],
/// );
///
/// await session.execute('x = 42');
/// final result = await session.execute('x + 1');
/// print(result.value); // 43
///
/// // Tool schemas for LLM integration
/// final tools = session.schemas;
///
/// await session.dispose();
/// ```
class AgentSession {
  /// Creates an agent session with optional OS provider, plugins, limits,
  /// and logger.
  AgentSession({
    OsProvider? os,
    List<MontyPlugin>? plugins,
    BridgeLogger? logger,
  }) : _monty = Monty(os: os) {
    _bridge = DefaultMontyBridge(
      platform: _monty.platform,
      useFutures: false,
      logger: logger,
    );

    if (os != null) _bridge.registerOs(os);

    _registerStateHostFunctions();

    if (plugins != null && plugins.isNotEmpty) {
      _registry = PluginRegistry();
      plugins.forEach(_registry!.register);
    }
  }

  static const _zeroUsage = MontyResourceUsage(
    memoryBytesUsed: 0,
    timeElapsedMs: 0,
    stackDepthUsed: 0,
  );

  final Monty _monty;
  late final DefaultMontyBridge _bridge;
  PluginRegistry? _registry;
  bool _attached = false;
  bool _disposed = false;
  Map<String, Object?> _sessionState = {};

  /// All registered tool schemas — feed these to an LLM as tool definitions.
  List<HostFunctionSchema> get schemas => _bridge.schemas;

  /// The underlying bridge — for advanced use (middleware, direct execute).
  MontyBridge get bridge => _bridge;

  /// The current persisted Python state.
  Map<String, Object?> get state => Map.from(_sessionState);

  /// Registers an additional host function.
  void register(HostFunction function) {
    _checkNotDisposed();
    _bridge.register(function);
  }

  /// Executes Python [code] with state persistence and full tool access.
  ///
  /// Variables defined in [code] persist for subsequent `execute()` calls.
  /// All registered host functions and plugins are callable from Python.
  ///
  /// Returns the [MontyResult] from execution.
  Future<MontyResult> execute(String code) async {
    _checkNotDisposed();
    await _ensureAttached();

    final wrappedCode = _wrapWithState(code);
    final events = await _bridge.execute(wrappedCode).toList();

    return _extractResult(events);
  }

  /// Executes [code] and returns the stream of bridge events.
  ///
  /// Use this when you need real-time event streaming (tool calls, text
  /// output, lifecycle events) rather than just the final result.
  Stream<BridgeEvent> executeStream(String code) {
    _checkNotDisposed();
    // Can't await _ensureAttached in a sync method that returns Stream.
    // Caller must ensure plugins are attached before first use.
    final wrappedCode = _wrapWithState(code);

    return _bridge.execute(wrappedCode);
  }

  /// Clears all persisted Python state.
  void clearState() {
    _checkNotDisposed();
    _sessionState = {};
  }

  /// Releases all resources.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _bridge.dispose();
    await _monty.dispose();
  }

  // ---------------------------------------------------------------------------
  // State host functions
  // ---------------------------------------------------------------------------

  void _registerStateHostFunctions() {
    _bridge
      ..register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: _restoreFn,
            description: 'Internal: restore session state',
          ),
          handler: (_) async => _sessionState,
        ),
      )
      ..register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: _persistFn,
            description: 'Internal: persist session state',
            params: [HostParam(name: 'state', type: HostParamType.any)],
          ),
          handler: (args) async {
            final captured = args['state'];
            if (captured is Map<String, Object?>) {
              _sessionState = captured;
            }

            return null;
          },
        ),
      );
  }

  // ---------------------------------------------------------------------------
  // Code wrapping (state persistence)
  // ---------------------------------------------------------------------------

  String _wrapWithState(String userCode) {
    final restore = _generateRestore();
    final persist = _generatePersist(userCode);
    final (processed, hasResult) =
        code_capture.captureLastExpression(userCode);

    final buf = StringBuffer(restore)
      ..write('\n')
      ..write(processed)
      ..write('\n')
      ..write(persist);

    if (hasResult) {
      buf.write('\n__r');
    }

    return buf.toString();
  }

  String _generateRestore() {
    final buf = StringBuffer('__d = $_restoreFn()');
    for (final key in _sessionState.keys) {
      buf.write('\n$key = __d["$key"]');
    }

    return buf.toString();
  }

  String _generatePersist(String userCode) {
    final names = <String>{
      ..._sessionState.keys,
      ...code_capture.extractAssignmentTargets(userCode),
    };

    if (names.isEmpty) {
      return '$_persistFn({})';
    }

    final buf = StringBuffer('__d2 = {}');
    for (final name in names) {
      buf
        ..write('\ntry:')
        ..write('\n    __d2["$name"] = $name')
        ..write('\nexcept Exception:')
        ..write('\n    pass');
    }
    buf.write('\n$_persistFn(__d2)');

    return buf.toString();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Future<void> _ensureAttached() async {
    if (!_attached && _registry != null) {
      await _registry!.attachTo(_bridge);
      _attached = true;
    }
  }

  MontyResult _extractResult(List<BridgeEvent> events) {
    for (final event in events.reversed) {
      if (event is BridgeRunFinished) {
        final value = event.value != null
            ? MontyValue.fromDart(event.value)
            : null;

        return MontyResult(
          value: value,
          usage: _zeroUsage,
          printOutput: event.printOutput,
        );
      }
      if (event is BridgeRunError) {
        return MontyResult(
          error: event.exception ?? MontyException(message: event.message),
          usage: _zeroUsage,
          printOutput: event.printOutput,
        );
      }
    }

    // Should not happen — bridge always emits a terminal event.
    throw StateError('No terminal event in bridge execution');
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('AgentSession has been disposed');
    }
  }
}
