"""D4b real-library mutation checks; never starts a browser or changes baselines."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
from d4a_mutations import mutants as memory_mutants

ROOT = Path(__file__).resolve().parents[1]
DRIVER = 'lib/src/workspace/workspace_driver.dart'
WORKSPACE = 'lib/src/workspace/workspace.dart'
TRANSFER = 'lib/src/workspace/workspace_transfers.dart'
TEST = 'test/integration/native_workspace_driver_test.dart'
POLICY_TEST = 'test/integration/native_workspace_policy_test.dart'
REVIEW_TEST = 'test/integration/native_workspace_review_test.dart'
IDENTITY_TEST = 'test/integration/native_workspace_identity_test.dart'


def review_mutants():
    return [
        ('D4b-REVIEW-POLICY', WORKSPACE,
         [('if (_disk == null) {\n      return root == path',
           'if (true) {\n      return root == path')],
         REVIEW_TEST, 'N8-policy-'),
        ('D4b-REVIEW-CLEANUP', 'lib/src/workspace/disk_backing_io.dart',
         [('_deleteOwned(Directory(canonical));', '''
    if (FileSystemEntity.typeSync(canonical, followLinks: false) ==
        FileSystemEntityType.link) {
      Link(canonical).deleteSync();
    } else if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }''')], REVIEW_TEST, 'N9-cleanup-'),
        ('D4b-IDENTITY-POLICY', WORKSPACE,
         [('!(_disk?.sameHostEntry(candidate, protected) ?? false)',
           'false')], IDENTITY_TEST, 'native Unicode'),
        ('D4b-IDENTITY-CLEANUP', 'lib/src/workspace/disk_backing_io.dart',
         [('if (!_ownsRoot()) throw retained;', '')],
         IDENTITY_TEST, 'native cleanup replacement'),
        ('D4b-REVIEW-ACCOUNTING', DRIVER,
         [('_writeBytes = previousWrites;', '')],
         REVIEW_TEST, 'N10-write-accounting-'),
    ]


def mutants():
    return [
        ('D4b-OS-ONLY', DRIVER,
         [('current = await _resumeDisk(call, disk);',
           'current = await call.resumeAuto();')], 'N2-intercept-before-mount'),
        ('D4b-SERIAL', DRIVER,
         [('externalLookup: options.externalLookup,', '''externalLookup: {
           for (final e in (options.externalLookup ?? <String, MontyValue>{}).entries)
             e.key: e.value is MontyHostFunction
               ? MontyHostFunction(e.key, (a, k) => (e.value as MontyHostFunction).fn(a, k))
               : e.value,
         },''')], 'N1-snapshot-composition'),
        ('D4b-COLLECT-DELETE', TRANSFER,
         [('workspace._release();', 'workspace._release(); await workspace.dispose();')],
         'N3-native-lifecycle'),
        ('D4b-EARLY-DELETE', WORKSPACE,
         [('await _leaseDone?.future;', 'await Future<void>.value();')], 'N4-dispose-lease'),
        ('D4b-DOUBLE-SLEEP', DRIVER,
         [('final snapshot = await session.feedStart(',
           "await session.feedRun('import time\\ntime.sleep(0.02)');\n"
           'final snapshot = await session.feedStart(')], 'N5-sleep-budget'),
        ('D4b-STOP-CLEANUP', DRIVER,
         [('first ??= error;', 'rethrow;')], 'N6-independent-cleanup'),
        ('D4b-REFUND', WORKSPACE,
         [('_writeBytes = nextWrites;', "_writeBytes = name == 'Path.unlink' ? 0 : nextWrites;")],
         'N-caps-lifetime-and-rejection'),
        ('D4b-OVERLAY', 'lib/src/workspace/persistent_transfer.dart',
         [("mount.mode == 'overlay'", "mount.mode == 'unsupported'")],
         'T-native-overlay-and-read-only-adapters'),
        ('D4b-UNBOUNDED-READ', 'lib/src/workspace/disk_backing_io.dart',
         [('if (size > bytesLeft)', 'if (false)')], 'B-native-direct-bounded-read'),
        ('D4b-UNIQUE-ENTRIES', 'lib/src/workspace/disk_backing_io.dart',
         [('++occurrences > maxEntries', 'entries.length >= maxEntries')],
         'B-native-traversal-occurrences'),
        ('D4b-READONLY-CHECKOUT', 'lib/src/workspace/persistent_transfer.dart',
         [("mount.mode == 'read-only'", "mount.mode == 'unsupported'")],
         'D4a-transfer-capacity'),
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dart', default='dart')
    parser.add_argument('--only')
    args = parser.parse_args()
    output = ROOT / 'build/d4b-mutations'
    output.mkdir(parents=True, exist_ok=True)
    results = []
    cases = [(name, filename, edits, TEST, case)
             for name, filename, edits, case in mutants()]
    cases.extend(review_mutants())
    cases.extend((f'D4b-{name}', filename, edits, POLICY_TEST,
                  f'native bounds {case}')
                 for name, filename, edits, _, case in memory_mutants()
                 if name.startswith('BOUNDS-'))
    for name, filename, edits, test, case in cases:
        if args.only and not name.startswith(args.only):
            continue
        source = ROOT / filename
        original = source.read_text()
        mutated = original
        for before, after in edits:
            assert before in mutated, (name, before)
            mutated = mutated.replace(before, after)
        command = [args.dart, '--suppress-analytics', 'test', test, '--run-skipped',
                   '--plain-name', case, '--reporter=json', '--timeout=5s']
        try:
            source.write_text(mutated)
            run = subprocess.run(command, cwd=ROOT, capture_output=True,
                                 text=True, timeout=60, env=os.environ)
        finally:
            source.write_text(original)
        (output / (name + '.log')).write_text(run.stdout + run.stderr)
        events = []
        for line in run.stdout.splitlines():
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                pass
        failures = [e for e in events if e.get('type') == 'testDone'
                    and e.get('result') in ('failure', 'error')]
        killed = run.returncode != 0 and bool(failures) and not any(
            phrase in run.stdout + run.stderr
            for phrase in ('Failed to load', 'Compilation failed', 'No tests match'))
        results.append({'mutant': name, 'case': case, 'command': command,
                        'exit_code': run.returncode, 'killed': killed})
        print('KILLED' if killed else 'SURVIVED/INVALID', name, flush=True)
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        if not killed:
            raise SystemExit(1)


if __name__ == '__main__':
    main()
