// The agent-loop acceptance suite: scenarios A1-A9.
//
// An LLM agent drives one shared-mode MontyRuntime through a single tool,
// `run_python(code)`, which returns `{value, output, error?}` JSON and never
// throws for a Python error; host tools come from bridged extensions. The
// suite runs that loop through dart_monty's public API on a real worker: a
// worker process on the VM, a Web Worker in Chrome and Firefox (dart2js and
// dart2wasm). Only A8's fault injection uses the runtime's test hook.
//
// Run:
//   DART_MONTY_WORKER=<worker> dart test test/acceptance --run-skipped \
//     --tags acceptance
//   dart test test/acceptance -p chrome,firefox -c dart2js,dart2wasm \
//     --run-skipped --tags acceptance
@Tags(['acceptance'])
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty/src/runtime/runtime.dart' show startRuntimeWith;
import 'package:test/test.dart';

import '_platform.dart';

/// The agent's tool: runs [code] and returns `{value, output, error?}`
/// JSON. A Python error is data, never a throw. With [timeout] the
/// execution is cancelled when it runs longer.
Future<String> runPythonTool(
  MontyRuntime runtime,
  String code, {
  Duration? timeout,
  void Function(ExecutionHandle handle)? onHandle,
}) async {
  final handle = runtime.execute(code);
  onHandle?.call(handle);
  final events = handle.events.toList();
  final timer = timeout == null
      ? null
      : Timer(timeout, () => unawaited(handle.cancel()));
  Object? value;
  Map<String, Object?>? error;
  try {
    value = (await handle.result).dartValue;
  } on MontyError catch (e) {
    error = {
      'excType': e.exception.excType,
      'message': e.exception.message,
      'traceback': [
        if (e case MontyRuntimeError(:final traceback))
          for (final frame in traceback) '$frame',
      ],
    };
  } finally {
    timer?.cancel();
  }
  final output = StringBuffer();
  for (final event in await events) {
    switch (event) {
      case BridgeRunFinished(:final printOutput?) ||
          BridgeRunError(:final printOutput?):
        output.write(printOutput);
      default:
        break;
    }
  }

  return jsonEncode({'value': value, 'output': '$output', 'error': ?error});
}

Map<String, Object?> _decode(String json) =>
    jsonDecode(json) as Map<String, Object?>;

/// A host tool backed by [handler], named [name], with [params].
HostFunction _tool(
  String name,
  List<HostParam> params,
  HostFunctionHandler handler, {
  DispatchMode dispatch = DispatchMode.sync,
}) => HostFunction(
  schema: HostFunctionSchema(name: name, description: name, params: params),
  handler: handler,
  dispatch: dispatch,
);

/// A host plugin bridged as an extension, as each app plugin is.
final class _Plugin extends MontyExtension {
  _Plugin(this.namespace, this.functions);

  @override
  final String namespace;

  @override
  final List<HostFunction> functions;
}

/// The host tools of the scenarios, recording each call.
final class _Tools {
  final calls = <(String, Map<String, Object?>)>[];
  Exception? markerFailure;

  List<MontyExtension> get extensions => [
    _Plugin('narrate', [
      _tool(
        'narrate_say',
        const [
          HostParam(name: 'text', type: HostParamType.string),
          HostParam(
            name: 'actor',
            type: HostParamType.string,
            isRequired: false,
          ),
        ],
        (args, _) async {
          calls.add(('narrate_say', args));

          return 'ok';
        },
      ),
    ]),
    _Plugin('map', [
      _tool(
        'map_add_marker',
        const [
          HostParam(name: 'lat', type: HostParamType.number),
          HostParam(name: 'lng', type: HostParamType.number),
        ],
        (args, _) async {
          calls.add(('map_add_marker', args));
          if (markerFailure case final failure?) throw failure;

          return 'marker-1';
        },
      ),
      _tool(
        'map_sleep_ms',
        const [HostParam(name: 'ms', type: HostParamType.integer)],
        (args, _) async {
          final ms = args['ms']! as int;
          await Future<void>.delayed(Duration(milliseconds: ms));

          return ms;
        },
        dispatch: DispatchMode.future,
      ),
    ]),
    _Plugin('http', [
      _tool(
        'http_get_json',
        const [HostParam(name: 'url', type: HostParamType.string)],
        (args, _) async {
          calls.add(('http_get_json', args));
          await Future<void>.delayed(const Duration(milliseconds: 50));

          return {
            'msg': 'm',
            'n': 3,
            'xs': [1.5, null],
          };
        },
      ),
    ]),
  ];
}

