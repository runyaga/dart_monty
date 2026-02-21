import 'package:meta/meta.dart';

/// An exception thrown by the Monty Python interpreter.
///
/// Contains the error [message] and optional source location information
/// ([filename], [lineNumber], [columnNumber]) along with the offending
/// [sourceCode] snippet when available.
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
  });

  /// Creates a [MontyException] from a JSON map.
  ///
  /// Expected keys: `message`, `filename`, `line_number`, `column_number`,
  /// `source_code`.
  factory MontyException.fromJson(Map<String, dynamic> json) {
    return MontyException(
      message: json['message'] as String,
      filename: json['filename'] as String?,
      lineNumber: json['line_number'] as int?,
      columnNumber: json['column_number'] as int?,
      sourceCode: json['source_code'] as String?,
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

  /// Serializes this exception to a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {
      'message': message,
      if (filename != null) 'filename': filename,
      if (lineNumber != null) 'line_number': lineNumber,
      if (columnNumber != null) 'column_number': columnNumber,
      if (sourceCode != null) 'source_code': sourceCode,
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
            other.sourceCode == sourceCode);
  }

  @override
  int get hashCode => Object.hash(
        message,
        filename,
        lineNumber,
        columnNumber,
        sourceCode,
      );

  @override
  String toString() {
    final buffer = StringBuffer('MontyException: $message');
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
