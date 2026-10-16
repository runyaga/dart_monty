// Every published demo page must LOAD AND BOOT in a real browser, and every
// web entrypoint must EXECUTE there.
//
// THE GAP THIS CLOSES, MEASURED 2026-09-16 on integration/0.23:
//
//   example/*.dart              4  EXECUTED  (test/integration/example_smoke_test.dart)
//   example/web/bin/*.dart      7  COMPILED ONLY — ci.yaml ran `dart compile js`
//                                  per file and never ran the result
//   example/web/web/*.html      8  NOT EXERCISED AT ALL — nothing loaded them
//
// A demo that compiles can still throw on load, 404 its own `.dart.js`, or
// fail to boot WASM. That is not hypothetical here: async_matrix_demo.dart.js
// returned 404 on the live site while async_matrix.html returned 200, and the
// published site sat stale from 2026-06-02 with every check green — because
// GitHub Pages hides a failed build by continuing to serve the last good one.
//
// WHAT IS ASSERTED, PER PAGE:
//   1. the page raised its boot signal        (example/web/lib/demo_ready.dart)
//   2. no uncaught JS exception, no console error
//   3. no same-origin request answered 4xx/5xx — this is the assertion that
//      would have caught the async_matrix 404
//
// Tagged `demo` and skipped by default: it compiles seven entrypoints and
// drives a browser. Run it through its owner, which builds the site first:
//
//   bash tool/check_demo_pages.sh
//
// Running `dart test test/integration/demo_page_boot_test.dart` directly works
// too, but only against a site that script has already assembled.

// TAGGED `demo` AND DELIBERATELY NOT `integration`. The CI `test-integration`
// job runs `dart test --run-skipped --tags=integration` over the whole suite,
// and this file needs an ASSEMBLED SITE that only tool/check_demo_pages.sh
// builds. Carrying the `integration` tag would break that job on every run.
@Tags(['demo'])
@Timeout(Duration(minutes: 20))
library;

import 'dart:io';

import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'demo_harness.dart';

/// Where `tool/check_demo_pages.sh` assembles the site, mirroring the copy
/// steps in `.github/workflows/pages.yaml`.
const _siteDir = 'build/demo-site';

