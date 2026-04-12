import 'package:dart_monty/src/platform/monty_exception.dart';
import 'package:dart_monty/src/platform/monty_resource_usage.dart';
import 'package:dart_monty/src/platform/monty_value.dart';
import 'package:meta/meta.dart';

/// The result of executing Python code in the Monty sandbox.
///
/// A result always carries [usage] statistics. It contains either a [value]
/// (the Python expression result) or an [error] (a [MontyException]), but
/// never both.
@immutable
final class MontyResult {
  /// Creates a [MontyResult] with the given [value], optional [error], and
  /// required [usage] statistics.
  const MontyResult({
    required this.usage,
    required this.value,
    this.error,
    this.printOutput,
  });

  /// Creates a [MontyResult] from a JSON map.
  ///
  /// Expected keys: `value`, `error` (optional map), `usage` (required map).
  factory MontyResult.fromJson(Map<String, dynamic> json) {
    return MontyResult(
      value: MontyValue.fromJson(json['value']),
      error: json['error'] != null
          ? MontyException.fromJson(json['error'] as Map<String, dynamic>)
          : null,
      usage: MontyResourceUsage.fromJson(json['usage'] as Map<String, dynamic>),
      printOutput: json['print_output'] as String?,
    );
  }

  /// The return value from the Python execution.
  ///
  /// Python always produces a value — when a script returns `None` this field
  /// holds [MontyNull] rather than a Dart `null`. Use [MontyNull.dartValue]
  /// (which returns `null`) if you need the raw Dart representation.
  ///
  /// Use pattern matching to access typed values:
  /// ```dart
  /// switch (result.value) {
  ///   case MontyNull(): // Python returned None
  ///   case MontyInt(:final value): print(value);
  ///   case MontyString(:final value): print(value);
  ///   case MontyDate(:final year, :final month, :final day): ...
  /// }
  /// ```
  final MontyValue value;

  /// The error from the Python execution, or `null` if execution succeeded.
  final MontyException? error;

  /// Resource usage statistics from the execution.
  final MontyResourceUsage usage;

  /// Captured output from Python `print()` calls, or `null` if nothing was
  /// printed.
  final String? printOutput;

  /// Whether this result represents an error.
  bool get isError => error != null;

  /// Serializes this result to a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {
      'value': value.toJson(),
      if (error case final e?) 'error': e.toJson(),
      'usage': usage.toJson(),
      'print_output': ?printOutput,
    };
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is MontyResult &&
            other.value == value &&
            other.error == error &&
            other.usage == usage &&
            other.printOutput == printOutput);
  }

  @override
  int get hashCode => Object.hash(value, error, usage, printOutput);

  @override
  String toString() {
    if (error case final e?) {
      return 'MontyResult.error(${e.message})';
    }

    return 'MontyResult.value($value)';
  }
}
