import 'dart:async';

import 'package:dart_monty_bridge/dart_monty_bridge.dart';
import 'package:dart_monty_mcp/src/bridge_adapter.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:mcp_dart/mcp_dart.dart';

/// A persistent Python interpreter session for MCP.
///
/// Wraps a [MontyPlatform] and [DefaultMontyBridge] pair. Serializes
/// concurrent requests with a simple lock so two MCP tool calls to
/// the same session don't corrupt Python globals (blocker B3).
class McpMontySession {
  /// Creates a [McpMontySession].
  McpMontySession({
    required this.id,
    required MontyPlatform platform,
  })  : _platform = platform,
        _bridge = DefaultMontyBridge(platform: platform);

  /// Session identifier.
  final String id;

  final MontyPlatform _platform;
  final DefaultMontyBridge _bridge;
  Completer<void>? _lock;
  bool _disposed = false;

  /// Whether this session has been disposed.
  bool get isDisposed => _disposed;

  /// Registers a host function on this session's bridge.
  void register(HostFunction function) => _bridge.register(function);

  /// Executes [code] in this session, serializing concurrent requests.
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
      final events = _bridge.execute(code);
      return await bridgeEventsToResult(events);
    } finally {
      final lock = _lock!;
      _lock = null;
      lock.complete();
    }
  }

  /// Releases platform and bridge resources.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _bridge.dispose();
    await _platform.dispose();
  }
}
