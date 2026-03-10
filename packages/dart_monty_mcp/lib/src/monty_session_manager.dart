import 'package:dart_monty_bridge/dart_monty_bridge.dart';
import 'package:dart_monty_mcp/src/bridge_adapter.dart';
import 'package:dart_monty_mcp/src/monty_session.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:mcp_dart/mcp_dart.dart';

/// Factory that creates a fresh [MontyPlatform] instance.
typedef PlatformFactory = MontyPlatform Function();

/// Manages the lifecycle of [McpMontySession] instances.
///
/// Tracks named sessions, handles creation/destruction, and provides
/// stateless execution (creates a temporary platform per call).
class MontySessionManager {
  /// Creates a [MontySessionManager].
  MontySessionManager({required this.platformFactory});

  /// Factory for creating platform instances.
  final PlatformFactory platformFactory;

  final Map<String, McpMontySession> _sessions = {};
  int _nextId = 0;

  /// IDs of all active sessions.
  List<String> get sessionIds => _sessions.keys.toList(growable: false);

  /// Number of active sessions.
  int get sessionCount => _sessions.length;

  /// Creates a new persistent session.
  ///
  /// If [id] is provided, uses it as the session ID. Otherwise generates
  /// a sequential ID. Returns `null` if [id] already exists.
  String? createSession({String? id}) {
    final sessionId = id ?? 'session_${_nextId++}';
    if (_sessions.containsKey(sessionId)) return null;
    _sessions[sessionId] = McpMontySession(
      id: sessionId,
      platform: platformFactory(),
    );
    return sessionId;
  }

  /// Returns the session with [id], or `null` if not found.
  McpMontySession? getSession(String id) => _sessions[id];

  /// Destroys and disposes the session with [id].
  ///
  /// Returns `true` if the session existed and was destroyed.
  Future<bool> destroySession(String id) async {
    final session = _sessions.remove(id);
    if (session == null) return false;
    await session.dispose();
    return true;
  }

  /// Executes [code] in a temporary (stateless) platform instance.
  ///
  /// Creates a fresh platform + bridge, runs the code, and disposes.
  Future<CallToolResult> executeStateless(String code) async {
    final platform = platformFactory();
    final bridge = DefaultMontyBridge(platform: platform);
    try {
      final events = bridge.execute(code);
      return await bridgeEventsToResult(events);
    } finally {
      bridge.dispose();
      await platform.dispose();
    }
  }

  /// Disposes all sessions.
  Future<void> disposeAll() async {
    final sessions = _sessions.values.toList();
    _sessions.clear();
    for (final session in sessions) {
      await session.dispose();
    }
  }
}
