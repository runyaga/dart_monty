import 'dart:async';

import 'package:dart_monty_bridge/dart_monty_bridge.dart';
import 'package:dart_monty_mcp/src/bridge_adapter.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:mcp_dart/mcp_dart.dart';

/// A persistent Python interpreter session for MCP.
///
/// Wraps a [MontyPlatform] in a [MontySession] to persist Python globals
/// across calls. Serializes concurrent requests with a simple lock so two
/// MCP tool calls to the same session don't corrupt state (blocker B3).
///
/// Registered [HostFunction]s are callable from Python code via the
/// `MontySession.start()` dispatch loop.
class McpMontySession {
  /// Creates a [McpMontySession].
  McpMontySession({
    required this.id,
    required MontyPlatform platform,
  })  : _platform = platform,
        _session = MontySession(platform: platform);

  /// Session identifier.
  final String id;

  final MontyPlatform _platform;
  final MontySession _session;
  final Map<String, HostFunction> _hostFunctions = {};
  Completer<void>? _lock;
  bool _disposed = false;

  /// Whether this session has been disposed.
  bool get isDisposed => _disposed;

  /// Registers a [HostFunction] callable from Python in this session.
  void register(HostFunction function) {
    _hostFunctions[function.schema.name] = function;
  }

  /// Executes [code] in this session, serializing concurrent requests.
  ///
  /// Variables and imports defined in previous calls persist via
  /// [MontySession]'s state restore/persist mechanism.
  ///
  /// If host functions are registered, uses [MontySession.start()] with a
  /// dispatch loop. Otherwise falls back to [MontySession.run()] for
  /// simpler execution.
  ///
  /// If another execution is in flight, waits for it to complete before
  /// starting.
  Future<CallToolResult> execute(String code) async {
    if (_disposed) {
      return CallToolResult(
        isError: true,
        content: [TextContent(text: 'Session "$id" is disposed')],
      );
    }

    // Wait for any in-flight request (B3 concurrency guard).
    while (_lock != null) {
      await _lock!.future;
    }

    _lock = Completer<void>();
    try {
      if (_hostFunctions.isEmpty) {
        final result = await _session.run(code);
        return montyResultToCallToolResult(result);
      }
      return await _executeWithHostFunctions(code);
    } finally {
      final lock = _lock!;
      _lock = null;
      lock.complete();
    }
  }

  /// Dispatch loop: uses [MontySession.start()] to handle host function
  /// calls from Python code.
  Future<CallToolResult> _executeWithHostFunctions(String code) async {
    final extFnNames = _hostFunctions.keys.toList();
    var progress = await _session.start(
      code,
      externalFunctions: extFnNames,
    );

    while (true) {
      switch (progress) {
        case MontyComplete(:final result):
          return montyResultToCallToolResult(result);

        case MontyPending():
          final fn = _hostFunctions[progress.functionName];
          if (fn == null) {
            progress = await _session.resumeWithError(
              'Unknown host function: ${progress.functionName}',
            );
            continue;
          }
          try {
            final args = fn.schema.mapAndValidate(progress);
            final result = await fn.handler(args);
            progress = await _session.resume(result);
          } catch (e) {
            progress = await _session.resumeWithError(e.toString());
          }

        case MontyResolveFutures():
          // No async dispatch yet — resume with null.
          progress = await _session.resume(null);
      }
    }
  }

  /// Releases platform and session resources.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _session.dispose();
    await _platform.dispose();
  }
}
