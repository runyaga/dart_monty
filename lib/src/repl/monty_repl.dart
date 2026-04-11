import 'dart:convert';

import 'package:dart_monty/src/platform/core_bindings.dart';
import 'package:dart_monty/src/platform/monty_error.dart';
import 'package:dart_monty/src/platform/monty_exception.dart';
import 'package:dart_monty/src/platform/monty_progress.dart';
import 'package:dart_monty/src/platform/monty_resource_usage.dart';
import 'package:dart_monty/src/platform/monty_result.dart';
import 'package:dart_monty/src/platform/monty_stack_frame.dart';
import 'package:dart_monty/src/platform/monty_value.dart';
import 'package:dart_monty/src/repl/repl_bindings.dart';
import 'package:dart_monty/src/repl/repl_factory.dart' as repl_factory;

/// Whether a source fragment is syntactically complete for REPL execution.
enum ReplContinuationMode {
  /// The snippet is complete and can be executed.
  complete,

  /// The snippet has unclosed brackets, parentheses, or strings.
  incompleteImplicit,

  /// The snippet opened an indented block and needs a trailing blank line.
  incompleteBlock,
}

/// A stateful REPL session backed by the Monty interpreter.
///
/// Unlike `MontySession` which fakes persistence via code generation,
/// `MontyRepl` uses the native Rust REPL — heap, globals, functions,
/// and classes all persist across [feed] calls without serialization.
///
/// ```dart
/// final repl = MontyRepl();
/// await repl.feed('x = 42');
/// final result = await repl.feed('x + 1');
/// print(result.value); // MontyInt(43)
/// await repl.dispose();
/// ```
class MontyRepl {
  /// Creates a [MontyRepl] with auto-detected backend (FFI or WASM).
  ///
  /// [hostFunctions] maps function names to brief descriptions, shown
  /// when the user calls `help()` in the REPL.
  MontyRepl({
    String? scriptName,
    String? preamble,
    Map<String, String> hostFunctions = const {},
  }) : _bindings = repl_factory.createReplBindings(),
       _scriptName = scriptName,
       _preamble = preamble,
       _hostFunctions = hostFunctions;

  /// Creates a [MontyRepl] with explicit [bindings].
  MontyRepl.withBindings({
    required ReplBindings bindings,
    String? scriptName,
    String? preamble,
    Map<String, String> hostFunctions = const {},
  }) : _bindings = bindings,
       _scriptName = scriptName,
       _preamble = preamble,
       _hostFunctions = hostFunctions;

  final ReplBindings _bindings;
  final String? _scriptName;
  final String? _preamble;
  final Map<String, String> _hostFunctions;
  bool _created = false;
  bool _disposed = false;

  /// Feeds a Python snippet and runs to completion.
  ///
  /// State (variables, functions, classes, heap objects) persists across
  /// calls. If the snippet raises a Python exception, the REPL survives
  /// and the error is returned in [MontyResult.error].
  Future<MontyResult> feed(String code) async {
    _checkNotDisposed();
    await _ensureCreated();

    final r = await _bindings.feedRun(code);

    if (r.ok) {
      return MontyResult(
        value: r.value != null ? MontyValue.fromJson(r.value) : null,
        error: _buildError(r.error, r.excType, r.traceback),
        usage: r.usage ?? _zeroUsage,
        printOutput: r.printOutput,
      );
    }

    // Error path — throw so callers can catch MontyScriptError.
    _throwError(
      message: r.error ?? 'Unknown error',
      excType: r.excType,
      traceback: r.traceback,
      filename: r.filename,
      lineNumber: r.lineNumber,
      columnNumber: r.columnNumber,
      sourceCode: r.sourceCode,
    );
  }

  /// Checks if [source] is complete for execution.
  ///
  /// Useful for building REPL UIs that show `>>>` vs `...` prompts.
  Future<ReplContinuationMode> detectContinuation(
    String source,
  ) async {
    _checkNotDisposed();
    await _ensureCreated();
    final mode = await _bindings.detectContinuation(source);

    return switch (mode) {
      1 => ReplContinuationMode.incompleteImplicit,
      2 => ReplContinuationMode.incompleteBlock,
      _ => ReplContinuationMode.complete,
    };
  }

  // -----------------------------------------------------------------------
  // Iterative execution (Phase 2)
  // -----------------------------------------------------------------------

  /// Starts iterative execution of [code] with external function support.
  ///
  /// If [externalFunctions] is provided, those names are registered for
  /// name resolution before execution begins. When Python calls one of
  /// these functions, execution pauses and returns [MontyPending].
  ///
  /// Use [resume] or [resumeWithError] to continue execution.
  Future<MontyProgress> feedStart(
    String code, {
    List<String>? externalFunctions,
  }) async {
    _checkNotDisposed();
    await _ensureCreated();
    if (externalFunctions != null && externalFunctions.isNotEmpty) {
      _bindings.setExtFns(externalFunctions);
    }
    final p = await _bindings.feedStart(code);

    return _translateProgress(p);
  }

