import 'package:monty_cli/src/cli_runner.dart';
import 'package:test/test.dart';

void main() {
  group('eval command', () {
    test('runner contains eval command', () {
      final runner = buildRunner();
      expect(runner.commands.keys, contains('eval'));
    });

    test('runner --help does not throw', () async {
      final runner = buildRunner();
      // --help returns null (no exit code), not an exception.
      final result = await runner.run(['--help']);
      expect(result, isNull);
    });
  });
}
