import 'package:args/command_runner.dart';
import 'package:monty_cli/src/commands/demo_command.dart';
import 'package:monty_cli/src/commands/eval_command.dart';
import 'package:monty_cli/src/commands/repl_command.dart';
import 'package:monty_cli/src/commands/run_command.dart';

/// The top-level command runner for the monty CLI.
CommandRunner<int> buildRunner() {
  return CommandRunner<int>(
    'dmonty',
    'Standalone CLI for the Monty sandboxed Python interpreter.',
  )
    ..argParser.addMultiOption(
      'prompt',
      abbr: 'p',
      splitCommas: false,
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
    ..addCommand(DemoCommand())
    ..addCommand(EvalCommand())
    ..addCommand(RunCommand())
    ..addCommand(ReplCommand());
}
