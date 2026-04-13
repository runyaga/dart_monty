/// FFI integration tests for StoragePlugin through a real AgentSession.
///
/// Run with:
/// ```bash
/// dart test --run-skipped --tags=integration \
///   test/bridge/integration/storage_plugin_integration_test.dart
/// ```
@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

void main() {
  group('StoragePlugin — FFI', () {
    late AgentSession session;
    late StoragePlugin storage;

    setUp(() {
      storage = StoragePlugin();
      session = AgentSession(plugins: [storage]);
    });
    tearDown(() async => session.dispose());

    test('storage_set / storage_get round-trip', () async {
      final r = await session.execute('''
storage_set(key='name', value='alice')
storage_get(key='name')
''');
      expect(r.error, isNull);
      expect(r.value.dartValue, 'alice');
    });

    test('storage_set integer value', () async {
      await session.execute("storage_set(key='count', value=42)");
      final r = await session.execute("storage_get(key='count')");
      expect(r.error, isNull);
      expect(r.value.dartValue, 42);
    });

    test('storage_list returns stored keys', () async {
      await session.execute('''
storage_set(key='a', value=1)
storage_set(key='b', value=2)
''');
      final r = await session.execute('storage_list()');
      expect(r.error, isNull);
      final keys = r.value.dartValue! as List;
      expect(keys, containsAll(['a', 'b']));
    });

    test('storage_delete removes key', () async {
      await session.execute("storage_set(key='tmp', value='x')");
      await session.execute("storage_delete(key='tmp')");
      final r = await session.execute("storage_get(key='tmp')");
      expect(r.error, isNull);
      expect(r.value.dartValue, isNull);
    });

    test('storage_has returns bool', () async {
      await session.execute("storage_set(key='present', value=True)");
      final yes = await session.execute("storage_has(key='present')");
      final no = await session.execute("storage_has(key='absent')");
      expect(yes.value.dartValue, true);
      expect(no.value.dartValue, false);
    });

    test('storageSignal updates after execute', () async {
      expect(storage.storageSignal.value, isEmpty);
      await session.execute("storage_set(key='reactive', value='yes')");
      expect(storage.storageSignal.value, contains('reactive'));
    });

    test('VFS path write/read round-trip', () async {
      final r = await session.execute('''
from pathlib import Path
Path('/storage/note.txt').write_text('hello vfs')
Path('/storage/note.txt').read_text()
''');
      expect(r.error, isNull);
      expect(r.value.dartValue, 'hello vfs');
    });

    test('VFS write updates storageSignal', () async {
      await session.execute('''
from pathlib import Path
Path('/storage/vfs_key.txt').write_text('data')
''');
      expect(storage.storageSignal.value, contains('vfs_key.txt'));
    });
  });
}
