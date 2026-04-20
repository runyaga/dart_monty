/// MontyHarness — a self-contained test harness for MontyRuntime.
///
/// Wires up a complete MontyRuntime with:
///   - In-memory VFS (Dart writes files; Python reads via pathlib.Path)
///   - Intercepting tool call layer (records every call + result)
///   - Per-tool fault injection (override result, force throw, add delay)
///   - Script priming (execute setup Python before the experiment starts)
///   - SignalCapture<T> — records every signal value change via effect()
///   - FauxUi — subscribes to runtime.events + plugin signals, simulates
///     what a Flutter widget tree would observe without the Flutter overhead
///
/// No server, no LLM, no network. The harness lets you write Python that
/// calls host functions exactly as an LLM would produce tool calls, and
/// verify the full Dart ↔ Python round-trip in isolation.
///
/// Usage:
/// ```dart
/// final h = MontyHarness()
///   ..registerTool(
///     'get_weather',
///     (args, ctx) async => {'temp': 22, 'city': args['city']},
///   )
///   ..writeFile('/data/config.json', '{"env": "test"}')
///   ..prime('from pathlib import Path');
///
/// await h.setup(); // attach runtime
///
/// final result = await h.run('''
///   w = get_weather(city='London')
///   w['temp']
/// ''');
///
/// h.assertToolCalled('get_weather', args: {'city': 'London'});
/// expect(result.value.dartValue, 22);
/// await h.dispose();
/// ```
library;

import 'dart:async';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:file/memory.dart';
import 'package:signals_core/signals_core.dart';

/// A recorded tool call — name, args, result or error, timing.
class ToolCallRecord {
  ToolCallRecord({
    required this.name,
    required this.args,
    required this.startedAt,
  });

  final String name;
  final Map<String, Object?> args;
  final DateTime startedAt;
  Object? result;
  Object? error;
  late Duration duration;
  bool get succeeded => error == null;
}

/// Fault configuration for a specific tool.
class ToolFault {
  const ToolFault._({this.throws, this.override, this.delay});

  /// Force the tool to throw this exception.
  factory ToolFault.throws(Exception error) =>
      ToolFault._(throws: error);

  /// Replace the tool's return value with [value].
  factory ToolFault.returns(Object? value) =>
      ToolFault._(override: value);

  /// Add an artificial delay before the tool responds.
  factory ToolFault.delayed(Duration delay, {Object? then}) =>
      ToolFault._(delay: delay, override: then);

  final Exception? throws;
  final Object? override;
  final Duration? delay;
}

// ---------------------------------------------------------------------------
// SignalCapture<T>
// ---------------------------------------------------------------------------

/// Records every value a signal takes via [effect()].
///
/// Usage:
/// ```dart
/// final cap = SignalCapture(ext.channelStateSignal);
/// await h.run(script);
/// expect(cap.values, [isA<EventLoopIdle>(), isA<EventLoopExecuting>(), ...]);
/// cap.dispose();
/// ```
class SignalCapture<T> {
  SignalCapture(ReadonlySignal<T> signal) {
    _cleanup = effect(() {
      _values.add(signal.value);
    });
  }

  final List<T> _values = [];
  late final EffectCleanup _cleanup;

  List<T> get values => List.unmodifiable(_values);

  void dispose() => _cleanup();
}

// ---------------------------------------------------------------------------
// FauxUi
// ---------------------------------------------------------------------------

/// Simulates what a Flutter widget tree would observe from a MontyRuntime.
///
/// Subscribes to [runtime.events] and collects typed events — giving you the
/// same AG-UI state delta / snapshot / activity coverage that a real UI would
/// see, without Flutter or widget-test overhead.
///
/// ```dart
/// await h.setup();
/// final ui = FauxUi(h.runtime);
///
/// await h.run(script);
///
/// ui.assertEventSequence([
///   isA<BridgeRunStarted>(),
///   isA<BridgeFunctionCallStart>(),
///   isA<BridgeFunctionCallEnd>(),
///   isA<BridgeRunFinished>(),
/// ]);
/// ui.dispose();
/// ```
class FauxUi {
  FauxUi(MontyRuntime runtime) {
    _sub = runtime.events.listen((e) => _events.add(e));
  }

  final List<BridgeEvent> _events = [];
  late final StreamSubscription<BridgeEvent> _sub;

  List<BridgeEvent> get events => List.unmodifiable(_events);

