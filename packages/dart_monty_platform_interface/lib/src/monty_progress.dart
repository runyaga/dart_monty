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
///
/// M7A additions:
/// - [kwargs] — keyword arguments passed by the Python call site. When
///   non-null, the call used `fn(key=value)` syntax.
/// - [callId] — a unique identifier for this call, used to correlate
///   pending calls with their resolution in async/futures scenarios (M13).
/// - [methodCall] — `true` when the call was made as a method on an
///   object (e.g. `obj.method()`), `false` for plain function calls.
///
/// ```dart
/// case MontyPending(:final functionName, :final kwargs):
///   if (kwargs != null) {
///     print('$functionName called with kwargs: $kwargs');
///   }
/// ```
@immutable
final class MontyPending extends MontyProgress {
  /// Creates a [MontyPending] with the given [functionName] and [arguments].
  const MontyPending({
    required this.functionName,
    required this.arguments,
    this.kwargs,
    this.callId = 0,
    this.methodCall = false,
  });

  /// Creates a [MontyPending] from a JSON map.
  ///
  /// Expected keys: `type` (must be `'pending'`), `function_name`,
  /// `arguments` (list, defaults to empty if absent), `kwargs` (map,
  /// optional), `call_id` (int, defaults to 0), `method_call` (bool,
  /// defaults to false).
  factory MontyPending.fromJson(Map<String, dynamic> json) {
    final rawArgs = json['arguments'] as List<dynamic>?;
    final rawKwargs = json['kwargs'] as Map<String, dynamic>?;

    return MontyPending(
      functionName: json['function_name'] as String,
      arguments: rawArgs != null ? List<Object?>.from(rawArgs) : const [],
      kwargs: rawKwargs != null ? Map<String, Object?>.from(rawKwargs) : null,
      callId: json['call_id'] as int? ?? 0,
      methodCall: json['method_call'] as bool? ?? false,
    );
  }

  /// The name of the external function to call.
  final String functionName;

  /// The positional arguments to pass to the external function.
  final List<Object?> arguments;

  /// Keyword arguments from the Python call site.
  ///
  /// `null` when no keyword arguments were used. An empty map `{}`
  /// means kwargs were explicitly empty (e.g. `fn(**{})`).
  final Map<String, Object?>? kwargs;

  /// A unique identifier for this pending call.
  ///
  /// Used to correlate calls with their resolutions in async execution
  /// scenarios. Defaults to `0` for single-call-at-a-time workflows.
  final int callId;

  /// Whether this was a method call (e.g. `obj.method()`) rather than
  /// a plain function call.
  final bool methodCall;

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': 'pending',
      'function_name': functionName,
      'arguments': arguments,
      if (kwargs != null) 'kwargs': kwargs,
      if (callId != 0) 'call_id': callId,
      if (methodCall) 'method_call': methodCall,
    };
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is MontyPending &&
            other.functionName == functionName &&
            _deepEquality.equals(other.arguments, arguments) &&
            _deepEquality.equals(other.kwargs, kwargs) &&
            other.callId == callId &&
            other.methodCall == methodCall);
  }

  @override
  int get hashCode => Object.hash(
        functionName,
        _deepEquality.hash(arguments),
        _deepEquality.hash(kwargs),
        callId,
        methodCall,
      );

  @override
  String toString() => 'MontyPending($functionName, $arguments)';
}
