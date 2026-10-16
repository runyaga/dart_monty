@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty_core/dart_monty_core.dart' show OSAccess;
import 'package:test/test.dart';

import '_worker.dart';
import 'shared_probe_extension.dart';
import 'template_stub_extension.dart';

/// Integration tests for MontyRuntime with plugins — requires native FFI.
///
/// Run with:
/// ```bash
/// dart test --run-skipped --tags=integration \
///   test/bridge/integration/agent_plugin_integration_test.dart
/// ```
void main() {
  late Monty pool;
  setUpAll(() async => pool = await startTestPool());
  tearDownAll(() => pool.close());

  // ---------------------------------------------------------------------------
  // Sandbox plugin — child spawning
  // ---------------------------------------------------------------------------

  group('MontyRuntime + SandboxExtension', tags: 'd1-pending', () {
    late MontyRuntime session;

    setUp(() async {
      final osContribs = <String, OsHandler>{
        'Path.': OSAccess().call,
      };
      final tmpl = TemplateStubExtension();
      final probe = SharedProbeExtension();
      final extensions = <MontyExtension>[
        tmpl,
        probe,
        SandboxExtension(),
      ];
      session = await MontyRuntime.start(
        pool: pool,
        osHandlers: osContribs,
        extensions: extensions,
      );
    });

    tearDown(() async {
      await session.dispose();
    });

    test('spawn and await child', () async {
      final result = await session.execute('''
h = sandbox_spawn(code='2 + 3')
sandbox_await(handle=h)
''').result;

      expect(result.dartValue, 5);
    });

    test('gather multiple children', () async {
      final result = await session.execute('''
h1 = sandbox_spawn(code='10')
h2 = sandbox_spawn(code='20')
h3 = sandbox_spawn(code='30')
sandbox_await_all(handles=[h1, h2, h3])
''').result;

      expect(result.dartValue, [10, 20, 30]);
    });

    test('child error propagates cleanly', () async {
      final result = await session.execute('''
h = sandbox_spawn(code='1 / 0')
try:
    r = sandbox_await(handle=h)
except Exception as e:
    r = f'caught: {e}'
r
''').result;
      final val = result.dartValue! as String;

      expect(val, contains('ZeroDivisionError'));
    });

    test('child captures print output', () async {
      final result = await session.execute(r'''
h = sandbox_spawn(code='print("hello")\n42')
sandbox_await(handle=h)
sandbox_get_output(handle=h)
''').result;

      expect(result.dartValue, contains('hello'));
    });

    test('child lifecycle: spawn, alive, await, free', () async {
      final result = await session.execute('''
h = sandbox_spawn(code='99')
r = sandbox_await(handle=h)
alive = sandbox_is_alive(handle=h)
sandbox_free(handle=h)
[r, alive]
''').result;

      expect(result.dartValue, [99, false]);
    });
  });

  // ---------------------------------------------------------------------------
  // Cross-plugin: templates inside children
  // ---------------------------------------------------------------------------

  group('MontyRuntime cross-plugin inheritance', tags: 'd1-pending', () {
    late MontyRuntime session;

    setUp(() async {
      final osContribs = <String, OsHandler>{
        'Path.': OSAccess().call,
      };
      final tmpl = TemplateStubExtension();
      final probe = SharedProbeExtension();
      final extensions = <MontyExtension>[
        tmpl,
        probe,
        SandboxExtension(),
      ];
      session = await MontyRuntime.start(
        pool: pool,
        osHandlers: osContribs,
        extensions: extensions,
      );
    });

    tearDown(() async {
      await session.dispose();
    });

    test('child can use tmpl_render', () async {
      final result = await session.execute('''
h = sandbox_spawn(code='tmpl_render(template="Hi {{ who }}!", context={"who": "child"})')
sandbox_await(handle=h)
''').result;

      expect(result.dartValue, 'Hi child!');
    });

    test('child shares external extension state with parent', () async {
      final result = await session.execute(r'''
probe_put(name='tasks', value='do X')
h = sandbox_spawn(code='task = probe_get(name="tasks")\nprobe_put(name="results", value=f"done: {task}")\ntask')
child_got = sandbox_await(handle=h)
parent_got = probe_get(name='results')
[child_got, parent_got]
''').result;

      expect(result.dartValue, ['do X', 'done: do X']);
    });

    test('sibling clones share external extension state', () async {
      final result = await session.execute('''
producer = sandbox_spawn(code='probe_put(name="item", value="shared")')
sandbox_await(handle=producer)
consumer = sandbox_spawn(code='probe_get(name="item")')
sandbox_await(handle=consumer)
''').result;
      expect(result.dartValue, 'shared');
    });

    test('child writes to isolated filesystem', () async {
      final result = await session.execute(r'''
from pathlib import Path
Path('/parent.txt').write_text('parent data')
h = sandbox_spawn(code='from pathlib import Path\nPath("/child.txt").write_text("child data")\nPath("/child.txt").read_text()')
child_result = sandbox_await(handle=h)
parent_file = Path('/parent.txt').read_text()
[child_result, parent_file]
''').result;

      expect(result.dartValue, ['child data', 'parent data']);
    });
  });
}
