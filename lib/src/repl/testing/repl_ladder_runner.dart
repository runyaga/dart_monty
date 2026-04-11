import 'dart:convert';
import 'dart:io';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/repl/repl_bindings.dart';
import 'package:test/test.dart';

/// Loads REPL ladder fixture files from [dir], returning sorted tier entries.
List<(String, List<Map<String, dynamic>>)> loadReplLadderFixtures(
  Directory dir,
) {
  final tierFiles =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  return [
    for (final file in tierFiles)
      (
        file.uri.pathSegments.lastOrNull?.replaceAll('.json', '') ?? 'unknown',
        (jsonDecode(file.readAsStringSync()) as List)
            .cast<Map<String, dynamic>>(),
      ),
  ];
}

/// Registers REPL ladder tests for a given backend.
///
/// [createBindings] provides fresh [ReplBindings] for each test.
/// [fixtureDir] points to the directory containing tier JSON files.
void registerReplLadderTests({
  required ReplBindings Function() createBindings,
  required Directory fixtureDir,
}) {
  final tiers = loadReplLadderFixtures(fixtureDir);

  for (final (tierName, fixtures) in tiers) {
    group(tierName, () {
      for (final fixture in fixtures) {
        final name = fixture['name'] as String;
        final id = fixture['id'] as int;

        test('#$id $name', () async {
          if (fixture.containsKey('continuation')) {
            await _runContinuationFixture(createBindings, fixture);
          } else if (fixture.containsKey('feeds')) {
            await _runFeedFixture(createBindings, fixture);
          } else {
            fail('Fixture #$id missing "feeds" or "continuation" key');
          }
        });
      }
    });
  }
}

Future<void> _runFeedFixture(
  ReplBindings Function() createBindings,
  Map<String, dynamic> fixture,
) async {
  final feeds = (fixture['feeds'] as List).cast<Map<String, dynamic>>();
  final repl = MontyRepl.withBindings(bindings: createBindings());

  try {
    for (final feed in feeds) {
      final code = feed['code'] as String;
      final expectError = feed['expectError'] as bool? ?? false;

      if (expectError) {
        try {
          await repl.feed(code);
          fail('Expected error for code: $code');
        } on MontyScriptError catch (e) {
          final errorContains = feed['errorContains'] as String?;
          if (errorContains != null) {
            expect(
              e.message,
              contains(errorContains),
              reason: 'Error message should contain "$errorContains"',
            );
          }
        }
        continue;
      }

      final result = await repl.feed(code);

      if (feed.containsKey('expected')) {
        final expected = feed['expected'];
        final actual = result.value?.dartValue;
        expect(actual, equals(expected), reason: 'After feeding: $code');
      }

      if (feed.containsKey('expectedPrint')) {
        expect(
          result.printOutput,
          feed['expectedPrint'],
          reason: 'Print output after: $code',
        );
      }
    }
  } finally {
    await repl.dispose();
  }
}

Future<void> _runContinuationFixture(
  ReplBindings Function() createBindings,
  Map<String, dynamic> fixture,
) async {
  final source = fixture['continuation'] as String;
  final expectedMode = fixture['expectedMode'] as String;

  final repl = MontyRepl.withBindings(bindings: createBindings());
  try {
    final mode = await repl.detectContinuation(source);
    expect(mode.name, expectedMode, reason: 'For source: $source');
  } finally {
    await repl.dispose();
  }
}
