import 'dart:io';

import 'package:dart_monty/src/workspace/workspace.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '_workspace_harness.dart';

Future<void> checkNativeOverlayRejection(
  WorkspaceHarness h,
  WorkspaceTransfers transfers,
) async {
  final directory = Directory.systemTemp.createTempSync('d4a-overlay-');
  addTearDown(() => directory.deleteSync(recursive: true));
  final mount = MountDir(hostPath: directory.path, virtualPath: '/overlay');
  addTearDown(mount.close);
  final output = Workspace(files: {'out': 'child'});
  addTearDown(output.dispose);
  var suspended = false;
  final value = await h.session.feedRun(
    'from pathlib import Path\n'
    "Path('/overlay/only').write_text('live overlay')\n"
    'transfer()\n'
    "(Path('/overlay/only').read_text(), Path('/overlay/out').exists())",
    mount: [mount],
    externalLookup: {
      'transfer': MontyHostFunction('transfer', (_, _) async {
        suspended = true;
        // Reusing a mount opens a fresh table and loses the suspended overlay.
        final fresh = await h.pool.withSession(
          (session) => session.feedRun(
            "from pathlib import Path\nPath('/overlay/only').exists()",
            mount: [mount],
          ),
        );
        expect(fresh, const MontyBool(false));
        final rejectsTransfer = throwsA(isA<ExternalException>());
        await expectLater(
          transfers.copyIn(files: {'in': '/overlay/only'}),
          rejectsTransfer,
        );
        await expectLater(
          transfers.collect(output, {'out': '/overlay/out'}),
          rejectsTransfer,
        );

        return const MontyNone();
      }),
    },
  );
  expect(suspended, true);
  expect(value.dartValue, ['live overlay', false]);
  expect(directory.listSync(), isEmpty);
}
