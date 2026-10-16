import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

import '../../integration/shared_probe_extension.dart';

void main() {
  late SharedProbeExtension parent;
  late SharedProbeExtension child;
  setUp(() {
    parent = SharedProbeExtension();
    child = parent.createChildInstance(const ChildSpawnContext(childId: 1));
  });
  tearDown(() async {
    await child.onDispose();
    await parent.onDispose();
  });

  test('clones share backing state, not ownership', () {
    expect(parent.childPolicy, ChildPolicy.clone);
    expect(child, isNot(same(parent)));
    expect(child.values, same(parent.values));
    expect(child.pending, isNot(same(parent.pending)));
  });

  test('disposing a clone fails its own pending work', () async {
    final settled = expectLater(child.pending.future, throwsStateError);
    await child.onDispose();
    await settled;
    expect(parent.pending.isCompleted, isFalse);
  });

  test('disposing a clone leaves siblings usable', () async {
    await parent.onDispose();
    final context = HostContext(
      emit: (_) => fail('Unexpected event'),
      executionId: 'test',
    );
    await child.functions.firstOrNull!.handler!({
      'name': 'answer',
      'value': 42,
    }, context);
    expect(
      await child.functions.lastOrNull!.handler!({'name': 'answer'}, context),
      42,
    );
    expect(child.pending.isCompleted, isFalse);
  });
}
