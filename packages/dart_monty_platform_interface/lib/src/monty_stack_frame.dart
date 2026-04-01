import 'package:meta/meta.dart';

/// A single frame in a Python traceback.
///
/// Represents one level of the call stack at the point where an error
/// occurred. The fields mirror the upstream monty `TracebackFrame` struct.
///
/// ```dart
/// for (final frame in exception.traceback) {
///   print('${frame.filename}:${frame.startLine} in ${frame.frameName}');
///   if (frame.previewLine != null) print('  ${frame.previewLine}');
/// }
/// ```
@immutable
final class MontyStackFrame {
  /// Creates a [MontyStackFrame] with source location and optional metadata.
  const MontyStackFrame({
    required this.filename,
    required this.startLine,
    required this.startColumn,
    this.endLine,
    this.endColumn,
    this.frameName,
    this.previewLine,
    this.hideCaret = false,
    this.hideFrameName = false,
  });

  /// Creates a [MontyStackFrame] from a JSON map.
  ///
  /// Expected keys: `filename`, `start_line`, `start_column`,
  /// `end_line`, `end_column`, `frame_name`, `preview_line`,
  /// `hide_caret`, `hide_frame_name`.
  factory MontyStackFrame.fromJson(Map<String, dynamic> json) {
    return MontyStackFrame(
      filename: json['filename'] as String,
      startLine: json['start_line'] as int,
      startColumn: json['start_column'] as int,
      endLine: json['end_line'] as int?,
      endColumn: json['end_column'] as int?,
      frameName: json['frame_name'] as String?,
      previewLine: json['preview_line'] as String?,
      hideCaret: json['hide_caret'] as bool? ?? false,
      hideFrameName: json['hide_frame_name'] as bool? ?? false,
    );
  }

  /// The source filename for this frame.
  final String filename;

  /// The starting line number (1-based).
  final int startLine;

  /// The starting column number (0-based).
  final int startColumn;

  /// The ending line number, if the span covers multiple lines.
  final int? endLine;

  /// The ending column number, if available.
  final int? endColumn;

  /// The name of the function or scope for this frame (e.g. `'<module>'`).
  final String? frameName;

  /// A source code preview line for display.
  final String? previewLine;

  /// Whether to hide the caret indicator when rendering this frame.
  final bool hideCaret;

  /// Whether to hide the frame name when rendering this frame.
  final bool hideFrameName;

  /// Serializes this frame to a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {
      'filename': filename,
      'start_line': startLine,
      'start_column': startColumn,
      if (endLine != null) 'end_line': endLine,
      if (endColumn != null) 'end_column': endColumn,
      if (frameName != null) 'frame_name': frameName,
      if (previewLine != null) 'preview_line': previewLine,
      if (hideCaret) 'hide_caret': hideCaret,
      if (hideFrameName) 'hide_frame_name': hideFrameName,
    };
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is MontyStackFrame &&
            other.filename == filename &&
            other.startLine == startLine &&
            other.startColumn == startColumn &&
            other.endLine == endLine &&
            other.endColumn == endColumn &&
            other.frameName == frameName &&
            other.previewLine == previewLine &&
            other.hideCaret == hideCaret &&
            other.hideFrameName == hideFrameName);
  }

  @override
  int get hashCode => Object.hash(
        filename,
        startLine,
        startColumn,
        endLine,
        endColumn,
        frameName,
        previewLine,
        hideCaret,
        hideFrameName,
      );

  @override
  String toString() => 'MontyStackFrame($filename:$startLine:$startColumn)';

  /// Parses a JSON list of frame objects into a list of [MontyStackFrame].
  static List<MontyStackFrame> listFromJson(List<Object?> jsonList) {
    return jsonList
        .cast<Map<String, dynamic>>()
        .map(MontyStackFrame.fromJson)
        .toList();
  }
}
