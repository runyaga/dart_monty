import 'package:dart_monty_core/dart_monty_core.dart';

/// A fresh demo filesystem with the staged files and a writable sandbox.
Future<OSAccess> createDemoVfs(Map<String, String> stagedFiles) async {
  final vfs = OSAccess(
    files: [for (final e in stagedFiles.entries) MemoryFile(e.key, e.value)],
  );
  // OSAccess creates parents of seeded files, but an empty seed has only /.
  await vfs.call(
    'Path.mkdir',
    [MontyPath('/sandbox')],
    {'parents': const MontyBool(true), 'exist_ok': const MontyBool(true)},
  );

  return vfs;
}
