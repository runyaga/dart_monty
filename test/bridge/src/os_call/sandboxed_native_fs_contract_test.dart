import 'dart:io';

import 'package:dart_monty/src/bridge/os_call/sandboxed_native_fs_handler.dart';
import 'package:test/test.dart';

import 'shared_fs_handler_contract.dart';

void main() {
  // Create once for the entire suite — each test gets a fresh handler
  // but the root dir persists (tests create/delete their own files).
  final root = Directory.systemTemp.createTempSync('monty_contract_');
  final rootPath = root.resolveSymbolicLinksSync();

  tearDownAll(() => root.deleteSync(recursive: true));

  runFsHandlerContract(
    'SandboxedNativeFsHandler',
    createHandler: () async => SandboxedNativeFsHandler(root: root),
    rootPath: rootPath,
  );
}
