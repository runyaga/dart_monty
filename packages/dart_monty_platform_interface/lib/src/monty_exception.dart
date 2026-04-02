import 'package:collection/collection.dart';
import 'package:dart_monty_platform_interface/src/monty_stack_frame.dart';
import 'package:meta/meta.dart';

/// Deep equality instance for traceback comparison.
const _deepEquality = DeepCollectionEquality();

/// An exception thrown by the Monty Python interpreter.
///
/// Contains the error [message] and optional source location information
/// ([filename], [lineNumber], [columnNumber]) along with the offending
/// [sourceCode] snippet when available.
///
/// M7A additions:
/// - [excType] — the Python exception class name (e.g. `'ValueError'`,
///   `'TypeError'`), enabling programmatic error handling without string
///   parsing.
/// - [traceback] — the full call-chain as a list of [MontyStackFrame]
///   objects, providing multi-frame visibility for debugging.
///
/// ```dart
/// switch (exception.excType) {
///   case 'ValueError':
///     handleValueError(exception);
///   case 'TypeError':
///     handleTypeError(exception);
///   default:
///     handleGenericError(exception);
/// }
/// ```
@immutable
final class MontyException implements Exception {
  /// Creates a [MontyException] with the given [message] and optional
  /// source location details.
  const MontyException({
    required this.message,
    this.filename,
    this.lineNumber,
    this.columnNumber,
    this.sourceCode,
    this.excType,
    this.traceback = const [],
  });

  /// Creates a [MontyException] from a JSON map.
  ///
  /// Expected keys: `message`, `filename`, `line_number`, `column_number`,
  /// `source_code`, `exc_type`, `traceback`.
  factory MontyException.fromJson(Map<String, dynamic> json) {
    final rawTraceback = json['traceback'] as List<dynamic>?;

    return MontyException(
      message: json['message'] as String,
      filename: json['filename'] as String?,
      lineNumber: json['line_number'] as int?,
      columnNumber: json['column_number'] as int?,
      sourceCode: json['source_code'] as String?,
      excType: json['exc_type'] as String?,
      traceback: rawTraceback != null
          ? MontyStackFrame.listFromJson(rawTraceback)
          : const [],
    );
  }

  /// The error message describing what went wrong.
  final String message;

  /// The filename where the error occurred, if available.
  final String? filename;

  /// The line number where the error occurred, if available.
  final int? lineNumber;

  /// The column number where the error occurred, if available.
  final int? columnNumber;

  /// The source code snippet where the error occurred, if available.
  final String? sourceCode;

  /// The Python exception class name (e.g. `'ValueError'`, `'TypeError'`).
  ///
  /// When non-null, enables programmatic dispatch on exception type
  /// without parsing the [message] string.
  final String? excType;

  /// The full traceback as a list of [MontyStackFrame] objects.
  ///
  /// Ordered from outermost frame (module level) to innermost frame
  /// (where the error occurred). Empty when traceback information is
  /// not available from the interpreter.
  final List<MontyStackFrame> traceback;

  /// Serializes this exception to a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {
      'message': message,
      if (filename != null) 'filename': filename,
      if (lineNumber != null) 'line_number': lineNumber,
      if (columnNumber != null) 'column_number': columnNumber,
      if (sourceCode != null) 'source_code': sourceCode,
      if (excType != null) 'exc_type': excType,
      if (traceback.isNotEmpty)
        'traceback': traceback.map((f) => f.toJson()).toList(),
    };
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is MontyException &&
            other.message == message &&
            other.filename == filename &&
            other.lineNumber == lineNumber &&
            other.columnNumber == columnNumber &&
            other.sourceCode == sourceCode &&
            other.excType == excType &&
            _deepEquality.equals(other.traceback, traceback));
  }

  @override
  int get hashCode => Object.hash(
        message,
        filename,
        lineNumber,
        columnNumber,
        sourceCode,
        excType,
        _deepEquality.hash(traceback),
      );

  @override
  String toString() {
    final buffer = StringBuffer('MontyException: ');
    if (excType != null) {
      buffer.write('$excType: ');
    }
    buffer.write(message);
    if (filename != null) {
      buffer.write(' ($filename');
      if (lineNumber != null) {
        buffer.write(':$lineNumber');
        if (columnNumber != null) {
          buffer.write(':$columnNumber');
        }
      }
      buffer.write(')');
    }

    return buffer.toString();
  }
}