  /// Resumes a paused REPL execution with [returnValue].
  Future<MontyProgress> resume(Object? returnValue) async {
    _checkNotDisposed();
    final json = returnValue != null ? jsonEncode(returnValue) : 'null';
    final p = await _bindings.resume(json);

    return _translateProgress(p);
  }

  /// Resumes a paused REPL execution by raising an error in Python.
  Future<MontyProgress> resumeWithError(String errorMessage) async {
    _checkNotDisposed();
    final p = await _bindings.resumeWithError(errorMessage);

    return _translateProgress(p);
  }

  /// Disposes the REPL session and frees native resources.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _bindings.dispose();
  }

  // -----------------------------------------------------------------------
  // Private
  // -----------------------------------------------------------------------

  static const _zeroUsage = MontyResourceUsage(
    memoryBytesUsed: 0,
    timeElapsedMs: 0,
    stackDepthUsed: 0,
  );

  MontyProgress _translateProgress(CoreProgressResult p) {
    switch (p.state) {
      case 'complete':
        return MontyComplete(
          result: MontyResult(
            value: p.value != null ? MontyValue.fromJson(p.value) : null,
            error: _buildError(p.error, p.excType, p.traceback),
            usage: p.usage ?? _zeroUsage,
            printOutput: p.printOutput,
          ),
        );
      case 'pending':
        return MontyPending(
          functionName: p.functionName ?? '',
          arguments: p.arguments != null
              ? p.arguments!.map(MontyValue.fromJson).toList()
              : const [],
          kwargs: p.kwargs?.map((k, v) => MapEntry(k, MontyValue.fromJson(v))),
          callId: p.callId ?? 0,
          methodCall: p.methodCall ?? false,
        );
      case 'os_call':
        return MontyOsCall(
          operationName: p.functionName ?? '',
          arguments: p.arguments != null
              ? p.arguments!.map(MontyValue.fromJson).toList()
              : const [],
          kwargs: p.kwargs?.map((k, v) => MapEntry(k, MontyValue.fromJson(v))),
          callId: p.callId ?? 0,
        );
      case 'error':
        _throwError(
          message: p.error ?? 'Unknown error',
          excType: p.excType,
          traceback: p.traceback,
        );
      default:
        throw StateError('Unknown progress state: ${p.state}');
    }
  }

  Future<void> _ensureCreated() async {
    if (!_created) {
      await _bindings.create(scriptName: _scriptName);
      _created = true;
      await _feedBootstrap();
    }
  }

  Future<void> _feedBootstrap() async {
    // Build the _help_registry dict: {"name": "description", ...}
    final entries = _hostFunctions.entries
        .map((e) => '    "${e.key}": "${e.value}"')
        .join(',\n');
    final registryDef = '_help_registry = {\n$entries\n}';

    // Define help(name=None): no args lists all, with arg shows detail.
    const helpDef = '''
def help(name=None):
    if name is None:
        print("Monty REPL - sandboxed Python interpreter")
        print("")
        if _help_registry:
            print("Host functions:")
            for fn, desc in _help_registry.items():
                print(f"  {fn}() - {desc}")
        else:
            print("Host functions: (none registered)")
        print("")
        print("Type help('function_name') for details.")
        print("Type Python code at the >>> prompt.")
    else:
        if name in _help_registry:
            print(f"{name}() - {_help_registry[name]}")
        else:
            print(f"Unknown function: {name}")
            print(f"Available: {', '.join(_help_registry.keys())}")''';

    await _bindings.feedRun(registryDef);
    await _bindings.feedRun(helpDef);

    // Run optional user preamble.
    final preamble = _preamble;
    if (preamble != null && preamble.isNotEmpty) {
      await _bindings.feedRun(preamble);
    }
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('MontyRepl has been disposed.');
    }
  }

  MontyException? _buildError(
    String? error,
    String? excType,
    List<dynamic>? traceback,
  ) {
    if (error == null) return null;

    return MontyException(
      message: error,
      excType: excType,
      traceback: MontyStackFrame.listFromJson(traceback ?? const []),
    );
  }

  Never _throwError({
    required String message,
    String? excType,
    List<dynamic>? traceback,
    String? filename,
    int? lineNumber,
    int? columnNumber,
    String? sourceCode,
  }) {
    if (excType == 'MemoryLimitExceeded') {
      throw MontyResourceError(message);
    }
    final exception = MontyException(
      message: message,
      excType: excType,
      traceback: MontyStackFrame.listFromJson(traceback ?? const []),
    );
    throw MontyScriptError(
      message,
      excType: excType,
      exception: exception,
    );
  }
}
