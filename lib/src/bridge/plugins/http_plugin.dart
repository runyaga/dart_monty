import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty/src/bridge/bridge/host_function.dart';
import 'package:dart_monty/src/bridge/bridge/host_function_schema.dart';
import 'package:dart_monty/src/bridge/bridge/host_param.dart';
import 'package:dart_monty/src/bridge/bridge/host_param_type.dart';
import 'package:dart_monty/src/bridge/bridge/monty_plugin.dart';
import 'package:http/http.dart' as http;
import 'package:signals_core/signals_core.dart';

/// Configuration for [HttpPlugin].
class HttpPluginConfig {
  const HttpPluginConfig({
    this.baseUrl,
    this.defaultHeaders = const {},
    this.defaultTimeout = const Duration(seconds: 30),
    this.maxResponseBodyBytes = 10 * 1024 * 1024,
  });

  final String? baseUrl;
  final Map<String, String> defaultHeaders;
  final Duration defaultTimeout;
  final int maxResponseBodyBytes;
}

/// Plugin providing HTTP client capabilities to Python code.
class HttpPlugin extends MontyPlugin {
  HttpPlugin({
    HttpPluginConfig? config,
    http.Client? client,
    this.allowFromSandboxedChildren = false,
  }) : config = config ?? const HttpPluginConfig(),
       _client = client ?? http.Client();

  final HttpPluginConfig config;
  final http.Client _client;
  final bool allowFromSandboxedChildren;

  /// Number of requests currently in flight.
  late final Signal<int> activeRequestsSignal = signal(0);

  /// Total number of requests initiated in this session.
  late final Signal<int> totalRequestsSignal = signal(0);

  /// Total bytes downloaded across all requests.
  late final Signal<int> totalBytesDownloadedSignal = signal(0);

  int _requestCount = 0;
  Stopwatch? _executionTimer;

  @override
  String get namespace => 'http';

  @override
  bool get hasExecuteHooks => true;

  @override
  String? get systemPromptContext =>
      'Perform HTTP requests (GET, POST, etc.). Responses include status_code, '
      'text (UTF-8), and content (binary bytes). Base URL: ${config.baseUrl ?? "none"}.';

  @override
  List<HostFunction> get functions => [
    HostFunction(schema: _httpGetSchema, handler: _handleGet),
    HostFunction(schema: _httpPostSchema, handler: _handlePost),
    HostFunction(schema: _httpRequestSchema, handler: _handleRequest),
  ];

  @override
  MontyPlugin? createChildInstance({ChildSpawnContext? context}) {
    if (!allowFromSandboxedChildren) return _DisabledHttpPlugin();
    return HttpPlugin(
      config: config,
      client: _client,
      allowFromSandboxedChildren: true,
    );
  }

  @override
  Future<void> onExecuteStart(String code) async {
    _requestCount = 0;
    _executionTimer = Stopwatch()..start();
  }

  @override
  Future<void> onExecuteEnd(ExecuteOutcome outcome) async {
    _executionTimer?.stop();
    logger.info(
      'HTTP metrics for execution',
      attributes: {
        'requests': _requestCount,
        'elapsed_ms': _executionTimer?.elapsedMilliseconds,
      },
    );
  }

  @override
  Future<void> onDispose() async {
    _client.close();
    await super.onDispose();
  }

  Future<Object?> _handleGet(Map<String, Object?> args) {
    return _doRequest(
      'GET',
      args['url']! as String,
      headers: args['headers'] as Map<String, Object?>?,
      timeoutMs: args['timeout_ms'] as int?,
    );
  }

  Future<Object?> _handlePost(Map<String, Object?> args) {
    return _doRequest(
      'POST',
      args['url']! as String,
      body: args['body'],
      headers: args['headers'] as Map<String, Object?>?,
      timeoutMs: args['timeout_ms'] as int?,
    );
  }

  Future<Object?> _handleRequest(Map<String, Object?> args) {
    return _doRequest(
      args['method']! as String,
      args['url']! as String,
      body: args['body'],
      headers: args['headers'] as Map<String, Object?>?,
      timeoutMs: args['timeout_ms'] as int?,
    );
  }

