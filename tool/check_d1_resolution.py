#!/usr/bin/env python3
"""Verify frozen deferred identities against actual package:test JSON cells.

No browser is launched. Each cell is a directory named vm, dart2js or dart2wasm
under --results. Every mapped assertion must have a non-skipped successful leaf
result in every applicable cell. --progress reports partial VM port evidence;
it is not the D5 completion gate.
"""
import argparse
import hashlib
import json
from pathlib import Path

# Filled from registration-only discovery at dm main 2f7befd. Includes the six
# browser demo cases, so the clone has 102 identities against historical 96.
FROZEN_SHA256 = '9e35f709f8109ed20b5cdc354597545f9d7c9f16fc666c4b66767fb14012db95'


def identity_hash(tests):
    return hashlib.sha256('\n'.join(sorted(t['id'] for t in tests)).encode()).hexdigest()


def load_results(directory):
    passed = set()
    failed = set()
    for path in directory.rglob('*.json*'):
        suites, tests = {}, {}
        for line in path.read_text().splitlines():
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if not isinstance(event, dict):
                continue
            kind = event.get('type')
            if kind == 'suite':
                suites[event['suite']['id']] = event['suite']['path']
            elif kind == 'testStart':
                tests[event['test']['id']] = event['test']
            elif kind == 'testDone' and event['testID'] in tests:
                test = tests[event['testID']]
                if test['name'].startswith('loading ') or event.get('hidden'):
                    continue
                identity = suites[test['suiteID']]+'::'+test['name']
                if event['result'] == 'success' and not event['skipped']:
                    passed.add(identity)
                else:
                    failed.add(identity)
    # A later passing rerun cannot erase a failure inside the same evidence cell.
    return passed - failed


def verify(manifest, results, progress=False):
    tests = manifest['tests']
    assert len(tests) == 102 and len({t['id'] for t in tests}) == 102, 'frozen identities missing or duplicated'
    assert identity_hash(tests) == FROZEN_SHA256, 'frozen identity changed (equal count is insufficient)'
    cells = {backend: load_results(results / backend) for backend in ['vm', 'dart2js', 'dart2wasm']}
    missing = []
    for test in tests:
        if not test['assertions']:
            missing.append(test['id']+' [unported]')
            continue
        for backend in (['vm'] if progress else test['backends']):
            for assertion in test['assertions']:
                if assertion not in cells[backend]:
                    missing.append(test['id']+' ['+backend+': '+assertion+']')
    if not progress:
        assert not missing, '\n'.join(missing)
    return missing


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--results', type=Path, required=True)
    parser.add_argument('--progress', action='store_true')
    args = parser.parse_args()
    try:
        missing = verify(json.loads(args.manifest.read_text()), args.results, args.progress)
        print(json.dumps({'complete': not missing, 'progress_only': args.progress, 'missing': missing}, indent=2))
    except (AssertionError, KeyError) as error:
        print('FAIL:', error)
        raise SystemExit(1)


if __name__ == '__main__':
    main()
