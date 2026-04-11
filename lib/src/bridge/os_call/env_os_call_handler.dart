import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/bridge/os_call/os_call_handler.dart';

/// Handles `os.*` environment operations using a provided map.
///
/// Prevents leaking the host's full `Platform.environment` into the
/// sandboxed Python code. Only the keys in [environment] are visible.
///
/// ```dart
/// EnvOsCallHandler({'APP_ENV': 'production', 'DEBUG': '0'});
/// ```
class EnvOsCallHandler extends OsCallHandler {
  /// Creates a handler backed by the given [environment] map.
  EnvOsCallHandler(this.environment);

  /// The environment variables visible to Python.
  final Map<String, String> environment;

  @override
  Future<Object?> handle(MontyOsCall call) {
    final op = call.operationName;
    final args = call.arguments;

    return Future.value(switch (op) {
      'os.getenv' =>
        environment[_extractString(args.first)] ??
            (args.length > 1 ? args[1].dartValue : null),
      'os.environ' => Map<String, String>.unmodifiable(environment),
      _ => throw UnsupportedError('Unsupported env operation: $op'),
    });
  }
}

String _extractString(MontyValue arg) => switch (arg) {
  MontyString(:final value) || MontyPath(:final value) => value,
  _ => throw ArgumentError('Expected string, got: $arg'),
};
