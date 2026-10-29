#!/usr/bin/env bash
# Core must resolve from pub.dev. Local gitignored path overrides are allowed.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
python3 - <<'PY'
import re
import subprocess
import sys
import yaml


def has_core_git(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key == 'dart_monty_core' and isinstance(child, dict) and 'git' in child:
                return True
            if key in ('repository', 'url') and isinstance(child, str) and re.search(
                r'(?:github\.com[/:])?[^/]+/dart_monty_core(?:\.git)?(?:$|[ /#])', child
            ) and ('ref' in value or key == 'repository'):
                return True
            if has_core_git(child):
                return True
    elif isinstance(value, list):
        return any(has_core_git(child) for child in value)
    return False


# Cover block and inline dependency syntax and workflow checkout refs.
assert has_core_git(yaml.safe_load('dart_monty_core: {git: {url: https://example.com/core, ref: main}}'))
assert has_core_git({'repository': 'runyaga/dart_monty_core', 'ref': 'main'})
assert has_core_git({'repository': 'https://github.com/runyaga/dart_monty_core', 'ref': 'main'})
assert not has_core_git({'dart_monty_core': '^0.120.0'})

bad = []
for path in subprocess.check_output(['git', 'ls-files', '-z', '*.yaml', '*.yml']).decode().split('\0'):
    if not path:
        continue
    with open(path) as source:
        doc = yaml.load(source, Loader=yaml.BaseLoader)
    if has_core_git(doc):
        bad.append(path)
if bad:
    print('FAIL: dart_monty_core git sources are forbidden: ' + ', '.join(bad))
    sys.exit(1)
print('PASS — no dart_monty_core git refs in tracked YAML.')
PY
