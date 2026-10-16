@TestOn('vm')
@Tags(['integration', 'd1-pending'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

import '_worker.dart';
import 'shared_probe_extension.dart';

void main() {
  late Monty pool;
  late MontyRuntime runtime;
  setUpAll(() async => pool = await startTestPool());
  tearDownAll(() => pool.close());
  setUp(() async {
    runtime = await MontyRuntime.start(
      pool: pool,
      extensions: [SharedProbeExtension(), SandboxExtension()],
    );
  });
  tearDown(() => runtime.dispose());

  test('child reads parent external extension state', () async {
    final result = await runtime.execute('''
probe_put(name="input", value={"greeting": "hello", "n": 42})
h = sandbox_spawn(code='probe_get(name="input")')
sandbox_await(handle=h)
''').result;
    expect(result.dartValue, {'greeting': 'hello', 'n': 42});
  });

  test('child updates parent external extension state', () async {
    final result = await runtime.execute('''
probe_put(name="input", value=12)
h = sandbox_spawn(code='probe_put(name="output", value=probe_get(name="input") * 2)')
sandbox_await(handle=h)
probe_get(name="output")
''').result;
    expect(result.dartValue, 24);
  });

  test('sibling external extension clones retain shared state', () async {
    final result = await runtime.execute('''
probe_put(name="input", value=10)
h1 = sandbox_spawn(code='probe_put(name="first", value=probe_get(name="input") * 2)')
h2 = sandbox_spawn(code='probe_put(name="second", value=probe_get(name="input") * 4)')
sandbox_await_all(handles=[h1, h2])
sandbox_free(handle=h1)
sandbox_free(handle=h2)
[probe_get(name="first"), probe_get(name="second")]
''').result;
    expect(result.dartValue, [20, 40]);
  });
}
