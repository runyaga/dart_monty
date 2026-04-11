import 'package:dart_monty/dart_monty_bridge.dart';

import 'shared_fs_handler_contract.dart';

void main() {
  runFsHandlerContract(
    'MemoryFsProvider',
    createHandler: () async => MemoryFsProvider(),
    rootPath: '/sandbox',
  );
}
