import 'package:args/command_runner.dart';
import 'package:monty_cli/src/commands/eval_command.dart';
import 'package:monty_cli/src/commands/run_command.dart';

/// The top-level command runner for the monty CLI.
CommandRunner<int> buildRunner() {
  return CommandRunner<int>(
    'monty-cli',
    'Standalone CLI for the Monty sandboxed Python interpreter.',
  )
    ..argParser.addOption(
      'library-path',
      help: 'Path to the native Monty shared library.\n'
          r'Defaults to $MONTY_LIBRARY_PATH if set.',
      valueHelp: 'path',
    )
    ..addCommand(EvalCommand())
    ..addCommand(RunCommand());
}
