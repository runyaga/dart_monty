import 'package:meta/meta.dart';

/// Resource usage statistics from a Monty Python execution.
///
/// Tracks [memoryBytesUsed], [timeElapsedMs], and [stackDepthUsed] to help
/// callers monitor and budget sandbox resources.
@immutable
final class MontyResourceUsage {
  /// Creates a [MontyResourceUsage] with the given resource metrics.
  const MontyResourceUsage({
    required this.memoryBytesUsed,
    required this.timeElapsedMs,
    required this.stackDepthUsed,
  });

  /// Creates a [MontyResourceUsage] from a JSON map.
  ///
  /// Expected keys: `memory_bytes_used`, `time_elapsed_ms`,
  /// `stack_depth_used`.
  factory MontyResourceUsage.fromJson(Map<String, dynamic> json) {
    return MontyResourceUsage(
      memoryBytesUsed: json['memory_bytes_used'] as int,
      timeElapsedMs: json['time_elapsed_ms'] as int,
      stackDepthUsed: json['stack_depth_used'] as int,
    );
  }

  /// The number of bytes of memory used during execution.
  final int memoryBytesUsed;

  /// The wall-clock time elapsed in milliseconds.
  final int timeElapsedMs;

  /// The maximum stack depth reached during execution.
  final int stackDepthUsed;

  /// Serializes this resource usage to a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {
      'memory_bytes_used': memoryBytesUsed,
      'time_elapsed_ms': timeElapsedMs,
      'stack_depth_used': stackDepthUsed,
    };
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is MontyResourceUsage &&
            other.memoryBytesUsed == memoryBytesUsed &&
            other.timeElapsedMs == timeElapsedMs &&
            other.stackDepthUsed == stackDepthUsed);
  }

  @override
  int get hashCode => Object.hash(
        memoryBytesUsed,
        timeElapsedMs,
        stackDepthUsed,
      );

  @override
  String toString() {
    return 'MontyResourceUsage('
        'memoryBytesUsed: $memoryBytesUsed, '
        'timeElapsedMs: $timeElapsedMs, '
        'stackDepthUsed: $stackDepthUsed)';
  }
}
