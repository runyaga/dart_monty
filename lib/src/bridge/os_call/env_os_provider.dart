import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/bridge/os_call/os_provider.dart';

/// Handles `os.*` environment operations using a provided map.
///
/// Prevents leaking the host's full `Platform.environment` into the
/// sandboxed Python code. Only the keys in [environment] are visible.
///
/// ```dart
/// EnvOsProvider({'APP_ENV': 'production', 'DEBUG': '0'});
/// ```
class EnvOsProvider extends OsProvider {
  /// Creates a provider backed by the given [environment] map.
  const EnvOsProvider(this.environment) : super.base();

  /// The environment variables visible to Python.
  final Map<String, String> environment;

  @override
  Future<Object?> resolve(MontyOsCall call) {
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