  /// All events of type [T].
  List<T> eventsOf<T extends BridgeEvent>() =>
      _events.whereType<T>().toList();

  /// Assert that the flat event list matches [matchers] in order.
  ///
  /// Uses `expect` style — throws [TestFailure] on mismatch.
  void assertEventSequence(List<bool Function(BridgeEvent)> matchers) {
    if (_events.length < matchers.length) {
      throw TestFailure(
        'Expected at least ${matchers.length} events, got ${_events.length}.\n'
        'Events: ${_events.map((e) => e.runtimeType).toList()}',
      );
    }
    for (var i = 0; i < matchers.length; i++) {
      if (!matchers[i](_events[i])) {
        throw TestFailure(
          'Event[$i] mismatch: expected matcher[$i] to pass, '
          'got ${_events[i].runtimeType}',
        );
      }
    }
  }

  /// Assert that [eventType] appears at least once.
  void assertContains<T extends BridgeEvent>() {
    if (eventsOf<T>().isEmpty) {
      throw TestFailure(
        'Expected at least one ${T} event, but none appeared.\n'
        'Events: ${_events.map((e) => e.runtimeType).toList()}',
      );
    }
  }

  /// Assert that [eventType] never appeared.
  void assertAbsent<T extends BridgeEvent>() {
    final found = eventsOf<T>();
    if (found.isNotEmpty) {
      throw TestFailure(
        'Expected no ${T} events, but found ${found.length}.',
      );
    }
  }

  void reset() => _events.clear();

  void dispose() => _sub.cancel();
}

// ---------------------------------------------------------------------------
// MontyHarness
// ---------------------------------------------------------------------------

/// Self-contained test harness for MontyRuntime experiments.
class MontyHarness {
  MontyHarness({
    List<MontyExtension>? extensions,
    bool sandbox = false,
  })  : _extensions = extensions ?? [],
        _sandbox = sandbox,
        _fs = MemoryFileSystem();

  final List<MontyExtension> _extensions;
  final bool _sandbox;
  final MemoryFileSystem _fs;

  final List<HostFunction> _tools = [];
  final Map<String, ToolFault> _faults = {};
  final List<ToolCallRecord> _calls = [];
  final List<String> _primeCode = [];

  MontyRuntime? _runtime;

  // ---------------------------------------------------------------------------
  // Build phase — call before setup()
  // ---------------------------------------------------------------------------

  /// Register a host function callable from Python.
  ///
  /// May be called before or after [setup()] — if the runtime is already
  /// running the function is registered immediately.
  void registerTool(
    String name,
    HostFunctionHandler handler, {
    String description = '',
    List<HostParam> params = const [],
  }) {
    final fn = HostFunction(
      schema: HostFunctionSchema(
        name: name,
        description: description,
        params: params,
      ),
      handler: handler,
    );
    _tools.add(fn);
    _runtime?.register(fn);
  }

