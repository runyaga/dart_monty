@Tags(['integration'])
@TestOn('browser')
library;

import 'package:dart_monty/src/workspace/workspace.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  test('N-web-native-mount-refusal', () {
    expect(
      () => MountDir(hostPath: '/host', virtualPath: '/work'),
      throwsUnsupportedError,
    );
    expect(() => Workspace(sandboxBaseDir: '/host'), throwsUnsupportedError);
    final memory = Workspace();
    addTearDown(memory.dispose);
    expect(
      memory.call('Path.is_dir', [MontyPath('/work')], {}),
      const MontyBool(true),
    );
  });
}
