import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:file/memory.dart';

import 'shared_fs_handler_contract.dart';

void main() {
  runFsHandlerContract(
    'fsHandler(MemoryFileSystem)',
    createHandler: () async => fsHandler(MemoryFileSystem()),
    rootPath: '/sandbox',
  );
}
