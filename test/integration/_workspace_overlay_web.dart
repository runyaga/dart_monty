import 'package:dart_monty/src/workspace/workspace.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '_workspace_harness.dart';

Future<void> checkNativeOverlayRejection(
  WorkspaceHarness h,
  WorkspaceTransfers transfers,
) async {
  expect(
    () => MountDir(hostPath: '/host', virtualPath: '/overlay'),
    throwsUnsupportedError,
  );
  await expectLater(
    transfers.copyIn(files: {'in': '/overlay/only'}),
    throwsA(isA<ExternalException>()),
  );
  expect(await h.session.feedRun('1 + 1'), const MontyInt(2));
}
