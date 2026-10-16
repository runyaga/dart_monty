#!/usr/bin/env python3
"""Execute focused D5 mutants on VM, never browsers; restore after every probe."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SANDBOX = ROOT / 'lib/src/extensions/sandbox.dart'
RUNTIME = ROOT / 'lib/src/runtime/runtime.dart'
COORDINATOR = ROOT / 'lib/src/extension/coordinator.dart'
FIELDS = ['maxFeedDuration', 'maxTurnDuration', 'maxMemory', 'gcInterval',
          'maxRecursionDepth', 'maxSuspensions', 'maxTotalSleep']
FILES = ['child_context', 'child_limits', 'child_lifecycle',
         'inherited_extension_ownership', 'injected_pool_timeout', 'child_os_policy']


def run(dart, name, pattern, files=None):
    files = files or [f'test/integration/{f}_test.dart' for f in FILES]
    command = [dart, '--suppress-analytics', 'test', '-p', 'vm', '--run-skipped',
               '--timeout', '3s', '--reporter', 'json', *files, '--name', pattern]
    result = subprocess.run(command, cwd=ROOT,
                            env={**os.environ, 'CI': 'true'},
                            text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=120)
    out = ROOT / '.gate-logs/d5-mutants'
    out.mkdir(parents=True, exist_ok=True)
    (out / (name + '.jsonl')).write_text(result.stdout)
    events = []
    for line in result.stdout.splitlines():
        try:
            events.append(json.loads(line))
        except ValueError:
            pass
    tests = {e['test']['id']: e['test']['name'] for e in events
             if e.get('type') == 'testStart' and not e['test']['name'].startswith('loading ')}
    done = [e for e in events if e.get('type') == 'testDone' and e['testID'] in tests]
    assert done and not any(e['skipped'] for e in done), (name, 'missing discovery')
    assert not any(e.get('type') == 'error' and e['testID'] not in tests
                   for e in events), (name, 'compilation/suite failure')
    return {'name': name, 'command': command, 'exit': result.returncode,
            'passed': [tests[e['testID']] for e in done if e['result'] == 'success'],
            'failed': [tests[e['testID']] for e in done if e['result'] != 'success']}


def replace(needle, replacement, count=1):
    def edit(text):
        assert needle in text, needle
        return text.replace(needle, replacement, count)
    return edit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dart', default='dart')
    parser.add_argument('--only', default='.*')
    args = parser.parse_args()
    originals = {p: p.read_text() for p in [SANDBOX, RUNTIME, COORDINATOR]}
    mutations = []
    def add(name, path, edit, pattern):
        mutations.append((name, path, edit, pattern))
    add('D5-RESERVE-LATE', SANDBOX, replace('_children.length + _pendingSpawns', '_children.length'), 'D5-admit-k')
    add('BOUNDS-RELEASE-ON-COMPLETE', SANDBOX,
        replace('_children.length + _pendingSpawns', '_children.values.where((child) => child.isAlive).length + _pendingSpawns'), 'D5-retained-k')
    add('D5-DROP-LATE', RUNTIME,
        replace("      await session.close();\n      throw StateError('Child origin ended during checkout');",
                "      throw StateError('Child origin ended during checkout');"), 'D5-context-late-checkout|D5-timeout-late-close$')
    add('D5-NO-ORIGIN-CANCEL', RUNTIME, replace('      run.token.cancel();\n', ''), 'D5-parent-crash')
    add('D5-NO-ORIGIN-EVENT', RUNTIME, replace('if (run != null && !run.events.isClosed)', 'if (false && run != null && !run.events.isClosed)'), 'D5-context-checkout')
    add('D5-NO-SUB-LIMITS', RUNTIME, replace('    limits: limits,', '    limits: null,'), 'D5-child-subexecute')
    add('D5-NO-CWD', SANDBOX, replace("cwd: '/work',", "cwd: '/',"), 'D5-context-checkout')
    add('D5-NO-STREAM-CLEANUP', SANDBOX,
        lambda s: re.sub(r'onError: \(Object streamError, StackTrace stack\) => unawaited\(.*?\n      \),',
                         'onError: (Object streamError, StackTrace stack) {},', s, count=1, flags=re.S), 'D5-stream-error-no-done')
    add('D5-CLOSE-SKIPS-REST', SANDBOX, replace('/* terminal result remains primary */', 'break;'), 'D5-dispose-throws$')
    add('D5-LOG-SKIPS-CLEANUP', SANDBOX, replace('/* Logging cannot interrupt child ownership. */', 'rethrow;'), 'D5-terminal-log-fault')
    add('D5-REPEAT-CLOSE', SANDBOX, replace('_cleanup ??= _cleanupExecution()', '_cleanupExecution()'), 'D5-free-race')
    add('D5-NO-WAITER-DISPOSE', SANDBOX, replace('      coordinator.disposeAll,\n', ''), 'D5-external-cancel-cleanup')
    add('D5-NO-ATTACH-CLOSE', SANDBOX, replace('    () => session?.close(),\n', ''), 'D5-attach-seed-failure')
    add('D5-NO-BORROW-OWNER', COORDINATOR, replace('_injectCoordinators(owned, this)', '_injectCoordinators(attachOrder, this)'), 'D5-borrow-two-children')
    add('D5-NO-BORROW-LOGGER', COORDINATOR, replace('if (!borrowed.contains(ext))', 'if (true)'), 'D5-borrow-two-children')
    add('D5-DISPOSE-BORROWED', COORDINATOR,
        replace('final owned = disposeOrder\n        .where((ext) => !_borrowed.contains(ext))\n        .toList();', 'final owned = disposeOrder.toList();'), 'D5-borrow-two-children')
    add('D5-NO-LEASE-WAIT', COORDINATOR,
        replace('if ((_leases[ext] ?? 0) > 0)', 'if (false)'), 'D5-borrow-two-children')
    add('D5-PARENT-NO-JOIN', RUNTIME,
        replace('if (pending != null) return pending;', 'if (pending != null) return Future.value();'), 'D5-parent-dispose-close-fault')
    add('D5-PARENT-CLOSE-SKIPS-REST', RUNTIME,
        replace('      _failure ??= error;', '      rethrow;\n      _failure ??= error;'), 'D5-parent-dispose-close-fault')
    add('D5-FIELDWISE-FALLBACK', SANDBOX,
        replace('childLimits ?? (parent is MontyRuntime ? runtimeLimits(parent) : null)',
                '(parent is MontyRuntime ? runtimeLimits(parent) : null) ?? childLimits'), 'D5-explicit-independent')
    add('D5-ESCALATE', SANDBOX,
        replace('requested < 0 || (ceiling != null && requested > ceiling)', 'requested < 0'), 'D5-guest-reject-precheckout')
    add('D5-NEGATIVE', SANDBOX,
        replace('requested < 0 || (ceiling != null && requested > ceiling)', '(ceiling != null && requested > ceiling)'), 'D5-guest-reduce')
    for field in FIELDS:
        def drop(text, field=field):
            return re.sub(r'    '+field+r': [^\n]+,\n', '', text, count=1)
        add('D5-DROP-FIELD-'+field, SANDBOX, drop, 'D5-omitted-whole-object mixed=false')
    def three(text):
        for field in ['maxTurnDuration', 'gcInterval', 'maxSuspensions', 'maxTotalSleep']:
            text = re.sub(r'    '+field+r': [^\n]+,\n', '', text, count=1)
        return text
    add('D5-THREE-LIMITS', SANDBOX, three, 'D5-omitted-whole-object mixed=false')
    add('D5-DROP-ALL-LIMITS', RUNTIME,
        replace('await runtime._checkout(limits: limits)', 'await runtime._checkout()'), 'D5-suspensions|D5-total-sleep')
    add('D5-FORWARD-AUTHORITATIVE', RUNTIME,
        replace('checkout: monty.checkout,', "checkout: ({limits}) => monty.checkout(limits: limits, osPolicy: const OsPolicy(datetime: 'call_host', randomStart: 'call_host')),"), 'D5-system-child$')
    # Timeout refusal must not silently fall back to another transport/pool.
    add('D5-CHILD-FALLBACK', RUNTIME,
        replace('final session = await runtime._checkout(limits: limits);',
                'final session = await runtime._checkout(limits: limits).catchError((Object _) async { final pool = await Monty.start(); return pool.checkout(limits: limits); });'), 'D5-finite-child')
    report = []
    try:
        baseline = run(args.dart, 'baseline', 'D5-')
        report.append(baseline)
        assert baseline['exit'] == 0, baseline['failed']
        for name, path, edit, pattern in mutations:
            if not re.search(args.only, name):
                continue
            changed = edit(originals[path])
            assert changed != originals[path], (name, 'no mutation')
            try:
                path.write_text(changed)
                outcome = run(args.dart, name, pattern)
                report.append(outcome)
                assert outcome['exit'] != 0 and outcome['failed'], name+' survived'
                print(name, 'KILLED', flush=True)
            finally:
                path.write_text(originals[path])
                (ROOT / '.gate-logs/d5-mutants/report.json').write_text(json.dumps(report, indent=2)+'\n')
    finally:
        for path, text in originals.items():
            path.write_text(text)


if __name__ == '__main__':
    main()
