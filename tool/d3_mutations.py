#!/usr/bin/env python3
"""Run D3 limit mutants, restoring the implementation even on failure.

With --real, also require SUB-DROP-LIMITS to fail both nested enforcement
cases. DART_MONTY_WORKER must name the pinned native worker for that run.
No browsers are launched. Logs and exact commands go under .gate-logs.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / 'lib/src/runtime/runtime.dart'
FIELDS = ['maxFeedDuration', 'maxTurnDuration', 'maxMemory', 'gcInterval',
          'maxRecursionDepth', 'maxSuspensions', 'maxTotalSleep']


def run(dart, name, pattern):
    command = [dart, '--suppress-analytics', 'test', '-p', 'vm',
               '--run-skipped', '--tags', 'integration', '--reporter', 'json',
               'test/integration/sub_execution_limits_test.dart',
               '--name', pattern]
    result = subprocess.run(command, cwd=ROOT, env={**os.environ, 'CI': 'true'},
                            text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=180)
    log = ROOT / '.gate-logs/d3-mutants' / (name + '.jsonl')
    log.parent.mkdir(parents=True, exist_ok=True)
    log.write_text(result.stdout)
    events = []
    for line in result.stdout.splitlines():
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    tests = {e['test']['id']: e['test']['name'] for e in events
             if e.get('type') == 'testStart' and 'D3-sub-' in e['test']['name']}
    done = [e for e in events if e.get('type') == 'testDone'
            and e['testID'] in tests]
    assert done and not any(e['skipped'] for e in done), (name, 'no discovery')
    assert not any(e.get('type') == 'error' and e['testID'] not in tests
                   for e in events), (name, 'compilation or suite failure')
    return dict(name=name, command=command, exit=result.returncode,
                passed=[tests[e['testID']] for e in done if e['result'] == 'success'],
                failed=[tests[e['testID']] for e in done if e['result'] != 'success'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dart', default='dart')
    parser.add_argument('--real', action='store_true')
    args = parser.parse_args()
    original = RUNTIME.read_text()
    needle = 'final session = await _checkout(limits: _limits);'
    assert original.count(needle) == 1
    field_pattern = 'D3-sub-seven-fields'
    report = [run(args.dart, 'baseline', field_pattern)]
    assert report[-1]['exit'] == 0 and len(report[-1]['passed']) == 4
    mutations = {'SUB-DROP-LIMITS': 'final session = await _checkout();'}
    keep_three = ['maxFeedDuration', 'maxMemory', 'maxRecursionDepth']
    for name, fields in [('SUB-THREE-FIELDS', keep_three)] + [
        ('SUB-DROP-FIELD-' + field, [f for f in FIELDS if f != field])
        for field in FIELDS
    ]:
        members = ', '.join(f'{f}: _limits?.{f}' for f in fields)
        mutations[name] = f'final session = await _checkout(limits: ResourceLimits({members}));'
    try:
        for name, replacement in mutations.items():
            RUNTIME.write_text(original.replace(needle, replacement))
            outcome = run(args.dart, name, field_pattern)
            assert outcome['exit'] != 0 and outcome['failed'], name + ' survived'
            report.append(outcome)
            print(name, 'KILLED', flush=True)
        if args.real:
            RUNTIME.write_text(original)
            baseline = run(args.dart, 'baseline-real', 'D3-sub-(suspension|sleep)-limit')
            assert baseline['exit'] == 0 and len(baseline['passed']) == 4
            report.append(baseline)
            RUNTIME.write_text(original.replace(needle, mutations['SUB-DROP-LIMITS']))
            real = run(args.dart, 'SUB-DROP-LIMITS-real', 'D3-sub-(suspension|sleep)-limit')
            assert real['exit'] != 0 and len(real['failed']) == 4
            report.append(real)
    finally:
        RUNTIME.write_text(original)
        (ROOT / '.gate-logs/d3-mutants/report.json').write_text(
            json.dumps(report, indent=2) + '\n')
    assert RUNTIME.read_text() == original


if __name__ == '__main__':
    main()
