import 'dart:io';

import 'package:monty_cli/src/cli_runner.dart';
import 'package:monty_cli/src/commands/prompt_command.dart';
import 'package:monty_cli/src/library_resolver.dart';

Future<void> main(List<String> args) async {
  final runner = buildRunner();

  // Check for --prompt / -p before dispatching to subcommands.
  // This allows: monty-cli -p "x=1" -p "x+1"
  try {
    final parsed = runner.argParser.parse(args);
    final prompts = parsed.multiOption('prompt');

    if (prompts.isNotEmpty) {
      final exitCode = await runPrompts(
        prompts: prompts,
        json: parsed.flag('json'),
        verbose: parsed.flag('verbose'),
        libraryPath: resolveLibraryPath(
          override: parsed.option('library-path'),
        ),
      );
      exit(exitCode);
    }
  } on FormatException {
    // Fall through to runner.run() which handles its own error display.
  }

  try {
    final exitCode = await runner.run(args) ?? 0;
    exit(exitCode);
  } on Exception catch (e) {
    stderr.writeln(e);
    exit(1);
  }
}
