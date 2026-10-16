#!/usr/bin/env python3
"""Restore every removed D5 name/member and require its negative fixture to fail."""
import argparse
import json
from pathlib import Path
import re
from d5_mutations import run

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dart', default='dart')
    args = parser.parse_args()
    sandbox = ROOT / 'lib/src/extensions/sandbox.dart'
    facade = ROOT / 'lib/dart_monty.dart'
    original = sandbox.read_text()
    barrel = facade.read_text()
    names = ['ChildState', 'ChildRunning', 'ChildCompleted', 'ChildFailed',
             'ChildDisposed', 'ChildSandboxException', 'childrenSignal', 'aliveCountSignal']
    report = []
    try:
        baseline = run(args.dart, 'surface-baseline', 'D5-private-', ['test/surface/facade_compile_test.dart'])
        report.append(baseline)
        assert baseline['exit'] == 0
        for name in names:
            if name[0].isupper():
                sandbox.write_text(re.sub(r'\b_'+name+r'\b', name, original))
                facade.write_text(barrel.replace('show SandboxExtension;', 'show SandboxExtension, '+name+';'))
            else:
                body = ('Object get childrenSignal => _childrenSignal;' if name == 'childrenSignal' else
                        'Object get aliveCountSignal => _children.values.where((child) => child.isAlive).length;')
                sandbox.write_text(original.replace("  String get namespace => 'sandbox';", "  String get namespace => 'sandbox';\n  "+body))
            outcome = run(args.dart, 'D5-RESTORE-'+name, 'rejects D5-private-'+name+'$', ['test/surface/facade_compile_test.dart'])
            report.append(outcome)
            assert outcome['exit'] != 0 and outcome['failed'], name+' survived'
            print(name, 'KILLED', flush=True)
            sandbox.write_text(original)
            facade.write_text(barrel)
    finally:
        sandbox.write_text(original)
        facade.write_text(barrel)
        (ROOT / '.gate-logs/d5-mutants/surface-report.json').write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    main()
