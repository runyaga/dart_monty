#!/usr/bin/env python3
"""Compile the approved D3 fixtures against this clone, leaving design read-only.

D2's curated facade is retained; select only D3 negative cases.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dart', default='dart')
    parser.add_argument('--design', type=Path, required=True,
                        help='read-only design/dm/evidence directory')
    args = parser.parse_args()
    # Exact changed-member golden complements Dart's variance-based fixtures.
    golden = json.loads((ROOT / 'tool/d3-members.json').read_text())
    for file, declarations in golden.items():
        source = re.sub(r'\s+', '', (ROOT / file).read_text())
        for declaration in declarations:
            assert re.sub(r'\s+', '', declaration) in source, (file, declaration)
    print('EXACT D3 MEMBER GOLDEN PASSED', flush=True)
    output = ROOT / '.gate-logs/d3-members'
    output.mkdir(parents=True, exist_ok=True)
    imports = ("import 'dart:async';\n"
               "import 'package:dart_monty/dart_monty.dart';\n")
    positive = (args.design / 'fixtures/member-positive.dart').read_text()
    cases = [('positive', positive, True)]
    for case in json.loads((args.design / 'fixtures/member-negative.json').read_text()):
        if case['phase'] == 'D3':
            cases.append((case['id'], imports + 'void main() {\n' + case['body'] + '\n}\n', False))
    report = []
    for name, source, accepted in cases:
        path = output / (name + '.dart')
        path.write_text(source)
        command = [args.dart, '--suppress-analytics', 'compile', 'kernel',
                   '--packages=' + str(ROOT / '.dart_tool/package_config.json'),
                   str(path), '-o', str(output / (name + '.dill'))]
        result = subprocess.run(command, cwd=ROOT, env={**os.environ, 'CI': 'true'},
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (output / (name + '.log')).write_text(result.stdout)
        assert (result.returncode == 0) == accepted, result.stdout
        if not accepted:
            diagnostics = re.findall(r'^(.+?):\d+:\d+: Error:', result.stdout, re.MULTILINE)
            assert diagnostics and all(Path(p).resolve() == path for p in diagnostics), result.stdout
            assert 'Error when reading' not in result.stdout and 'Not found:' not in result.stdout
        report.append(dict(name=name, accepted=accepted, exit=result.returncode, command=command))
        print(name, 'ACCEPTED' if accepted else 'REJECTED', flush=True)
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
