import 'package:dart_monty/src/workspace/workspace.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '_workspace_pool_web.dart' if (dart.library.io) '_worker.dart';

class WorkspaceHarness {
  late Monty pool;
  late MontySession session;
  void install() {
    setUpAll(() async {
      pool = await startTestPool();
    });
    tearDownAll(() => pool.close());
    setUp(() async {
      session = await pool.checkout();
    });
    tearDown(() => session.close());
  }

  Future<Object?> run(Workspace workspace, String code) async =>
      (await workspace.driver(session)(
        'from pathlib import Path\n$code',
        cwd: '/work',
      )).dartValue;
  Future<String> caught(Workspace workspace, String code) async =>
      (await run(
            workspace,
            'try:\n    $code\n    result = "ok"\n'
            'except Exception as e:\n'
            '    result = type(e).__name__ + ": " + str(e)\nresult',
          ))!
          as String;
}
