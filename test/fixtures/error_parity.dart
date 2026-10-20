import 'dart:convert';

import 'error_parity.g.dart';

export 'error_parity.g.dart';

/// A single traceback frame in an error-parity fixture case.
class ErrorParityFrame {
  /// Creates an [ErrorParityFrame].
  const ErrorParityFrame({
    required this.filename,
    required this.line,
    required this.column,
    required this.endLine,
    required this.endColumn,
    this.function,
    this.sourceLine,
  });

  /// Parses an [ErrorParityFrame] from a decoded JSON object.
  factory ErrorParityFrame.fromJson(Map<String, Object?> json) =>
      ErrorParityFrame(
        filename: _requireString(json, 'filename'),
        line: _requireInt(json, 'line'),
        column: _requireInt(json, 'column'),
        endLine: _requireInt(json, 'end_line'),
        endColumn: _requireInt(json, 'end_column'),
        function: _optionalString(json, 'function'),
        sourceLine: _optionalString(json, 'source_line'),
      );

  /// Source filename (for example `<python-input-0>`).
  final String filename;

  /// 1-based start line number.
  final int line;

  /// 1-based start column number.
  final int column;

  /// 1-based end line number.
  final int endLine;

  /// 1-based end column number.
  final int endColumn;

  /// Enclosing function name, or `null` for syntax/parser errors without one.
  final String? function;

  /// Source text of the frame line, if available.
  final String? sourceLine;
}

/// Expected exception details for an [ErrorParityStep].
class ErrorParityException {
  /// Creates an [ErrorParityException].
  const ErrorParityException({
    required this.type,
    required this.message,
    required this.traceback,
    this.data,
  });

  /// Parses an [ErrorParityException] from a decoded JSON object.
  factory ErrorParityException.fromJson(Map<String, Object?> json) =>
      ErrorParityException(
        type: _requireString(json, 'type'),
        message: _requireString(json, 'message'),
        traceback: _mapList(json['traceback'], ErrorParityFrame.fromJson),
        data: _optionalMap(json, 'data'),
      );

  /// Python exception type name (for example `ValueError`).
  final String type;

  /// Exception message string.
  final String message;

  /// Expected traceback frames in outer-to-inner order.
  final List<ErrorParityFrame> traceback;

  /// Optional structured payload (such as JSON or Unicode decode error fields).
  final Map<String, Object?>? data;

  /// Provides map-style lookup by JSON key name.
  Object? operator [](String key) => switch (key) {
    'type' => type,
    'message' => message,
    'traceback' => traceback,
    'data' => data,
    _ => null,
  };
}

/// Expected formatted display strings and metadata for an exception outcome.
class ErrorParityDisplay {
  /// Creates an [ErrorParityDisplay].
  const ErrorParityDisplay({
    required this.traceback,
    required this.typeMsg,
    required this.msg,
    required this.str,
    required this.exception,
    this.data,
    this.badFormat,
  });

  /// Parses an [ErrorParityDisplay] from a decoded JSON object.
  factory ErrorParityDisplay.fromJson(Map<String, Object?> json) =>
      ErrorParityDisplay(
        traceback: _requireString(json, 'traceback'),
        typeMsg: _requireString(json, 'type-msg'),
        msg: _requireString(json, 'msg'),
        str: _requireString(json, 'str'),
        exception: _requireMap(json, 'exception'),
        data: _optionalMap(json, 'data'),
        badFormat: _optionalMap(json, 'bad_format'),
      );

  /// Full formatted traceback display (`display('traceback')`).
  final String traceback;

  /// Type-and-message display (`display('type-msg')`).
  final String typeMsg;

  /// Message-only display (`display('msg')`).
  final String msg;

  /// String conversion display (`str(exc)`).
  final String str;

  /// Serialized exception representation (`type` and `args`).
  final Map<String, Object?> exception;

  /// Optional structured payload (such as JSON or Unicode decode error fields).
  final Map<String, Object?>? data;

  /// Expected error when passing an invalid display format.
  final Map<String, Object?>? badFormat;

  /// Provides map-style lookup by JSON key name.
  Object? operator [](String key) => switch (key) {
    'traceback' => traceback,
    'type-msg' => typeMsg,
    'msg' => msg,
    'str' => str,
    'exception' => exception,
    'data' => data,
    'bad_format' => badFormat,
    _ => null,
  };
}

/// Expected outcome of a single execution or REPL feed step.
class ErrorParityStep {
  /// Creates an [ErrorParityStep].
  const ErrorParityStep({
    required this.prints,
    required this.extCalls,
    this.value,
    this.exception,
    this.errorClass,
    this.display,
  });

