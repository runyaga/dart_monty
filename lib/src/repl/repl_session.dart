import 'dart:async';

import 'package:dart_monty/src/bridge/bridge/bridge_event.dart';
import 'package:dart_monty/src/bridge/bridge/default_monty_bridge.dart';
import 'package:dart_monty/src/bridge/bridge/host_function.dart';
import 'package:dart_monty/src/bridge/bridge/monty_plugin.dart';
import 'package:dart_monty/src/bridge/bridge/plugin_registry.dart';
import 'package:dart_monty/src/bridge/os_call/os_provider.dart';
import 'package:dart_monty/src/platform/monty_exception.dart';
import 'package:dart_monty/src/platform/monty_resource_usage.dart';
import 'package:dart_monty/src/platform/monty_result.dart';
import 'package:dart_monty/src/platform/monty_value.dart';
import 'package:dart_monty/src/repl/monty_repl.dart';
import 'package:dart_monty/src/repl/repl_platform.dart';

/// A stateful REPL session with full plugin dispatch.
///
/// Combines [MontyRepl] (native heap persistence) with
/// [DefaultMontyBridge] (plugin dispatch, middleware, event streaming).
/// State (variables, functions, classes, closures) persists natively
/// across [execute] calls — no JSON serialization required.
///
/// ```dart
/// final session = ReplSession(
///   plugins: [DinjaTemplatePlugin()],
/// );
/// final result = await session.run(
///   "tmpl_render(template='{{ x }}', context={'x': 42})",
/// );
/// print(result.value); // '42'
/// await session.dispose();
/// ```
class ReplSession {
  /// Creates a [ReplSession] with optional [plugins] and [os] provider.
  ReplSession({
    List<MontyPlugin>? plugins,
    OsProvider? os,
    String? scriptName,
  }) : _plugins = plugins,
       _os = os,
       _repl = MontyRepl(scriptName: scriptName);

  final List<MontyPlugin>? _plugins;
  final OsProvider? _os;
  final MontyRepl _repl;

  DefaultMontyBridge? _bridge;
  bool _attached = false;
  bool _disposed = false;

  /// Executes [code] with full plugin dispatch, returning a stream
  /// of [BridgeEvent]s for real-time visibility into tool calls.
  ///
  /// State persists across calls. Each call reuses the same REPL
  /// heap and bridge — plugins remain registered.
  Stream<BridgeEvent> execute(String code) {
    _checkNotDisposed();
    _ensureBridge();

    // Wrap in async* to allow awaiting plugin attachment on first call.
    return _executeWithPlugins(code);
  }

  Stream<BridgeEvent> _executeWithPlugins(String code) async* {
    await _ensurePluginsAttached();
    yield* _bridge!.execute(code);
  }

  /// Convenience: executes [code] and awaits the final result.
  ///
  /// Collects all [BridgeEvent]s internally and extracts the result
  /// from the terminal event.
  Future<MontyResult> run(String code) async {
    final events = await execute(code).toList();

    return _extractResult(events);
  }

  /// Registers an additional [HostFunction] on the bridge.
  ///
  /// Must be called before [execute] / [run], or between calls.
  void register(HostFunction function) {
    _checkNotDisposed();
    _ensureBridge();
    _bridge!.register(function);
  }

  /// Disposes the session, bridge, and REPL.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _bridge?.dispose();
    await _repl.dispose();
  }

  // -----------------------------------------------------------------------
  // Private
  // -----------------------------------------------------------------------

  static const _zeroUsage = MontyResourceUsage(
    memoryBytesUsed: 0,
    timeElapsedMs: 0,
    stackDepthUsed: 0,
  );

  void _ensureBridge() {
    if (_bridge != null) return;

    final platform = ReplPlatform(repl: _repl);
    _bridge = DefaultMontyBridge(
      platform: platform,
      useFutures: false,
    );

    if (_os != null) _bridge!.registerOs(_os);

    // Plugin attachment is deferred to first execute — plugins may
    // need async setup via onRegister().
  }

  Future<void> _ensurePluginsAttached() async {
    if (_attached) return;
    _attached = true;

    final plugins = _plugins;
    if (plugins != null && plugins.isNotEmpty) {
      final registry = PluginRegistry();
      plugins.forEach(registry.register);
      await registry.attachTo(_bridge!);

      // Inject help() with registered function descriptions.
      await _injectHelp(plugins);
    }
  }

  Future<void> _injectHelp(List<MontyPlugin> plugins) async {
    final entries = <String>[];
    for (final plugin in plugins) {
      for (final fn in plugin.functions) {
        final name = fn.schema.name;
        final desc = fn.schema.description;
        final short = desc.length > 60 ? '${desc.substring(0, 57)}...' : desc;
        entries.add('    "$name": "$short"');
      }
    }
    final registryCode = '_help_registry = {\n${entries.join(",\n")}\n}';
    try {
      await _repl.feed(registryCode);
      await _repl.feed(
        'def help(name=None):\n'
        '    if name is None:\n'
        '        print("Host functions:")\n'
        '        for fn, desc in _help_registry.items():\n'
        '            print(f"  {fn}() - {desc}")\n'
        '    else:\n'
        '        if name in _help_registry:\n'
        '            print(f"{name}() - {_help_registry[name]}")\n'
        '        else:\n'
        '            print(f"Unknown: {name}")',
      );
    } on Object {
      // Non-fatal — help() is a convenience, not critical.
    }
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('ReplSession has been disposed.');
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

    throw StateError('No terminal event in bridge execution');
  }
}
