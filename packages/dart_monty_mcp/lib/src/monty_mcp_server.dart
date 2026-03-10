import 'package:dart_monty_bridge/dart_monty_bridge.dart';
import 'package:dart_monty_mcp/src/monty_session_manager.dart';
import 'package:mcp_dart/mcp_dart.dart';

/// Reserved tool name prefix. Host functions must not start with this.
const _reservedPrefix = 'monty_';

/// MCP server that exposes the Monty Python interpreter as tools.
///
/// Registers stateless and session-based tools:
/// - `monty_run` — execute Python code (stateless, one-shot)
/// - `monty_session_create` — create a persistent session
/// - `monty_session_exec` — execute code in a persistent session
/// - `monty_session_list` — list active sessions
/// - `monty_session_destroy` — destroy a persistent session
class MontyMcpServer {
  /// Creates a [MontyMcpServer].
  ///
  /// Pass [platformFactory] to control how Monty platform instances are
  /// created. Pass [version] to set the server version in the MCP
  /// implementation info.
  MontyMcpServer({
    required PlatformFactory platformFactory,
    String version = '0.1.0',
  }) : _sessionManager = MontySessionManager(
          platformFactory: platformFactory,
        ) {
    _server = McpServer(
      Implementation(name: 'dart-monty-mcp', version: version),
      options: const McpServerOptions(
        capabilities: ServerCapabilities(
          tools: ServerCapabilitiesTools(),
        ),
      ),
    );
    _registerTools();
  }

  final MontySessionManager _sessionManager;
  late final McpServer _server;

  /// The underlying session manager (for testing/introspection).
  MontySessionManager get sessionManager => _sessionManager;

  /// Connects the server to [transport] and starts serving.
  Future<void> serve(Transport transport) async {
    await _server.connect(transport);
  }

  /// Disposes all sessions and cleans up.
  Future<void> dispose() async {
    await _sessionManager.disposeAll();
  }

  /// Registers all host functions from [plugin] as both Python-callable
  /// host functions (on sessions) and direct MCP tools.
  ///
  /// Must be called before [serve]. Each function becomes:
  /// 1. A host function on all future sessions (callable from Python)
  /// 2. An MCP tool (callable directly by the LLM)
  void registerPlugin(MontyPlugin plugin) {
    for (final fn in plugin.functions) {
      registerHostFunction(fn);
    }
  }

  /// Registers a single [HostFunction] as both a Python-callable host
  /// function and a direct MCP tool.
  ///
  /// Throws [ArgumentError] if the function name starts with the reserved
  /// `monty_` prefix.
  void registerHostFunction(HostFunction function) {
    final name = function.schema.name;
    if (name.startsWith(_reservedPrefix)) {
      throw ArgumentError(
        'Host function name "$name" cannot start with '
        'reserved prefix "$_reservedPrefix"',
      );
    }
    _sessionManager.registerHostFunction(function);
    _registerHostFunctionAsTool(function);
  }

  void _registerHostFunctionAsTool(HostFunction fn) {
    final schema = fn.schema;
    _server.registerTool(
      schema.name,
      description: schema.description,
      inputSchema: ToolInputSchema(
        properties: {
          for (final param in schema.params)
            param.name: JsonSchema.fromJson(
              Map<String, dynamic>.from(param.toJsonSchema()),
            ),
        },
        required: [
          for (final param in schema.params)
            if (param.isRequired) param.name,
        ],
      ),
      callback: (args, extra) async {
        try {
          final validated = <String, Object?>{};
          for (final param in schema.params) {
            validated[param.name] = param.validate(args[param.name]);
          }
          final result = await fn.handler(validated);
          return CallToolResult(
            content: [TextContent(text: '$result')],
          );
        } catch (e) {
          return CallToolResult(
            isError: true,
            content: [TextContent(text: e.toString())],
          );
        }
      },
    );
  }

  void _registerTools() {
    _registerMontyRun();
    _registerSessionCreate();
    _registerSessionExec();
    _registerSessionList();
    _registerSessionDestroy();
  }

  void _registerMontyRun() {
    _server.registerTool(
      'monty_run',
      description: 'Execute Python code in a sandboxed Monty interpreter. '
          'Returns stdout output and the expression result. '
          'Each call runs in a fresh interpreter (no state persists).',
      inputSchema: ToolInputSchema(
        properties: {
          'code': JsonSchema.string(
            description: 'Python code to execute',
          ),
        },
        required: ['code'],
      ),
      callback: (args, extra) async {
        final code = args['code'] as String;
        return _sessionManager.executeStateless(code);
      },
    );
  }

  void _registerSessionCreate() {
    _server.registerTool(
      'monty_session_create',
      description: 'Create a persistent Python session. Variables and imports '
          'persist across calls to monty_session_exec.',
      inputSchema: ToolInputSchema(
        properties: {
          'session_id': JsonSchema.string(
            description: 'Optional session ID. Auto-generated if omitted.',
          ),
        },
      ),
      callback: (args, extra) async {
        final requestedId = args['session_id'] as String?;
        final id = _sessionManager.createSession(id: requestedId);
        if (id == null) {
          return CallToolResult(
            isError: true,
            content: [
              TextContent(text: 'Session already exists: $requestedId'),
            ],
          );
        }
        return CallToolResult(
          content: [TextContent(text: 'Session created: $id')],
        );
      },
    );
  }

  void _registerSessionExec() {
    _server.registerTool(
      'monty_session_exec',
      description: 'Execute Python code in a persistent session. '
          'Variables and imports from previous calls are available.',
      inputSchema: ToolInputSchema(
        properties: {
          'session_id': JsonSchema.string(
            description: 'Session ID from monty_session_create',
          ),
          'code': JsonSchema.string(
            description: 'Python code to execute',
          ),
        },
        required: ['session_id', 'code'],
      ),
      callback: (args, extra) async {
        final sessionId = args['session_id'] as String;
        final code = args['code'] as String;
        final session = _sessionManager.getSession(sessionId);
        if (session == null) {
          return CallToolResult(
            isError: true,
            content: [
              TextContent(text: 'Session not found: $sessionId'),
            ],
          );
        }
        return session.execute(code);
      },
    );
  }

  void _registerSessionList() {
    _server.registerTool(
      'monty_session_list',
      description: 'List all active Python sessions.',
      inputSchema: const ToolInputSchema(properties: {}),
      callback: (args, extra) async {
        final ids = _sessionManager.sessionIds;
        final text = ids.isEmpty
            ? 'No active sessions'
            : 'Active sessions:\n${ids.join('\n')}';
        return CallToolResult(
          content: [TextContent(text: text)],
        );
      },
    );
  }

  void _registerSessionDestroy() {
    _server.registerTool(
      'monty_session_destroy',
      description: 'Destroy a persistent Python session and free resources.',
      inputSchema: ToolInputSchema(
        properties: {
          'session_id': JsonSchema.string(
            description: 'Session ID to destroy',
          ),
        },
        required: ['session_id'],
      ),
      callback: (args, extra) async {
        final sessionId = args['session_id'] as String;
        final destroyed = await _sessionManager.destroySession(sessionId);
        if (!destroyed) {
          return CallToolResult(
            isError: true,
            content: [
              TextContent(text: 'Session not found: $sessionId'),
            ],
          );
        }
        return CallToolResult(
          content: [TextContent(text: 'Session destroyed: $sessionId')],
        );
      },
    );
  }
}
