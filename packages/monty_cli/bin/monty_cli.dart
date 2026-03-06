import 'dart:io';

import 'package:monty_cli/src/cli_runner.dart';

Future<void> main(List<String> args) async {
  final runner = buildRunner();

  try {
    final exitCode = await runner.run(args) ?? 0;
    exit(exitCode);
  } on Exception catch (e) {
    stderr.writeln(e);
    exit(1);
  }
}