  /// Write a file into the in-memory VFS.
  ///
  /// Python can read it with:
  ///   `from pathlib import Path; Path('/data/x.txt').read_text()`
  void writeFile(String virtualPath, String content) {
    final file = _fs.file(virtualPath);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  /// Queue Python code to execute once during [setup()], before experiments.
  void prime(String code) {
    _primeCode.add(code);
  }

  /// Inject a fault for [toolName] — applied to the next call(s).
  void injectFault(String toolName, ToolFault fault) {
    _faults[toolName] = fault;
  }

  /// Remove a previously injected fault.
  void clearFault(String toolName) => _faults.remove(toolName);

  // ---------------------------------------------------------------------------
  // Setup / teardown
  // ---------------------------------------------------------------------------

  /// Creates and primes the runtime. Must be called before [run].
  Future<void> setup() async {
    final interceptor = _buildInterceptor();
    _runtime = MontyRuntime(
      osHandlers: {'Path.': fsHandler(_fs)},
      extensions: _extensions,
      interceptor: interceptor,
      sandbox: _sandbox,
    );
    _tools.forEach(_runtime!.register);
    for (final code in _primeCode) {
      final r = await _runtime!.execute(code).result;
      if (r.error != null) {
        throw StateError(
          'Priming code failed: ${r.error!.message}\n\n$code',
        );
      }
    }
  }

  /// Disposes the runtime. Call in tearDown.
  Future<void> dispose() => _runtime?.dispose() ?? Future.value();

  // ---------------------------------------------------------------------------
  // Execution
  // ---------------------------------------------------------------------------

  /// The live [MontyRuntime] — available after [setup()].
  MontyRuntime get runtime {
    _assertSetup();
    return _runtime!;
  }

  /// Execute Python code and return the final result.
  ///
  /// All tool calls are recorded in [calls].
  Future<MontyResult> run(String code) {
    _assertSetup();
    return _runtime!.execute(code).result;
  }

  /// Execute Python code and collect all bridge events + final result.
  Future<({MontyResult result, List<BridgeEvent> events})> runWithEvents(
    String code,
  ) async {
    _assertSetup();
    final handle = _runtime!.execute(code);
    final events = await handle.events.toList();
    final result = await handle.result;
    return (result: result, events: events);
  }

  /// Execute Python from a file in the VFS.
  ///
  /// The file content is read by Dart and passed to [run].
  Future<MontyResult> runFile(String virtualPath) {
    final content = _fs.file(virtualPath).readAsStringSync();
    return run(content);
  }

  // ---------------------------------------------------------------------------
  // Assertions
  // ---------------------------------------------------------------------------

  /// All recorded tool calls in invocation order.
  List<ToolCallRecord> get calls => List.unmodifiable(_calls);

  /// Calls for a specific tool, in order.
  List<ToolCallRecord> callsTo(String name) =>
      _calls.where((c) => c.name == name).toList();

  /// Assert [toolName] was called at least once, optionally with [args].
  void assertCalled(String toolName, {Map<String, Object?>? args}) {
    final matching = callsTo(toolName);
    if (matching.isEmpty) {
      throw TestFailure('Expected $toolName to be called, but it was not.');
    }
    if (args != null) {
      final withArgs = matching.where((c) {
        for (final entry in args.entries) {
          if (c.args[entry.key] != entry.value) return false;
        }
        return true;
      }).toList();
      if (withArgs.isEmpty) {
        throw TestFailure(
          'Expected $toolName(${_fmtArgs(args)}) but actual calls were:\n'
          '${matching.map((c) => '  $toolName(${_fmtArgs(c.args)})')
              .join('\n')}',
        );
      }
    }
  }

  /// Assert [toolName] was never called.
  void assertNotCalled(String toolName) {
    final matching = callsTo(toolName);
    if (matching.isNotEmpty) {
      throw TestFailure(
        'Expected $toolName NOT to be called, but it was called '
        '${matching.length} time(s).',
      );
    }
  }

  /// Assert [toolName] was called exactly [n] times.
  void assertCallCount(String toolName, int n) {
    final count = callsTo(toolName).length;
    if (count != n) {
      throw TestFailure(
        'Expected $toolName to be called $n time(s), got $count.',
      );
    }
  }

  /// Assert every call succeeded (no tool threw an error).
  void assertNoErrors() {
    final failed = _calls.where((c) => c.error != null).toList();
    if (failed.isNotEmpty) {
      throw TestFailure(
        'Tool calls with errors:\n'
        '${failed.map((c) => '  ${c.name}: ${c.error}').join('\n')}',
      );
    }
  }

  /// Reset recorded calls. Useful between sub-experiments.
  void resetCalls() => _calls.clear();

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  void _assertSetup() {
    if (_runtime == null) {
      throw StateError(
        'MontyHarness.setup() must be called before run().',
      );
    }
  }

  MontyInterceptor _buildInterceptor() {
    return (name, args, next) async {
      final record = ToolCallRecord(
        name: name,
        args: args,
        startedAt: DateTime.now(),
      );
      _calls.add(record);

      final fault = _faults[name];
      try {
        if (fault != null) {
          if (fault.delay != null) await Future<void>.delayed(fault.delay!);
          if (fault.throws != null) throw fault.throws!;
          record
            ..result = fault.override
            ..duration = DateTime.now().difference(record.startedAt);
          return fault.override;
        }
        final result = await next();
        record
          ..result = result
          ..duration = DateTime.now().difference(record.startedAt);
        return result;
      } catch (e) {
        record
          ..error = e
          ..duration = DateTime.now().difference(record.startedAt);
        rethrow;
      }
    };
  }

  String _fmtArgs(Map<String, Object?> args) =>
      args.entries.map((e) => '${e.key}=${e.value}').join(', ');
}

/// Thrown by assertion helpers on failure.
class TestFailure implements Exception {
  const TestFailure(this.message);
  final String message;

  @override
  String toString() => 'TestFailure: $message';
}
