@Tags(['integration'])
library;

import 'package:dart_monty/src/os_call/os_handlers.dart';
import 'package:dart_monty/src/workspace/workspace.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '_workspace_harness.dart';

void main() {
  final h = WorkspaceHarness()..install();
  late Workspace w;
  setUp(() {
    w = Workspace();
  });
  tearDown(() => w.dispose());
  test('open calls route through the workspace', () async {
    final os = composeOsHandlers({'Path.': w.call});
    final value = await h.session.feedRun(
      "with open('a', 'w') as f:\n    f.write('hi')\nopen('a').read()",
      cwd: '/work',
      os: os,
    );
    expect(value, const MontyString('hi'));
    expect(w.writeBytes, 2);
  });
  test('synchronous workspace calls can decline', () async {
    expect(
      () => w.call('Path.read_text', [MontyPath('/outside')], {}),
      throwsA(isA<OsCallNotHandledException>()),
    );
    expect(
      await h.caught(w, "Path('/outside').read_text()"),
      startsWith('PermissionError:'),
    );
  });
  test('workspace calls do not fall through to parent filesystems', () async {
    var called = false;
    final os = w.compose((name, args, kwargs) {
      called = true;
      return const MontyString('parent secret');
    });
    expect(
      () => os('open', [const MontyString('/parent')], {}),
      throwsA(isA<OsCallNotHandledException>()),
    );
    expect(called, isFalse);
    expect(
      await h.session.feedRun("import os\nos.getenv('KEY')", os: os),
      const MontyString('parent secret'),
    );
    expect(called, isTrue);
  });
}