  Future<Map<String, Object?>> _doRequest(
    String method,
    String urlStr, {
    Object? body,
    Map<String, Object?>? headers,
    int? timeoutMs,
  }) async {
    _requestCount++;
    var uri = Uri.parse(urlStr);
    if (!uri.isAbsolute && config.baseUrl != null) {
      uri = Uri.parse(config.baseUrl!).resolveUri(uri);
    }

    final requestHeaders = {
      ...config.defaultHeaders,
      if (headers != null) ...headers.map((k, v) => MapEntry(k, v.toString())),
    };

    final request = http.Request(method, uri);
    request.headers.addAll(requestHeaders);

    if (body != null) {
      if (body is String) {
        request.body = body;
      } else if (body is Uint8List) {
        request.bodyBytes = body;
      } else {
        request.body = jsonEncode(body);
        request.headers.putIfAbsent('content-type', () => 'application/json');
      }
    }

    final timeout = timeoutMs != null
        ? Duration(milliseconds: timeoutMs)
        : config.defaultTimeout;

    try {
      activeRequestsSignal.value++;
      totalRequestsSignal.value++;
      final streamedResponse = await _client.send(request).timeout(timeout);
      final response = await http.Response.fromStream(streamedResponse);

      if (response.bodyBytes.length > config.maxResponseBodyBytes) {
        throw StateError('Response body size exceeds limit');
      }

      totalBytesDownloadedSignal.value += response.bodyBytes.length;

      return {
        'status_code': response.statusCode,
        'text': response.body,
        'content': response.bodyBytes,
        'headers': response.headers,
        'ok': response.statusCode >= 200 && response.statusCode < 300,
      };
    } on TimeoutException {
      throw StateError(
        'HTTP request timed out after ${timeout.inMilliseconds}ms',
      );
    } finally {
      activeRequestsSignal.value--;
    }
  }
}

class _DisabledHttpPlugin extends MontyPlugin {
  @override
  String get namespace => 'http';

  @override
  List<HostFunction> get functions => [
    HostFunction(schema: _httpGetSchema, handler: _disabled),
    HostFunction(schema: _httpPostSchema, handler: _disabled),
    HostFunction(schema: _httpRequestSchema, handler: _disabled),
  ];

  Future<Object?> _disabled(Map<String, Object?> args) {
    throw StateError(
      'PermissionError: HTTP calls are disabled in this sandbox',
    );
  }
}

// ---------------------------------------------------------------------------
// Schemas
// ---------------------------------------------------------------------------

const _httpGetSchema = HostFunctionSchema(
  name: 'http_get',
  description: 'Perform an HTTP GET request.',
  params: [
    HostParam(name: 'url', type: HostParamType.string, description: 'URL.'),
    HostParam(
      name: 'headers',
      type: HostParamType.any,
      isRequired: false,
      description: 'Optional headers dict.',
    ),
    HostParam(
      name: 'timeout_ms',
      type: HostParamType.integer,
      isRequired: false,
      description: 'Timeout override.',
    ),
  ],
);

const _httpPostSchema = HostFunctionSchema(
  name: 'http_post',
  description: 'Perform an HTTP POST request.',
  params: [
    HostParam(name: 'url', type: HostParamType.string, description: 'URL.'),
    HostParam(
      name: 'body',
      type: HostParamType.any,
      isRequired: false,
      description: 'Request body (string, bytes, or json).',
    ),
    HostParam(
      name: 'headers',
      type: HostParamType.any,
      isRequired: false,
      description: 'Optional headers dict.',
    ),
    HostParam(
      name: 'timeout_ms',
      type: HostParamType.integer,
      isRequired: false,
      description: 'Timeout override.',
    ),
  ],
);

const _httpRequestSchema = HostFunctionSchema(
  name: 'http_request',
  description: 'Perform a generic HTTP request.',
  params: [
    HostParam(
      name: 'method',
      type: HostParamType.string,
      description: 'HTTP method (GET, POST, PUT, DELETE, etc.).',
    ),
    HostParam(name: 'url', type: HostParamType.string, description: 'URL.'),
    HostParam(
      name: 'body',
      type: HostParamType.any,
      isRequired: false,
      description: 'Request body.',
    ),
    HostParam(
      name: 'headers',
      type: HostParamType.any,
      isRequired: false,
      description: 'Optional headers dict.',
    ),
    HostParam(
      name: 'timeout_ms',
      type: HostParamType.integer,
      isRequired: false,
      description: 'Timeout override.',
    ),
  ],
);