void main() {
  late Monty pool;
  late _Tools tools;

  Future<MontyRuntime> startRuntime({ResourceLimits? limits}) async {
    final runtime = await MontyRuntime.start(
      pool: pool,
      extensions: tools.extensions,
      limits: limits,
    );
    addTearDown(runtime.dispose);

    return runtime;
  }

  setUpAll(countWorkers);

  setUp(() async {
    tools = _Tools();
    pool = await Monty.start(
      maxProcesses: 3,
      checkoutTimeout: const Duration(seconds: 30),
      workerLocation: acceptanceWorkerLocation,
    );
    addTearDown(pool.close);
  });

  test('A1 tool round trip: value, print text, events and result', () async {
    final runtime = await startRuntime();
    late ExecutionHandle handle;
    final events = <BridgeEvent>[];

    final json = await runPythonTool(
      runtime,
      'print("hi")\nx = 6 * 7\nx',
      onHandle: (h) {
        handle = h;
        h.events.listen(events.add);
      },
    );

    expect(_decode(json), {'value': 42, 'output': 'hi\n'});
    expect(events, hasLength(2));
    expect(events.first, isA<BridgeRunStarted>());
    expect(
      events.last,
      isA<BridgeRunFinished>()
          .having((e) => e.printOutput, 'printOutput', 'hi\n')
          .having((e) => e.montyValue, 'montyValue', const MontyInt(42)),
    );
    expect(await handle.result, const MontyInt(42));
  });

  test('A2 a Python error is data, and the runtime runs on', () async {
    final runtime = await startRuntime();
    late ExecutionHandle handle;
    final events = <BridgeEvent>[];

    final json = _decode(
      await runPythonTool(
        runtime,
        'print("before")\n1/0',
        onHandle: (h) {
          handle = h;
          h.events.listen(events.add);
          // The tool awaits the result itself; this copy only reads it.
          h.result.ignore();
        },
      ),
    );

    expect(json['output'], 'before\n');
    final error = json['error']! as Map<String, Object?>;
    expect(error['excType'], 'ZeroDivisionError');
    expect(error['traceback'], isNotEmpty);
    final failure = events.whereType<BridgeRunError>().single;
    expect(failure.exception, isA<MontyError>());
    expect(failure.exception!.exception.excType, 'ZeroDivisionError');
    await expectLater(handle.result, throwsA(same(failure.exception)));

    expect(_decode(await runPythonTool(runtime, '1+1'))['value'], 2);
  });

  test(
    'A3 state persists across executions, and clearState resets it',
    () async {
      final runtime = await startRuntime();

      await runPythonTool(runtime, 'y = 1');
      expect(_decode(await runPythonTool(runtime, 'y + 1'))['value'], 2);
      await runtime.clearState();
      final error = _decode(await runPythonTool(runtime, 'y'))['error'];

      expect(error, isA<Map<String, Object?>>());
      expect((error! as Map)['excType'], 'NameError');
    },
  );

  test('A4 host tools, sync-shaped and async, in program order with typed '
      'arguments', () async {
    final runtime = await startRuntime();
    final events = <BridgeEvent>[];

    final json = await runPythonTool(
      runtime,
      'r = http_get_json(url="u")\n'
      'assert r == {"msg": "m", "n": 3, "xs": [1.5, None]}, r\n'
      'narrate_say(text=r["msg"])\n'
      'map_add_marker(lat=1.5, lng=2.0)',
      onHandle: (h) => h.events.listen(events.add),
    );

    expect(_decode(json), {'value': 'marker-1', 'output': ''});
    expect(tools.calls.map((c) => c.$1), [
      'http_get_json',
      'narrate_say',
      'map_add_marker',
    ]);
    expect(tools.calls[0].$2['url'], isA<String>());
    expect(tools.calls[1].$2['text'], 'm');
    final marker = tools.calls[2].$2;
    expect(marker['lat'], isA<double>());
    expect(marker['lat'], 1.5);
    expect(marker['lng'], 2.0);

    // Each call: started, name, arguments, end, result, finished.
    final calls = events.where((e) => e is! BridgeRunStarted).toList()
      ..removeLast();
    expect(calls, hasLength(18));
    for (final (i, name, result) in [
      (0, 'http_get_json', null),
      (6, 'narrate_say', 'ok'),
      (12, 'map_add_marker', 'marker-1'),
    ]) {
      final callId = (calls[i] as BridgeCallStarted).callId;
      expect(
        calls[i + 1],
        isA<BridgeFunctionCallStart>()
            .having((e) => e.name, 'name', name)
            .having((e) => e.callId, 'callId', callId),
      );
      expect(calls[i + 2], isA<BridgeFunctionCallArgs>());
      expect(calls[i + 3], isA<BridgeFunctionCallEnd>());
      expect(
        calls[i + 4],
        isA<BridgeFunctionCallResult>().having(
          (e) => e.result,
          'result',
          result ?? '{msg: m, n: 3, xs: [1.5, null]}',
        ),
      );
      expect(
        calls[i + 5],
        isA<BridgeCallFinished>().having((e) => e.callId, 'callId', callId),
      );
    }
  });

  group('A5 a failing host tool', () {
    test('is a RuntimeError Python can catch', () async {
      tools.markerFailure = const FormatException('bad');
      final runtime = await startRuntime();

      final json = await runPythonTool(
        runtime,
        'try:\n'
        '  map_add_marker(lat=1.0, lng=2.0)\n'
        'except Exception as e:\n'
        '  out = [type(e).__name__, str(e)]\n'
        'out',
      );

      expect(_decode(json)['value'], ['RuntimeError', 'FormatException: bad']);
    });

    test('is error data when uncaught, and the runtime runs on', () async {
      tools.markerFailure = const FormatException('bad');
      final runtime = await startRuntime();

      final json = _decode(
        await runPythonTool(runtime, 'map_add_marker(lat=1.0, lng=2.0)'),
      );

      final error = json['error']! as Map<String, Object?>;
      expect(error['excType'], 'RuntimeError');
      expect(error['message'], 'FormatException: bad');
      expect(_decode(await runPythonTool(runtime, '1+1'))['value'], 2);
    });
  });

  test('A6 concurrent async tools overlap and keep request order', () async {
    final runtime = await startRuntime();
    // Warm the session and the extensions, so the timing is the gather's.
    await runPythonTool(runtime, '0');
    final watch = Stopwatch()..start();

    final json = await runPythonTool(
      runtime,
      'import asyncio\n'
      'await asyncio.gather(map_sleep_ms(ms=100), map_sleep_ms(ms=101), '
      'map_sleep_ms(ms=102))',
    );
    watch.stop();

    expect(_decode(json)['value'], [100, 101, 102]);
    expect(watch.elapsedMilliseconds, lessThan(250));
  });

  group('A7 runaway code', () {
    test('(a) the tool timeout cancels it; the next execution runs on a '
        'fresh checkout, with no extra worker', () async {
      final runtime = await startRuntime();
      await runPythonTool(runtime, '0');
      final before = await liveWorkers();
      Duration? settled;
      final watch = Stopwatch();

      final json = _decode(
        await runPythonTool(
          runtime,
          'while True:\n  pass',
          timeout: const Duration(milliseconds: 300),
          onHandle: (h) {
            Timer(const Duration(milliseconds: 300), watch.start);
            h.result.whenComplete(() => settled = watch.elapsed).ignore();
          },
        ),
      );

      expect(json['error'], isNotNull);
      expect(settled, lessThan(const Duration(seconds: 2)));
      expect(_decode(await runPythonTool(runtime, '1+1'))['value'], 2);
      // The cancelled worker is gone, its replacement holds the session.
      await _until(() async => await liveWorkers() == before);
    });

    test('(b) a feed duration limit raises TimeoutError as data; the next '
        'execution runs on a replaced session', () async {
      final runtime = await startRuntime(
        limits: const ResourceLimits(
          maxFeedDuration: Duration(milliseconds: 200),
        ),
      );
      await runPythonTool(runtime, 'kept = 1');

      final json = _decode(await runPythonTool(runtime, 'while True:\n  pass'));

      expect((json['error']! as Map)['excType'], 'TimeoutError');
      expect(_decode(await runPythonTool(runtime, '1+1'))['value'], 2);
      // The replacement starts with empty globals.
      final gone = _decode(await runPythonTool(runtime, 'kept'));
      expect((gone['error']! as Map)['excType'], 'NameError');
      // The limits hold on the replacement too.
      final again = _decode(
        await runPythonTool(runtime, 'while True:\n  pass'),
      );
      expect((again['error']! as Map)['excType'], 'TimeoutError');
    });
  });

  test('A8 a worker crash is data, and the next execution runs on a '
      'replacement worker', () async {
    final sessions = <MontySession>[];
    final runtime = await startRuntimeWith(
      checkout: ({limits}) async {
        final session = await pool.checkout(limits: limits);
        sessions.add(session);

        return session;
      },
      extensions: tools.extensions,
    );
    addTearDown(runtime.dispose);
    await runPythonTool(runtime, 'kept = 1');
    final pid = sessions.single.workerPid;
    late ExecutionHandle handle;

    final pending = runPythonTool(
      runtime,
      'while True:\n  pass',
      onHandle: (h) => (handle = h).result.ignore(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (hasWorkerProcesses) {
      // The worker dies as an out-of-memory kill would end it.
      expect(killWorker(pid!), isTrue);
    } else {
      // A Web Worker cannot be killed from outside its session: closing the
      // session mid-turn terminates it.
      await sessions.single.close();
    }
    final json = _decode(await pending);

    expect((json['error']! as Map)['excType'], 'RuntimeError');
    await expectLater(handle.result, throwsA(isA<MontyCrashedError>()));
    expect(_decode(await runPythonTool(runtime, '1+1'))['value'], 2);
    expect(sessions, hasLength(2));
    if (hasWorkerProcesses) {
      expect(sessions.last.workerPid, isNot(pid));
      expect(await processAlive(pid!), isFalse);
    }
    // The host tools are still bridged on the replacement.
    final tool = _decode(await runPythonTool(runtime, 'narrate_say(text="x")'));
    expect(tool['value'], 'ok');
  });

  test(
    'A9 dispose ends the runtime; closing the pool leaves no worker',
    () async {
      final runtime = await startRuntime();
      expect(_decode(await runPythonTool(runtime, '1'))['value'], 1);
      expect(await liveWorkers() ?? 1, greaterThan(0));

      await runtime.dispose();
      await pool.close();

      expect(() => runtime.execute('1'), throwsStateError);
      await _until(() async => (await liveWorkers() ?? 0) == 0);
    },
  );

  test(
    'A9 a runtime that owns its pool leaves no worker after dispose',
    () async {
      // Only this test's workers count.
      await pool.close();
      await _until(() async => (await liveWorkers() ?? 0) == 0);
      final ownPool = await Monty.start(
        workerLocation: acceptanceWorkerLocation,
      );
      final runtime = await startRuntimeWith(
        checkout: ownPool.checkout,
        closePool: ownPool.close,
        extensions: tools.extensions,
      );
      expect(_decode(await runPythonTool(runtime, '1'))['value'], 1);
      expect(await liveWorkers() ?? 1, greaterThan(0));

      await runtime.dispose();

      expect(() => runtime.execute('1'), throwsStateError);
      await _until(() async => (await liveWorkers() ?? 0) == 0);
    },
  );
}

/// Waits until [done] holds, for up to five seconds.
Future<void> _until(Future<bool> Function() done) async {
  for (var i = 0; i < 100; i++) {
    if (await done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('the condition did not hold within five seconds');
}
