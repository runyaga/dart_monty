#!/usr/bin/env python3
"""Kill D3 value-erasure, None-default, and widened-signature mutants on VM.

Run check_d3_members.py first to materialize the approved negative fixtures.
Every modified source is restored in finally; no browser is launched.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dart', default='dart')
    args = parser.parse_args()
    logs = ROOT / '.gate-logs/d3-typed-mutants'
    logs.mkdir(parents=True, exist_ok=True)
    paths = ['lib/src/host/schema.dart', 'lib/src/host/param.dart',
             'lib/src/extensions/event_loop.dart', 'lib/src/bridge/bridge.dart',
             'lib/src/bridge/session_bridge.dart', 'lib/src/runtime/runtime.dart']
    originals = {name: (ROOT / name).read_text() for name in paths}
    report = []

    def restore():
        for name, source in originals.items():
            (ROOT / name).write_text(source)

    def replace(path, before, after):
        source = originals[path]
        assert before in source, (path, before)
        (ROOT / path).write_text(source.replace(before, after))

    def run(name, command):
        result = subprocess.run([args.dart, '--suppress-analytics', *command],
                                cwd=ROOT, env={**os.environ, 'CI': 'true'},
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (logs / (name + '.log')).write_text(result.stdout)
        report.append(dict(name=name, command=[args.dart, '--suppress-analytics', *command],
                           exit=result.returncode))
        return result

    tests = ['test', '-p', 'vm', '--run-skipped', '--tags', 'integration',
             'test/integration/typed_host_contract_test.dart', '--name',
             'D3-(absent|explicit|bigint|matrix|default-registration|invalid-default|required-default)']
    assert run('baseline', tests).returncode == 0
    try:
        replace(paths[0], 'raw[params[i].name] = positionalArgs[i];',
                'raw[params[i].name] = MontyValue.fromDart(positionalArgs[i].dartValue);')
        result = run('D3-ERASE', tests)
        assert result.returncode != 0 and 'D3-bigint-dict [E]' in result.stdout
        restore()
        replace(paths[1], '      return value;', '      return defaultValue ?? value;')
        result = run('D3-NONE-DEFAULT', tests)
        assert result.returncode != 0 and 'D3-explicit-none [E]' in result.stdout
        restore()
        signature_cases = [('D3-RAW-PAYLOAD', ['raw-event']),
                           ('D3-WIDE-VALIDATE', ['raw-validate']),
                           ('D3-WIDE-INVOKE', ['raw-invoke', 'raw-bridge-invoke'])]
        for name, fixtures in signature_cases:
            if name == 'D3-RAW-PAYLOAD':
                replace(paths[2], 'void dispatch(MontyDict event) {',
                        'void dispatch(Object raw) { final event = raw as MontyDict;')
            elif name == 'D3-WIDE-VALIDATE':
                replace(paths[1], 'MontyValue validate(MontyValue? value, {bool isPresent = true}) {',
                        'MontyValue validate(Object? raw, {bool isPresent = true}) { final value = raw as MontyValue?;')
            else:
                for path in paths[3:]:
                    replace(path, 'Map<String, MontyValue> args, {', 'Map<String, Object?> args, {')
                session = ROOT / paths[4]
                session.write_text(session.read_text().replace(
                    '_host.invokeHostFunction(name, args, onEvent: onEvent)',
                    '_host.invokeHostFunction(name, args.map((key, value) => MapEntry(key, value as MontyValue)), onEvent: onEvent)'))
            for fixture in fixtures:
                result = run(name + '-' + fixture, ['compile', 'kernel',
                    '--packages=' + str(ROOT / '.dart_tool/package_config.json'),
                    str(ROOT / '.gate-logs/d3-members' / (fixture + '.dart')),
                    '-o', str(logs / (fixture + '.dill'))])
                # The negative unexpectedly compiling is exactly the mutant kill.
                assert result.returncode == 0, result.stdout
                report[-1]['negative_unexpectedly_compiled'] = True
            restore()
    finally:
        restore()
        (logs / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print('KILLED D3-ERASE D3-NONE-DEFAULT D3-RAW-PAYLOAD D3-WIDE-VALIDATE D3-WIDE-INVOKE')


if __name__ == '__main__':
    main()
