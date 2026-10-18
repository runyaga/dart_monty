@Tags(['bench'])
library;

import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

import '_worker.dart';

void main() {
  late Monty pool;

  setUpAll(() async => pool = await startTestPool(maxProcesses: 4));
  tearDownAll(() => pool.close());

  test('type-check latency matrix', () async {
    for (final stubs in [5, 20, 60]) {
      for (final lines in [10, 50, 200]) {
        await _measureGroup(pool, lines: lines, stubs: stubs);
      }
    }
  });

  test('type-check latency as context grows', () async {
    const stubs = 20;
    const lines = 10;
    final runtime = await _runtime(pool, stubs);
    try {
      for (var turn = 1; turn <= 30; turn++) {
        final value = await runtime
            .execute(_program(lines, prefix: 't${turn}_'))
            .result;
        expect(value, isA<MontyValue>());
        if ({1, 10, 20, 30}.contains(turn)) {
          final samples = <double>[];
          for (var sample = 0; sample < 5; sample++) {
            samples.add(
              await _time(
                runtime.execute('bad_$turn: int = "x"').result,
                rejected: true,
              ),
            );
          }
          _report('growth', lines, stubs, samples);
        }
      }
    } finally {
      await runtime.dispose();
    }
  });
}

Future<void> _measureGroup(
  Monty pool, {
  required int lines,
  required int stubs,
}) async {
  final rejected = '${_program(lines)}\nbad: int = "x"';
  final runtime = await _runtime(pool, stubs);
  try {
    for (var index = 0; index < 3; index++) {
      await _time(runtime.execute(rejected).result, rejected: true);
    }
    final warm = <double>[];
    for (var index = 0; index < 15; index++) {
      warm.add(await _time(runtime.execute(rejected).result, rejected: true));
    }
    _report('warm', lines, stubs, warm);

    final baseline = <double>[];
    for (var index = 0; index < 15; index++) {
      baseline.add(
        await _time(
          runtime.execute('None', skipTypeCheck: true).result,
          rejected: false,
        ),
      );
    }
    _report('baseline', lines, stubs, baseline);
  } finally {
    await runtime.dispose();
  }

  final cold = <double>[];
  for (var index = 0; index < 5; index++) {
    final fresh = await _runtime(pool, stubs);
    try {
      cold.add(await _time(fresh.execute(rejected).result, rejected: true));
    } finally {
      await fresh.dispose();
    }
  }
  _report('cold', lines, stubs, cold);

  if (lines == 10) {
    final coldAccept = <double>[];
    for (var index = 0; index < 5; index++) {
      final fresh = await _runtime(pool, stubs);
      try {
        coldAccept.add(
          await _time(fresh.execute(_program(lines)).result, rejected: false),
        );
      } finally {
        await fresh.dispose();
      }
    }
    _report('cold-accept', lines, stubs, coldAccept);
  }
}

Future<MontyRuntime> _runtime(Monty pool, int count) async {
  final runtime = await MontyRuntime.start(
    pool: pool,
    typeCheck: true,
    typeCheckStubs: _stubs(count),
    typeCheckFormat: 'json',
  );
  _hostFunctions(count).forEach(runtime.register);

  return runtime;
}

List<HostFunction> _hostFunctions(int count) => [
  for (var index = 0; index < count; index++)
    HostFunction(
      schema: HostFunctionSchema(
        name: 'fn_$index',
        params: const [
          HostParam(name: 'a', type: HostParamType.any),
          HostParam(name: 'b', type: HostParamType.any),
        ],
      ),
      handler: (args, _) async => MontyValue.fromDart({
        'name': args['a']!.dartValue,
        'value': args['b']!.dartValue,
        'kind': 'a',
        'labels': <String>[],
      }),
    ),
];

String _stubs(int count) {
  final records = count ~/ 5;
  final lines = [
    'from typing import Literal, TypedDict',
    "Kind = Literal['a', 'b']",
  ];
  for (var index = 0; index < records; index++) {
    lines.addAll([
      'class Rec_$index(TypedDict):',
      '    name: str',
      '    value: int',
      '    kind: Kind',
      '    labels: list[str]',
    ]);
  }
  for (var index = 0; index < count; index++) {
    lines.add('def fn_$index(a: str, b: int) -> Rec_${index % records}: ...');
  }

  return lines.join('\n');
}

String _program(int count, {String prefix = 'v_'}) {
  final lines = [
    'def ${prefix}sum_values(items: list[int]) -> int:',
    '    total: int = 0',
    '    for item in items:',
    '        total += item',
    '    return total',
  ];
  var index = 0;
  while (lines.length < count) {
    final name = '$prefix$index';
    final remaining = count - lines.length;
    if (remaining >= 3) {
      lines.addAll([
        '$name = fn_${index % 5}("x", $index)',
        '${name}_value: int = $name["value"]',
        '${name}_labels: list[str] = $name["labels"]',
      ]);
    } else {
      lines.add('${name}_plain: int = $index');
    }
    index++;
  }

  return lines.take(count).join('\n');
}

Future<double> _time(
  Future<MontyValue> future, {
  required bool rejected,
}) async {
  final stopwatch = Stopwatch()..start();
  var didReject = false;
  try {
    await future;
  } on MontyTypingError {
    didReject = true;
  } finally {
    stopwatch.stop();
  }
  expect(didReject, rejected);

  return stopwatch.elapsedMicroseconds / 1000;
}

void _report(String kind, int lines, int stubs, List<double> rawSamples) {
  final samples = [for (final sample in rawSamples) _round(sample)]..sort();
  final payload = {
    'kind': kind,
    'lines': lines,
    'stubs': stubs,
    'samples': samples,
    'p50': _percentile(samples, 0.5),
    'p90': _percentile(samples, 0.9),
  };
  // ignore: avoid_print, the TCBENCH line is the benchmark report.
  print('TCBENCH ${jsonEncode(payload)}');
}

double _round(double value) => (value * 10).round() / 10;

double _percentile(List<double> sorted, double percentile) {
  final index = ((sorted.length - 1) * percentile).ceil();

  return sorted.elementAtOrNull(index) ?? double.nan;
}
