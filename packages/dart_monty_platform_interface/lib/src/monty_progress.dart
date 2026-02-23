import 'package:collection/collection.dart';
import 'package:dart_monty_platform_interface/src/monty_result.dart';
import 'package:meta/meta.dart';

/// Deep equality instance shared across [MontyPending] operations.
const _deepEquality = DeepCollectionEquality();

/// The progress of a multi-step Monty Python execution.
///
/// A sealed class with two subtypes:
/// - [MontyComplete] — execution finished with a [MontyResult].
/// - [MontyPending] — execution paused, awaiting an external function call.
///
/// Use pattern matching to handle both cases:
/// ```dart
/// switch (progress) {
///   case MontyComplete(:final result):
///     print(result.value);
///   case MontyPending(:final functionName, :final arguments):
///     print('Call $functionName with $arguments');
/// }
/// ```
sealed class MontyProgress {
  /// Creates a [MontyProgress].
  const MontyProgress();

  /// Creates a [MontyProgress] from a JSON map.
  ///
  /// The `type` discriminator selects the subtype:
  /// - `'complete'` → [MontyComplete]
  /// - `'pending'` → [MontyPending]
  factory MontyProgress.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;

    return switch (type) {
      'complete' => MontyComplete.fromJson(json),
      'pending' => MontyPending.fromJson(json),
      _ => throw ArgumentError.value(type, 'type', 'Unknown progress type'),
    };
  }

  /// Serializes this progress to a JSON-compatible map.
  Map<String, dynamic> toJson();
}

/// Execution completed with a [result].
@immutable
final class MontyComplete extends MontyProgress {
  /// Creates a [MontyComplete] with the given [result].
  const MontyComplete({required this.result});

  /// Creates a [MontyComplete] from a JSON map.
  ///
  /// Expected keys: `type` (must be `'complete'`), `result` (required map).
  factory MontyComplete.fromJson(Map<String, dynamic> json) {
    return MontyComplete(
      result: MontyResult.fromJson(json['result'] as Map<String, dynamic>),
    );
  }

  /// The final result of the execution.
  final MontyResult result;

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': 'complete',
      'result': result.toJson(),
    };
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is MontyComplete && other.result == result);
  }

  @override
  int get hashCode => result.hashCode;

  @override
  String toString() => 'MontyComplete($result)';
}

/// Execution paused, awaiting the return value of an external function call.
@immutable
final class MontyPending extends MontyProgress {
  /// Creates a [MontyPending] with the given [functionName] and [arguments].
  const MontyPending({
    required this.functionName,
    required this.arguments,
  });

  /// Creates a [MontyPending] from a JSON map.
  ///
  /// Expected keys: `type` (must be `'pending'`), `function_name`,
  /// `arguments` (list, defaults to empty if absent).
  factory MontyPending.fromJson(Map<String, dynamic> json) {
    final rawArgs = json['arguments'] as List<dynamic>?;

    return MontyPending(
      functionName: json['function_name'] as String,
      arguments: rawArgs != null ? List<Object?>.from(rawArgs) : const [],
    );
  }

  /// The name of the external function to call.
  final String functionName;

  /// The arguments to pass to the external function.
  final List<Object?> arguments;

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': 'pending',
      'function_name': functionName,
      'arguments': arguments,
    };
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is MontyPending &&
            other.functionName == functionName &&
            _deepEquality.equals(other.arguments, arguments));
  }

  @override
  int get hashCode => Object.hash(functionName, _deepEquality.hash(arguments));

  @override
  String toString() => 'MontyPending($functionName, $arguments)';
}
