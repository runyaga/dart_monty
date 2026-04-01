import 'dart:convert';

import 'package:dart_monty_bridge/dart_monty_bridge.dart';

/// Default maximum input size for JSON text (1 MB).
const int defaultMaxJsonInputSize = 1024 * 1024;

/// Plugin that provides JSON parsing and serialization to Python scripts.
///
/// Uses Dart's `dart:convert` for reliable, battle-tested JSON handling.
/// All functions are prefixed with `json_`.
class JsonPlugin extends MontyPlugin {
  /// Creates a [JsonPlugin].
  ///
  /// [maxInputSize] controls the maximum allowed character count for
  /// `json_loads` and `json_get` inputs. Defaults to 1 MB.
  JsonPlugin({int? maxInputSize})
      : _maxInputSize = maxInputSize ?? defaultMaxJsonInputSize;

  final int _maxInputSize;

  @override
  String get namespace => 'json';

  @override
  String? get systemPromptContext =>
      'Parse and serialize JSON. Use json_loads to convert JSON text to '
      'a dict/list. Use json_dumps to convert a dict/list to JSON text. '
      'Use json_get for dot-path extraction from JSON text.';

  @override
  List<HostFunction> get functions => [
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'json_loads',
            description: 'Parse a JSON string into a dict or list.',
            params: [
              HostParam(
                name: 'data',
                type: HostParamType.string,
                description: 'JSON string to parse.',
              ),
            ],
          ),
          handler: _handleLoads,
        ),
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'json_dumps',
            description: 'Serialize a dict or list to a JSON string. '
                'Set indent > 0 for pretty-printing.',
            params: [
              HostParam(
                name: 'data',
                type: HostParamType.any,
                description: 'Value to serialize (dict, list, string, number, '
                    'bool, null).',
              ),
              HostParam(
                name: 'indent',
                type: HostParamType.integer,
                isRequired: false,
                defaultValue: 0,
                description: 'Indentation spaces. 0 = compact.',
              ),
            ],
          ),
          handler: _handleDumps,
        ),
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'json_get',
            description:
                'Parse JSON text and extract a value by dot-separated path. '
                'Returns null if path not found. '
                'Use integer segments for list indexing: "items.0.name".',
            params: [
              HostParam(
                name: 'data',
                type: HostParamType.string,
                description: 'JSON string to parse.',
              ),
              HostParam(
                name: 'path',
                type: HostParamType.string,
                description: 'Dot-separated path. e.g. "scores.ratio.value" or '
                    '"items.0.name".',
              ),
            ],
          ),
          handler: _handleGet,
        ),
      ];

  @override
  MontyPlugin? createChildInstance({ChildSpawnContext? context}) => JsonPlugin(
        maxInputSize: _maxInputSize,
      );

  Future<Object?> _handleLoads(Map<String, Object?> args) async {
    final text = args['data']! as String;
    _guardInputSize(text, 'json_loads');
    try {
      final result = jsonDecode(text);
      logger.debug('json_loads ok', attributes: {'length': text.length});
      return result;
    } on FormatException {
      rethrow;
    }
  }

  Future<Object?> _handleDumps(Map<String, Object?> args) async {
    final value = args['data'];
    final indent = args['indent']! as int;
    try {
      final String result;
      if (indent > 0) {
        result = JsonEncoder.withIndent(' ' * indent).convert(value);
      } else {
        result = jsonEncode(value);
      }
      logger.debug('json_dumps ok', attributes: {'length': result.length});
      return result;
    } on Exception catch (e) {
      throw FormatException('Cannot serialize to JSON: $e');
    }
  }

  Future<Object?> _handleGet(Map<String, Object?> args) async {
    final text = args['data']! as String;
    final path = args['path']! as String;
    _guardInputSize(text, 'json_get');

    final Object? root;
    try {
      root = jsonDecode(text);
    } on FormatException {
      rethrow;
    }

    final segments = path.split('.');
    var current = root;
    var i = 0;
    while (i < segments.length) {
      final segment = segments[i];
      if (current is Map<String, Object?>) {
        if (!current.containsKey(segment)) return null;
        current = current[segment];
      } else if (current is List<Object?>) {
        final index = int.tryParse(segment);
        if (index == null || index < 0 || index >= current.length) return null;
        current = current[index];
      } else {
        return null;
      }
      i++;
    }

    logger.debug('json_get ok', attributes: {'path': path});
    return current;
  }

  void _guardInputSize(String text, String caller) {
    if (text.length > _maxInputSize) {
      throw FormatException(
        '$caller: input exceeds $_maxInputSize character limit '
        '(got ${text.length})',
      );
    }
  }
}
