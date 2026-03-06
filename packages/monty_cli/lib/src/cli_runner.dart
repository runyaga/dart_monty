import 'package:args/command_runner.dart';
import 'package:monty_cli/src/commands/eval_command.dart';
import 'package:monty_cli/src/commands/repl_command.dart';
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
    ..argParser.addMultiOption(
      'prompt',
      abbr: 'p',
      help: 'Execute Python expression(s) in a single session.\n'
          'Can be repeated: -p "x=1" -p "x+1"',
      valueHelp: 'expression',
    )
    ..argParser.addFlag(
      'json',
      help: 'Output results as JSON (with --prompt).',
      negatable: false,
    )
    ..argParser.addFlag(
      'verbose',
      abbr: 'v',
      help: 'Show resource usage stats on stderr (with --prompt).',
      negatable: false,
    )
    ..addCommand(EvalCommand())
    ..addCommand(RunCommand())
    ..addCommand(ReplCommand());
}
