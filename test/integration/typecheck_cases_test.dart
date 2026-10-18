@Tags(['integration'])
library;

import 'dart:convert';

import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

import '_typecheck_cases.dart';
import '_worker.dart';

void main() {
  late Monty pool;

  setUpAll(() async => pool = await startTestPool(maxProcesses: 4));
  tearDownAll(() => pool.close());

  for (final typecheckCase in typecheckCases) {
    test('${typecheckCase.id} ${typecheckCase.title}', () async {
      final calls = <String>[];
      final checked = await _runCase(pool, typecheckCase, calls, checked: true);
      final unchecked = await _runCase(
        pool,
        typecheckCase,
        [],
        checked: false,
      );
      final report = {
        'id': typecheckCase.id,
        'verdict': checked.verdict.name,
        'codes': checked.codes.toList()..sort(),
        'diagnostics': checked.diagnostics,
        'checkedOutcome': checked.outcome,
        'uncheckedOutcome': unchecked.outcome,
      };
      // ignore: avoid_print, the TCCASE line is the cross-platform report.
      print('TCCASE ${jsonEncode(report)}');

      expect(
        checked.verdict,
        typecheckCase.verdict,
        reason: '${typecheckCase.id}: verdict',
      );
      expect(
        checked.codes,
        typecheckCase.codes,
        reason: '${typecheckCase.id}: diagnostic codes',
      );
      if (checked.verdict == Verdict.reject) {
        expect(
          calls.isNotEmpty,
          isFalse,
          reason: '${typecheckCase.id}: rejected code must not call a host',
        );
      }
      expect(
        checked.outcome,
        typecheckCase.checkedOutcome,
        reason: '${typecheckCase.id}: checked outcome',
      );
      expect(
        unchecked.outcome,
        typecheckCase.uncheckedOutcome,
        reason: '${typecheckCase.id}: unchecked outcome',
      );
      if (typecheckCase.cls != CaseClass.builtin &&
          typecheckCase.cls != CaseClass.module) {
        final actualClass = _deriveClass(checked.verdict, unchecked.outcome);
        expect(
          actualClass,
          typecheckCase.cls,
          reason: '${typecheckCase.id}: derived class',
        );
      }
    });
  }
}

Future<_CaseResult> _runCase(
  Monty pool,
  TypecheckCase typecheckCase,
  List<String> calls, {
  required bool checked,
}) async {
  final runtime = await MontyRuntime.start(
    pool: pool,
    typeCheck: checked,
    typeCheckStubs: checked ? typecheckStubs : null,
    typeCheckFormat: checked ? 'json' : null,
  );
  typecheckHostFunctions(calls).forEach(runtime.register);
  try {
    for (final setup in typecheckCase.setup) {
      await runtime
          .execute(setup, skipTypeCheck: checked && typecheckCase.skipSetup)
          .result;
    }
    calls.clear();
    try {
      final value = await runtime.execute(typecheckCase.program).result;

      return _CaseResult(
        verdict: Verdict.pass,
        codes: const {},
        diagnostics: const [],
        outcome: _success(
          value,
          checked
              ? typecheckCase.checkedOutcome
              : typecheckCase.uncheckedOutcome,
        ),
      );
    } on MontyTypingError catch (error) {
      final diagnostics = _diagnostics(error.display());

      return _CaseResult(
        verdict: Verdict.reject,
        codes: {
          for (final diagnostic in diagnostics) diagnostic['code']! as String,
        },
        diagnostics: diagnostics,
        outcome: 'not-run',
      );
    } on MontyError catch (error) {
      return _CaseResult(
        verdict: Verdict.pass,
        codes: const {},
        diagnostics: const [],
        outcome: 'error:${error.exception.excType}',
      );
    } on Object catch (error) {
      return _CaseResult(
        verdict: Verdict.pass,
        codes: const {},
        diagnostics: const [],
        outcome: 'dart:${error.runtimeType}',
      );
    }
  } finally {
    await runtime.dispose();
  }
}

List<Map<String, Object?>> _diagnostics(String text) {
  final decoded = jsonDecode(text)! as List<Object?>;

  return [
    for (final item in decoded)
      if (item case {
        'code': final String code,
        'message': final String message,
        'location': final Map<Object?, Object?> location,
      })
        <String, Object?>{
          'code': code,
          'message': message,
          'row': location['row'],
          'column': location['column'],
        },
  ];
}

String _success(MontyValue value, String expected) =>
    expected.contains(':') ? 'ok:${_pythonRepr(value.dartValue)}' : 'ok';

String _pythonRepr(Object? value) => switch (value) {
  null => 'None',
  true => 'True',
  false => 'False',
  String() => "'${value.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'",
  List<Object?>() => '[${value.map(_pythonRepr).join(', ')}]',
  Map<Object?, Object?>() =>
    '{${value.entries.map((entry) {
      final key = _pythonRepr(entry.key);
      final item = _pythonRepr(entry.value);

      return '$key: $item';
    }).join(', ')}}',
  _ => '$value',
};

CaseClass _deriveClass(Verdict verdict, String uncheckedOutcome) {
  final failed =
      uncheckedOutcome.startsWith('error:') ||
      uncheckedOutcome.startsWith('dart:');

  return switch ((verdict, failed)) {
    (Verdict.reject, true) => CaseClass.catchError,
    (Verdict.reject, false) => CaseClass.knownFalsePositive,
    (Verdict.pass, true) => CaseClass.knownMiss,
    (Verdict.pass, false) => CaseClass.accept,
  };
}

class _CaseResult {
  const _CaseResult({
    required this.verdict,
    required this.codes,
    required this.diagnostics,
    required this.outcome,
  });

  final Verdict verdict;
  final Set<String> codes;
  final List<Map<String, Object?>> diagnostics;
  final String outcome;
}
