"""Run D4a policy mutants against real sessions; restore each source in finally.

Requires DART_MONTY_WORKER on VM. Does not run browsers or edit baselines.
Each mutant must produce a test assertion failure, not a compilation failure.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = 'lib/src/workspace/workspace.dart'
TRANSFER = 'lib/src/workspace/workspace_transfers.dart'
CAPS = 'test/src/workspace/caps_test.dart'
BOUNDS = 'test/src/workspace/bounds_test.dart'
MIGRATION = 'test/integration/workspace_migration_test.dart'
TRANSFERS = 'test/integration/workspace_transfer_test.dart'


def mutants():
    cases = [
        ('D4a-ROOT-FILE', WORKSPACE,
         [("if (path == '/work') {", "if (false) {")],
         TRANSFERS, 'D4a-root-file'),
        ('D4a-ROOT-FILE-CHECKOUT', WORKSPACE,
         [("if (path == '/work') {", "if (false) {")],
         TRANSFERS, 'D4a-schema-root-file'),
        ('D4a-REFUND', WORKSPACE,
         [('_writeBytes = nextWrites;', "_writeBytes = name == 'Path.unlink' ? 0 : nextWrites;")],
         CAPS, 'D4a-caps-write-lifetime'),
        ('D4a-UTF16', WORKSPACE,
         [('MontyString(:final value) => utf8.encode(value).length,',
           'MontyString(:final value) => value.length,')],
         CAPS, 'D4a-caps-text-vs-bytes'),
        ('D4a-PROTECTED-DESCENDANTS', WORKSPACE,
         [('p.posix.isWithin(path, root)', 'false')],
         TRANSFERS, 'D4a-protected-rename'),
        ('D4a-EARLY-DELETE', WORKSPACE,
         [('await _leaseDone?.future;', 'await Future<void>.value();')],
         TRANSFERS, 'T5-dispose-order'),
        ('D4a-OPEN-ROUTING', 'lib/src/os_call/os_handlers.dart',
         [('operation == PathOp.open && pathHandler != null',
           'operation == "obsolete-open" && pathHandler != null')],
         MIGRATION, 'D4a-open-routing'),
        ('D4a-ASYNC-DECLINE', WORKSPACE,
         [('MontyValue call(', 'FutureOr<MontyValue> call('),
          ('if (!_inside(path)) throw const OsCallNotHandledException();',
           'if (!_inside(path)) return Future.error(const OsCallNotHandledException());')],
         MIGRATION, 'D4a-sync-decline'),
        ('BOUNDS-NULL-DEFAULT', 'lib/src/extensions/sandbox.dart',
         [('this.writeBytesLimit = 8388608', 'this.writeBytesLimit'),
          ('this.memoryUsageLimit = 8388608', 'this.memoryUsageLimit')],
         BOUNDS, 'B-default-caps'),
        ('BOUNDS-PER-FILE', TRANSFER,
         [("    _checkedPath(path, absolute: true);", "    _bytes = 0;\n    _checkedPath(path, absolute: true);")],
         BOUNDS, 'B-transfer-bytes'),
        ('BOUNDS-ALIAS', TRANSFER,
         [('int _bytes = 0;', 'int _bytes = 0;\n  final Set<String> _seenSources = {};'),
          ("final reserved = _statField(stat, 'st_size');",
           "final reserved = _seenSources.add(path) ? _statField(stat, 'st_size') : 0;"),
          ('content.value.length > reserved', 'content.value.length > 8388608')],
         BOUNDS, 'B-transfer-aliases'),
        ('BOUNDS-NO-DEPTH', TRANSFER,
         [('depth > _transferDepth', 'depth > 999')],
         BOUNDS, 'B-transfer-depth'),
        ('BOUNDS-FOLLOW-LINK', TRANSFER,
         [('await _noLinks(source, path);', '// mutation: follow links')],
         BOUNDS, 'B-transfer-symlink'),
        ('BOUNDS-DESTINATION-LINK', TRANSFER,
         [('await _noLinks(parent, entry.destination);',
           '// mutation: trust destination descendants')],
         BOUNDS, 'B-collect-descendant-symlink'),
        ('BOUNDS-NO-ENTRY', TRANSFER,
         [('const _transferEntries = 4096;', 'const _transferEntries = 9999;')],
         BOUNDS, 'B-transfer-entries'),
        ('BOUNDS-NO-PATH', TRANSFER,
         [('const _transferPath = 4096;', 'const _transferPath = 9999;')],
         BOUNDS, 'B-transfer-path'),
        ('BOUNDS-GROWTH', TRANSFER,
         [('content.value.length > reserved', 'content.value.length > 8388608')],
         BOUNDS, 'B-transfer-growth'),
        ('BOUNDS-PARALLEL', TRANSFER,
         [('await previous;', 'await Future<void>.value();')],
         BOUNDS, 'B-transfer-serial'),
    ]
    cases.extend([
        ('D4a-INITIAL-CWD', TRANSFER,
         [("_checkedPath(e.value, absolute: true)",
           "_checkedPath(e.value.startsWith('/') ? e.value : '/${e.value}', absolute: true)")],
         TRANSFERS, 'T1-absolute-cwd'),
        ('D4a-PARTIAL-STAGING', TRANSFER,
         [('await stage.read(sourceReader, source, destination);',
           "await stage.read(sourceReader, source, destination);\n"
           "for (final e in stage.entries) { if (e.bytes case final bytes?) "
           "await parent('Path.write_bytes', [MontyPath(e.destination), MontyBytes(bytes)], {}); }")],
         TRANSFERS, 'D4a-staging-failure'),
        ('D4a-PARENT-FALLTHROUGH', WORKSPACE,
         [('return call(name, args, kwargs);',
           'try { return call(name, args, kwargs); } '
           'on OsCallNotHandledException { return nonFilesystem(name, args, kwargs); }')],
         MIGRATION, 'D4a-no-parent-fs-fallthrough'),
        ('D4a-OLD-STRATEGY-PARAMETER', 'lib/src/extensions/sandbox.dart',
         [('SandboxExtension({', 'SandboxExtension({Object? childVfsStrategy,')],
         'test/surface/facade_compile_test.dart', 'rejects old-strategy-parameter'),
        ('D4a-OLD-STRATEGY-FIELD', 'lib/src/extensions/sandbox.dart',
         [('class SandboxExtension extends MontyExtension {',
           'class SandboxExtension extends MontyExtension { final Object? childVfsStrategy = null;')],
         'test/surface/facade_compile_test.dart', 'rejects old-strategy'),
    ])
    for name in ['ChildVfsStrategy', 'DecoratorHandlers', 'defaultOsHandler',
                 'fsHandler', 'memoryFsHandler', 'overlayFsHandler',
                 'readOnlyHandler', 'envHandler', 'sandboxedFsHandler']:
        declaration = ('typedef ' + name + ' = Object;' if name[0].isupper()
                       else 'void ' + name + '() {}')
        cases.append(('D4a-RESTORE-' + name, 'lib/dart_monty.dart',
                      [("export 'src/runtime/runtime_ref.dart' show HostParentRef;",
                        "export 'src/runtime/runtime_ref.dart' show HostParentRef;\n" + declaration)],
                      'test/public_surface_test.dart', 'exact D4a exported names'))
    return cases



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dart', default='dart')
    parser.add_argument('--only')
    args = parser.parse_args()
    output = ROOT / 'build/d4a-mutations'
    output.mkdir(parents=True, exist_ok=True)
    results = []
    for name, filename, edits, test, case in mutants():
        if args.only and not name.startswith(args.only):
            continue
        source = ROOT / filename
        original = source.read_text()
        mutated = original
        for before, after in edits:
            assert before in mutated, (name, before)
            mutated = mutated.replace(before, after)
        command = [args.dart, 'test', test, '--run-skipped',
                   '--plain-name', case, '--reporter=json']
        try:
            source.write_text(mutated)
            run = subprocess.run(command, cwd=ROOT, capture_output=True, text=True,
                                 timeout=60, env={**os.environ, 'CI': 'true'})
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
