import 'package:meta/meta.dart';

/// Resource limits to impose on a Monty Python execution.
///
/// All fields are optional — omitted limits are unconstrained.
@immutable
final class MontyLimits {
  /// Creates a [MontyLimits] with optional resource constraints.
  const MontyLimits({
    this.memoryBytes,
    this.timeoutMs,
    this.stackDepth,
  });

  /// Creates a [MontyLimits] from a JSON map.
  ///
  /// Expected keys: `memory_bytes`, `timeout_ms`, `stack_depth`.
  factory MontyLimits.fromJson(Map<String, dynamic> json) {
    return MontyLimits(
      memoryBytes: json['memory_bytes'] as int?,
      timeoutMs: json['timeout_ms'] as int?,
      stackDepth: json['stack_depth'] as int?,
    );
  }

  /// Maximum memory in bytes, or `null` for unlimited.
  final int? memoryBytes;

  /// Maximum execution time in milliseconds, or `null` for unlimited.
  final int? timeoutMs;

  /// Maximum call stack depth, or `null` for unlimited.
  final int? stackDepth;

  /// Serializes this limits configuration to a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {
      if (memoryBytes != null) 'memory_bytes': memoryBytes,
      if (timeoutMs != null) 'timeout_ms': timeoutMs,
      if (stackDepth != null) 'stack_depth': stackDepth,
    };
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is MontyLimits &&
            other.memoryBytes == memoryBytes &&
            other.timeoutMs == timeoutMs &&
            other.stackDepth == stackDepth);
  }

  @override
  int get hashCode => Object.hash(
        memoryBytes,
        timeoutMs,
        stackDepth,
      );

  @override
  String toString() {
    return 'MontyLimits('
        'memoryBytes: $memoryBytes, '
        'timeoutMs: $timeoutMs, '
        'stackDepth: $stackDepth)';
  }
}