  /// Parses an [ErrorParityStep] from a decoded JSON object.
  factory ErrorParityStep.fromJson(Map<String, Object?> json) {
    final rawException = _optionalMap(json, 'exception');
    final rawDisplay = _optionalMap(json, 'display');

    return ErrorParityStep(
      value: _optionalMap(json, 'value'),
      exception: rawException == null
          ? null
          : ErrorParityException.fromJson(rawException),
      prints: _mapList(json['prints'], (item) => item),
      extCalls: _mapList(json['ext_calls'], (item) => item),
      errorClass: _optionalString(json, 'error_class'),
      display: rawDisplay == null
          ? null
          : ErrorParityDisplay.fromJson(rawDisplay),
    );
  }

  /// Tagged return value object when the step succeeds, or `null`.
  final Map<String, Object?>? value;

  /// Uncaught exception details when the step fails, or `null`.
  final ErrorParityException? exception;

  /// Captured print events (`stream` and `text`) emitted during the step.
  final List<Map<String, Object?>> prints;

  /// External function call records observed during the step.
  final List<Map<String, Object?>> extCalls;

  /// Expected host error class name (such as `MontyRuntimeError`), or `null`.
  final String? errorClass;

  /// Expected formatted display outputs when present, or `null`.
  final ErrorParityDisplay? display;
}

/// A single test case from `test/fixtures/error_parity/cases.json`.
class ErrorParityCase {
  /// Creates an [ErrorParityCase].
  const ErrorParityCase({
    required this.id,
    required this.expected,
    this.code,
    this.feeds,
    this.externals,
    this.autoExternals,
    this.limits,
    this.inputs,
    this.normalizeNumbers = false,
  });

  /// Parses an [ErrorParityCase] from a decoded JSON object.
  factory ErrorParityCase.fromJson(Map<String, Object?> json) =>
      ErrorParityCase(
        id: _requireString(json, 'id'),
        code: _optionalString(json, 'code'),
        feeds: _optionalStringList(json, 'feeds'),
        externals: _optionalMap(json, 'externals'),
        autoExternals: _optionalStringList(json, 'auto_externals'),
        limits: _optionalMap(json, 'limits'),
        inputs: _optionalMap(json, 'inputs'),
        normalizeNumbers: json['normalize_numbers'] == true,
        expected: _mapList(json['expected'], ErrorParityStep.fromJson),
      );

  /// Unique case identifier.
  final String id;

  /// Single-execution Python snippet, when the case is not a multi-feed case.
  final String? code;

  /// Ordered REPL feeds, when the case exercises multi-feed execution.
  final List<String>? feeds;

  /// Scripted external function behaviors keyed by function name.
  final Map<String, Object?>? externals;

  /// Names of auto-registered external functions, if any.
  final List<String>? autoExternals;

  /// Resource limit overrides (`max_recursion_depth`, `max_memory`, etc.).
  final Map<String, Object?>? limits;

  /// Input variable bindings keyed by name, if any.
  final Map<String, Object?>? inputs;

  /// Whether the oracle recorded this case with every digit run written as
  /// `N`, so messages and display text compare after the same rewrite.
  final bool normalizeNumbers;

  /// Expected step outcomes (one entry per execution or REPL feed).
  final List<ErrorParityStep> expected;
}

/// Loads all error-parity cases from the baked [errorParityCasesJson] fixture.
List<ErrorParityCase> loadErrorParityCases() {
  final Object? decoded = jsonDecode(errorParityCasesJson);
  final root = _toStringKeyedMap(decoded);

  return _mapList(root['cases'], ErrorParityCase.fromJson);
}

Map<String, Object?> _toStringKeyedMap(Object? raw) {
  if (raw case final Map<String, Object?> typed) {
    return typed;
  }
  if (raw case final Map<Object?, Object?> untyped) {
    return {
      for (final MapEntry(:key, :value) in untyped.entries)
        if (key case final String stringKey) stringKey: value,
    };
  }
  throw FormatException('Expected JSON object, got ${raw.runtimeType}.');
}

List<T> _mapList<T>(
  Object? raw,
  T Function(Map<String, Object?> json) fromJson,
) {
  if (raw case final List<Object?> items) {
    return [
      for (final item in items) fromJson(_toStringKeyedMap(item)),
    ];
  }
  throw FormatException('Expected JSON list, got ${raw.runtimeType}.');
}

String _requireString(Map<String, Object?> json, String key) {
  if (json[key] case final String value) {
    return value;
  }
  throw FormatException('Expected string for "$key".');
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value case final String text) {
    return text;
  }
  throw FormatException('Expected nullable string for "$key".');
}

int _requireInt(Map<String, Object?> json, String key) {
  if (json[key] case final int value) {
    return value;
  }
  throw FormatException('Expected int for "$key".');
}

Map<String, Object?> _requireMap(Map<String, Object?> json, String key) =>
    _toStringKeyedMap(json[key]);

Map<String, Object?>? _optionalMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) {
    return null;
  }

  return _toStringKeyedMap(value);
}

List<String>? _optionalStringList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value case final List<Object?> items) {
    return [
      for (final item in items)
        if (item case final String text)
          text
        else
          throw FormatException('Expected string element in "$key".'),
    ];
  }
  throw FormatException('Expected list of strings for "$key".');
}
