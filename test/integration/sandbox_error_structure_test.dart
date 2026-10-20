@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

import '_child_contract.dart';

void main() {
  group('child error structure preservation', () {
    for (final syntax in [false, true]) {
      test(
        syntax
            ? 'ChildSandboxException preserves info from child SyntaxError'
            : 'ChildSandboxException preserves excType from child NameError',
        () async {
          final runtime = await MontyRuntime.start(
            pool: await childContractPool(),
            extensions: [SandboxExtension()],
          );
          addTearDown(runtime.dispose);
          final events = <BridgeEvent>[];
          final sub = runtime.events.listen(events.add);
          addTearDown(sub.cancel);
          final handle = await spawnChild(
            runtime,
            syntax ? 'def (' : 'undefined_variable_xyz',
          );
          await expectLater(
            awaitChild(runtime, handle),
            throwsA(
              predicate<Object>(
                (e) =>
                    e.toString().contains(syntax ? 'SyntaxError' : 'NameError'),
              ),
            ),
          );
          final [error] = events
              .whereType<BridgeChildEvent>()
              .map((e) => e.inner)
              .whereType<BridgeRunError>()
              .toList();
          final childError = error.exception?.exception;
          expect(
            childError?.excType,
            syntax ? 'SyntaxError' : 'NameError',
          );
          expect(childError?.message, isNotEmpty);
        },
      );
    }
  });
}
