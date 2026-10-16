"""Require exact registered/passed D4b IDs, with no skipped or empty cells."""
import argparse
import json
from pathlib import Path


def verify(log, expected):
    starts, done, finished = {}, {}, False
    for line in log.splitlines():
        # Dart's hook progress can precede the first JSON event on its line.
        try:
            event = json.loads(line[line.index('{'):])
        except (ValueError, json.JSONDecodeError):
            continue
        if event.get('type') == 'testStart':
            test = event['test']
            if test['id'] in starts:
                raise ValueError('duplicate registration')
            starts[test['id']] = test
        elif event.get('type') == 'testDone':
            if event['testID'] in done:
                raise ValueError('duplicate completion')
            done[event['testID']] = event
        elif event.get('type') == 'done':
            finished = event['success'] is True
    cases = {key: test for key, test in starts.items()
             if not test['name'].startswith('loading ')
             and not test['name'].endswith(('(setUpAll)', '(tearDownAll)'))}
    names = [test['name'] for test in cases.values()]
    if not finished or len(names) != len(set(names)) or set(names) != set(expected):
        raise ValueError(f'wrong registered IDs: missing={set(expected)-set(names)}, '
                         f'extra={set(names)-set(expected)}, completed={finished}')
    for key, test in cases.items():
        result = done.get(key, {})
        if (test['metadata']['skip'] or result.get('skipped') is not False
                or result.get('result') != 'success' or result.get('hidden')):
            raise ValueError(f'not passed: {test["name"]}')
    return len(cases)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cell', choices=['native', 'native-policy', 'browser'])
    parser.add_argument('log', type=Path)
    args = parser.parse_args()
    manifest = json.loads(Path('tool/d4b-test-ids.json').read_text())
    expected = manifest[args.cell]
    assert expected and len(expected) == len(set(expected))
    count = verify(args.log.read_text(), expected)
    # Bad inputs must never become green evidence.
    for bad in ['', args.log.read_text().replace('"skipped":false', '"skipped":true')]:
        try:
            verify(bad, expected)
        except ValueError:
            pass
        else:
            raise AssertionError('verifier accepted invalid evidence')
    print(f'PASS: exactly {count} registered and passed {args.cell} IDs')


if __name__ == '__main__':
    main()
