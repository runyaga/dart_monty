// A host function returns a dataclass-like value as a ClassInstance, and the
// shared session keeps it across executions.
@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';

import 'package:test/test.dart';

import '../src/_user.dart';
import '_worker.dart';

void main() {
  late Monty pool;

  setUp(() async {
    pool = await startTestPool();
    addTearDown(pool.close);
  });

  test('a ClassInstance result is a live object across executions', () async {
    final runtime = await MontyRuntime.start(pool: pool)
      ..register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'make_user',
            description: 'A User dataclass.',
            params: [
              HostParam(name: 'name', type: HostParamType.string),
              HostParam(name: 'age', type: HostParamType.integer),
            ],
          ),
          handler: (args, _) async => userInstance(
            (args['name']! as MontyString).value,
            (args['age']! as MontyInt).value,
          ),
        ),
      );
    addTearDown(runtime.dispose);

    await runtime.execute('user = make_user(name="alice", age=30)').result;
    final name = await runtime.execute('user.name').result;
    final fields = await runtime
        .execute(
          'import dataclasses\n'
          '[type(user).__name__, dataclasses.is_dataclass(user), user.age]',
        )
        .result;

    expect(name.dartValue, 'alice');
    expect(fields.dartValue, ['User', true, 30]);
  });
}
