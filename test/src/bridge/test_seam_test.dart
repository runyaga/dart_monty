// What a consumer's test reaches through the public API: a MontyBridge over
// core's FakeMontySession, with no worker.
import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:test/test.dart';

import '../_user.dart';

HostFunction _fn(String name, HostFunctionHandler handler) => HostFunction(
  schema: HostFunctionSchema(
    name: name,
    description: name,
    params: const [HostParam(name: 'n', type: HostParamType.integer)],
  ),
  handler: handler,
);

/// The values the host answered with, in order.
List<Object> _returned(FakeMontySession session) => [
  for (final a in session.answers)
    if (a.answer case ExternalReturnValue(:final value)) value,
];

void main() {
  test('constructing a bridge over a session feeds nothing', () {
    final session = FakeMontySession();
    final bridge = MontyBridge(session: session);
    addTearDown(bridge.dispose);

    expect(session.feeds, isEmpty);
    expect(session.answers, isEmpty);
    expect(session.isClosed, isFalse);
  });

  test(
    'a scripted host call drives the public bridge: events and answers',
    () async {
      final session = FakeMontySession()
        ..willCall('twice', kwargs: {'n': const MontyInt(21)})
        ..willReturn(const MontyInt(42));
      final bridge = MontyBridge(session: session, logger: BridgeLogger.silent)
        ..register(_fn('twice', (args, _) async => (args['n']! as int) * 2));
      addTearDown(bridge.dispose);

      final events = await bridge.execute('twice(n=21)').toList();

      expect(session.feeds, ['twice(n=21)']);
      expect(_returned(session), [const MontyInt(42)]);
      expect(events.map((e) => e.runtimeType.toString()), [
        'BridgeRunStarted',
        'BridgeCallStarted',
        'BridgeFunctionCallStart',
        'BridgeFunctionCallArgs',
        'BridgeFunctionCallEnd',
        'BridgeFunctionCallResult',
        'BridgeCallFinished',
        'BridgeRunFinished',
      ]);
      expect(
        events.whereType<BridgeFunctionCallStart>().single.name,
        'twice',
      );
      expect(
        events.whereType<BridgeRunFinished>().single.montyValue,
        const MontyInt(42),
      );
    },
  );

  group('a host result', () {
    Future<Object> answer(Object? result) async {
      final session = FakeMontySession()
        ..willCall('give', kwargs: {'n': const MontyInt(0)})
        ..willReturn(const MontyNone());
      final bridge = MontyBridge(session: session)
        ..register(_fn('give', (_, _) async => result));
      addTearDown(bridge.dispose);
      await bridge.execute('give(n=0)').drain<void>();

      return _returned(session).single;
    }

    test('that is a MontyValue goes to Python unchanged', () async {
      const tuple = MontyTuple([MontyInt(1), MontyString('a')]);

      expect(await answer(tuple), tuple);
    });

    test('that is a host object goes to Python as that instance', () async {
      final user = userInstance('alice', 30);

      // The session sends the wrapper as an instance of its class, with the
      // eagerly sent fields: what Python then holds.
      expect(
        await answer(user),
        isA<MontyClassProxy>()
            .having((p) => p.instanceId, 'instanceId', user.id)
            .having((p) => p.attrs, 'attrs', {
              'name': const MontyString('alice'),
              'age': const MontyInt(30),
            }),
      );
    });

    test(
      'that is a Dart value is converted with MontyValue.fromDart',
      () async {
        expect(
          await answer(['a', 1, null]),
          MontyValue.fromDart(['a', 1, null]),
        );
        expect(await answer(['a', 1, null]), isA<MontyList>());
        expect(await answer(null), const MontyNone());
      },
    );
  });
}