void main() {
  // DISCOVERED FROM git ls-files, NEVER ENUMERATED. Adding a ninth page or an
  // eighth entrypoint extends this suite automatically, and — because the
  // page must raise a boot signal and every entrypoint must be loaded by a
  // page — it FAILS until it is actually covered. An empty glob throws rather
  // than producing a suite of zero tests that reports success.
  final pages = trackedFiles('example/web/web/*.html');
  final entrypoints = trackedFiles('example/web/bin/*.dart');

  // page path -> the example `<option value>` keys it declares.
  final exampleKeysByPage = <String, List<String>>{
    for (final page in pages) page: exampleKeysIn(page),
  };
  // page path -> the *.dart.js bundles it loads.
  final scriptsByPage = <String, List<String>>{
    for (final page in pages) page: scriptsLoadedBy(page),
  };
  // entrypoint path -> the pages that load its compiled bundle.
  final pagesByEntrypoint = <String, List<String>>{
    for (final entry in entrypoints)
      entry: [
        for (final page in pages)
          if (scriptsByPage[page]!.contains(
            '${p.basenameWithoutExtension(entry)}.dart.js',
          ))
            page,
      ],
  };

  late DemoServer server;
  late Chrome chrome;
  final loads = <String, PageLoad>{};
  // Requests answered while each page was loading, sliced out of the one
  // server log by position. Per-page slicing keeps a 404 attributable.
  final requestsByPage = <String, List<ServedRequest>>{};

  setUpAll(() async {
    final site = Directory(_siteDir);
    if (!site.existsSync()) {
      fail(
        '$_siteDir does not exist. This suite drives the ASSEMBLED site, not '
        'the source tree.\n  Build it first:  bash tool/check_demo_pages.sh',
      );
    }
    // A compile step that silently lost an entrypoint would otherwise present
    // as a page 404ing its script, which reads like a broken page rather than
    // a broken build. Fail at the cause.
    for (final entry in entrypoints) {
      final bundle = p.join(
        _siteDir,
        '${p.basenameWithoutExtension(entry)}.dart.js',
      );
      if (!File(bundle).existsSync()) {
        fail(
          '$bundle is missing — $entry was never compiled into the site.\n'
          '  Rebuild:  bash tool/check_demo_pages.sh',
        );
      }
    }

    final executable = Chrome.locate();
    if (executable == null) {
      // Unreachable in practice: tool/check_demo_pages.sh exits 77 (a VISIBLE
      // gate skip) before it gets here. Kept so a direct `dart test` run says
      // why rather than crashing inside the CDP client.
      fail(
        'No Chrome/Chromium found. Set CHROME_EXECUTABLE, or run this through '
        'tool/check_demo_pages.sh, which skips visibly instead of passing.',
      );
    }

    server = await DemoServer.bind(site.absolute.path);
    chrome = await Chrome.launch(executable);

    for (final page in pages) {
      final name = p.basename(page);
      final before = server.requests.length;
      loads[page] = await chrome.load(name, '${server.origin}/$name');
      requestsByPage[page] = server.requests.sublist(before);
    }
  });

  tearDownAll(() async {
    await chrome.close();
    await server.close();
  });

  group('published page boots in headless Chrome', () {
    for (final page in pages) {
      test(page, () {
        final load = loads[page];
        expect(load, isNotNull, reason: '$page was never loaded');

        // EVERY FAILURE MODE IS REPORTED AT ONCE, not one `expect` per rule.
        //
        // Ordered expects mask each other: a page whose script 404s fails the
        // ready-signal assertion first, and the reader never sees that the
        // CAUSE was a missing asset. That is the exact shape of the bug this
        // gate was built for — async_matrix_demo.dart.js 404'd while its page
        // returned 200 — so the 404 must be visible whenever it happened, not
        // only when it happened alone.
        final problems = <String>[];

        // 1. EVERY same-origin asset resolved. THE async_matrix_demo.dart.js
        //    ASSERTION.
        for (final request in requestsByPage[page]!) {
          if (!request.failed) continue;
          // The unprompted favicon probe is noise: every browser makes it and
          // no published page references one.
          if (request.path.endsWith('/favicon.ico')) continue;
          problems.add('failed request: $request');
        }

        // 2. A REAL READY SIGNAL, not HTTP 200. Every page raises
        //    window.__montyDemoReady once it is genuinely up; see
        //    example/web/lib/demo_ready.dart for why the contract is uniform.
        if (load!.error != null) {
          problems.add('the demo declared a boot failure: ${load.error}');
        }
        if (load.ready == null) {
          problems.add(
            'no boot signal after ${load.elapsed.inSeconds}s — the page never '
            'set window.__montyDemoReady. A page can return 200 and still '
            'throw on load, 404 its own script, or fail to boot WASM.',
          );
        }

        // 3. Nothing the browser itself considered an error.
        problems
          ..addAll(load.exceptions.map((e) => 'uncaught JS: $e'))
          ..addAll(load.consoleErrors);

        // 4. THE DROPDOWN CONTRACT. A page that offers examples must expose
        //    window.__montyRunExample so the gate can drive them, and the set
        //    it offers at RUNTIME must be the set its source declares. Those
        //    two assertions are what stop a changed selector from quietly
        //    reducing coverage to zero while every page still boots.
        final declared = exampleKeysByPage[page]!;
        if (declared.isEmpty) {
          if (load.exampleKeys.isNotEmpty) {
            problems.add(
              'the live page offers examples ${load.exampleKeys} that its '
              'source does not declare — the static parse in exampleKeysIn() '
              'has stopped matching, so the suite is running fewer tests than '
              'there are examples',
            );
          }
        } else {
          if (!load.hasExampleRunner) {
            problems.add(
              'declares ${declared.length} example(s) but exposes no '
              'window.__montyRunExample, so none of them can be run. See the '
              'hook in vfs.html / agent.html.',
            );
          }
          if (load.exampleKeys.isEmpty) {
            problems.add(
              'the runtime option selector matched NOTHING while the source '
              'declares ${declared.length} example(s) — a gate that discovers '
              'zero subjects verifies nothing',
            );
          } else if (!const ListEquality<String>().equals(
            load.exampleKeys,
            declared,
          )) {
            problems.add(
              'the examples offered at runtime ${load.exampleKeys} differ from '
              'the ones declared in source $declared',
            );
          }
        }

        expect(
          problems,
          isEmpty,
          reason:
              '$page did not boot cleanly:\n'
              '${problems.map((e) => '    - $e').join('\n')}\n'
              '${load.describe()}',
        );
      });
    }
  });

  group('demo example runs and the page renders it as a success', () {
    // ONE TEST PER EXAMPLE, derived from the page source. "The page booted"
    // was never enough: vfs.html's open() example was failing on the live site
    // while the page around it came up perfectly clean, and a console-error
    // check cannot see a demo that catches its own error and paints it red.
    for (final page in pages) {
      for (final key in exampleKeysByPage[page]!) {
        test('$page [$key]', () {
          final load = loads[page]!;
          final run = load.examples.firstWhereOrNull((e) => e.key == key);
          expect(
            run,
            isNotNull,
            reason:
                'the "$key" example on $page was never run.\n'
                '${load.describe()}',
          );
          expect(
            run!.ok,
            isTrue,
            reason:
                '$page rendered the "$key" example as a FAILURE.\n'
                '    status: ${run.status}\n'
                '    detail: ${run.detail}\n'
                "  This is the page's own verdict — its status label and its "
                'error node — not a console heuristic.',
          );
        });
      }
    }
  });

  group('web entrypoint executes in the browser', () {
    for (final entry in entrypoints) {
      test(entry, () {
        final name = p.basenameWithoutExtension(entry);
        final hosts = pagesByEntrypoint[entry]!;

        // COMPILING IS NOT RUNNING. ci.yaml compiled all seven of these and
        // executed none, so an entrypoint that threw on its first line was
        // indistinguishable from one that worked. An entrypoint no page
        // loads can only ever be compiled, so that is a failure in itself.
        expect(
          hosts,
          isNotEmpty,
          reason:
              'No published page loads $name.dart.js, so $entry is compiled '
              'and never executed.\n  Either add a page that loads it, or '
              'delete the entrypoint.',
        );

        for (final host in hosts) {
          final load = loads[host]!;
          expect(
            load.ready,
            equals(name),
            reason:
                '$host loads $name.dart.js but its boot signal is '
                '${load.ready ?? '<none>'}, not "$name" — the compiled '
                'entrypoint did not run to its ready point.\n'
                '${load.describe()}',
          );
          // The bundle itself must have been SERVED, not merely referenced.
          final served = requestsByPage[host]!
              .where((r) => r.path.endsWith('/$name.dart.js'))
              .toList();
          expect(
            served,
            isNotEmpty,
            reason: '$host never fetched $name.dart.js at all.',
          );
          expect(
            served.where((r) => r.failed),
            isEmpty,
            reason:
                '$host fetched $name.dart.js and the server could not serve '
                'it: ${served.join(', ')}',
          );
        }
      });
    }
  });

  test('every demo class is covered, and the counts are stated', () {
    // A FLOOR IN THE SUITE ITSELF, on top of tool/assert_test_count.sh. The
    // shell floor catches a harness that registered nothing; this catches the
    // subtler shape — a discovery glob that still matches, but matches less
    // than the repository holds.
    expect(
      pages.length,
      equals(
        Directory('example/web/web')
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.html'))
            .length,
      ),
      reason:
          'git ls-files found ${pages.length} published page(s) but '
          'example/web/web/ holds a different number of .html files. An '
          'untracked page is one that deploys and is never checked.',
    );
    expect(
      entrypoints.length,
      equals(
        Directory('example/web/bin')
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .length,
      ),
      reason: 'an untracked entrypoint is one nothing compiles or runs',
    );
    final exampleCount = exampleKeysByPage.values.fold<int>(
      0,
      (sum, keys) => sum + keys.length,
    );
    expect(
      exampleCount,
      greaterThan(0),
      reason:
          'no page declares a single <option value> example. Either the '
          'dropdowns are gone or exampleKeysIn() has stopped matching; both '
          'turn this suite into a page-load check.',
    );
    // The counts belong in the log, not only in a green tick: a reader of CI
    // output should be able to see HOW MANY demos were covered without
    // reopening the suite.
    // ignore: avoid_print
    print(
      'demo coverage: ${pages.length} published page(s), '
      '${entrypoints.length} web entrypoint(s), '
      '$exampleCount selectable example(s) — all executed',
    );
  });
}
