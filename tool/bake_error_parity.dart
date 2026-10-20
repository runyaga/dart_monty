import 'dart:convert';
import 'dart:io';

const _inputPath = 'test/fixtures/error_parity/cases.json';
const _outputPath = 'test/fixtures/error_parity.g.dart';

/// Bakes `test/fixtures/error_parity/cases.json` into
/// `test/fixtures/error_parity.g.dart`.
///
/// Pass `--check` to verify the committed generated file is up to date without
/// writing to disk.
void main(List<String> args) {
  final checkOnly = args.contains('--check');
  final inputFile = File(_inputPath);
  if (!inputFile.existsSync()) {
    stderr.writeln('Missing input fixture: $_inputPath.');
    exitCode = 1;

    return;
  }

  final rawJson = inputFile.readAsStringSync();
  if (rawJson.contains("'''")) {
    stderr.writeln('Input JSON must not contain triple single quotes.');
    exitCode = 1;

    return;
  }

  final oracle = _extractOracle(rawJson);
  final expectedOutput = _renderGeneratedFile(
    oracle: oracle,
    rawJson: rawJson,
  );

  final outputFile = File(_outputPath);
  if (checkOnly) {
    if (!outputFile.existsSync() ||
        outputFile.readAsStringSync() != expectedOutput) {
      stderr.writeln(
        '$_outputPath is out of date; regenerate with bake_error_parity.dart.',
      );
      exitCode = 1;
    }

    return;
  }

  outputFile.writeAsStringSync(expectedOutput);
}

String _extractOracle(String rawJson) {
  final Object? decoded = jsonDecode(rawJson);
  if (decoded case {'oracle': final String oracle}) {
    return oracle;
  }
  throw const FormatException('Expected top-level "oracle" string in JSON.');
}

String _renderGeneratedFile({
  required String oracle,
  required String rawJson,
}) {
  final body = rawJson.endsWith('\n') ? rawJson : '$rawJson\n';
  final buffer = StringBuffer()
    ..writeln('// Generated file — do not edit.')
    ..writeln('// Oracle: $oracle.')
    ..writeln('// Regenerate with: dart run tool/bake_error_parity.dart.')
    ..writeln()
    ..writeln('/// The upstream oracle version recorded in `cases.json`.')
    ..writeln("const String errorParityOracle = '$oracle';")
    ..writeln()
    ..writeln('/// Raw JSON contents of `$_inputPath`.')
    ..writeln("const String errorParityCasesJson = r'''")
    ..write(body)
    ..writeln("''';");

  return buffer.toString();
}
