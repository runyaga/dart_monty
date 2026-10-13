#!/usr/bin/env python3
"""Check that every workflow scopes its GITHUB_TOKEN down.

Two rules, each a way the token outlives or outgrows its job:

1. Every workflow under .github/workflows declares a top-level
   `permissions:`, and that block grants no write scope. Without the key a
   job gets the repository's default token, which can be read-write on
   everything. A write a job needs is granted on that job (`jobs.<id>.
   permissions`), so no other job in the file inherits it.

2. Every `actions/checkout` step sets `with: persist-credentials: false`. By
   default checkout writes the token into .git/config, where every later
   step -- a build script, a test, a third-party action -- can read it. A
   job that really pushes with git afterwards is listed in ALLOW below with
   the reason; an ALLOW entry that matches no such checkout is an error, so
   the list cannot outlive the job it excuses.

The files are read with a YAML parser (PyYAML), so anchors, aliases, merge
keys, flow mappings, quoting and escapes mean what they mean to GitHub; a
comment or a look-alike string is never mistaken for a setting. Scans
.github/workflows/*.yml|*.yaml (both rules) and every action.yml|action.yaml
tracked anywhere in the repository (rule 2), including steps nested in a
group of steps. Before the real tree it checks itself
against fixtures that must fail and fixtures that must pass, and it fails
when the tree yields no workflow or no checkout at all, so a scan that stops
finding them is a failure, not a pass.

Needs PyYAML in the python3 that runs it (pip install pyyaml); without it
the check fails, it never skips.

usage: python3 -I tool/check_workflow_tokens.py
Exit 0 on pass, 1 on any finding.
"""

from __future__ import annotations

import re
import sys
import subprocess
import tempfile
from pathlib import Path

try:
    import yaml
except ImportError:  # a missing parser is a failure, never a skip
    print('FAIL: PyYAML is not importable by this python3 (pip install pyyaml).')
    sys.exit(1)

ROOT = Path(__file__).resolve().parent.parent

# Checkouts that keep the token in .git/config, keyed by
# (file name, job id, n) where n counts that job's checkouts from 1.
# Each value is the reason the job needs git credentials after checkout.
ALLOW: dict[tuple[str, str, int], str] = {
}

SCOPE_VALUES = ('read', 'none', 'write')


class Loader(yaml.SafeLoader):
    """PyYAML read the way GitHub reads a workflow (YAML 1.2): only
    true/false are booleans, so `on`, `yes`, `no` and `off` stay distinct
    strings; and a key repeated in one mapping is an error, not a silent
    overwrite that hides the first value."""

    def construct_mapping(self, node, deep=False):
        seen = set()
        for k, _ in node.value:
            if k.tag == 'tag:yaml.org,2002:merge':
                continue
            key = self.construct_object(k, deep=True)
            if key in seen:
                raise yaml.constructor.ConstructorError(
                    None, None, f'duplicate key {key!r}', k.start_mark)
            seen.add(key)
        return super().construct_mapping(node, deep)


Loader.yaml_implicit_resolvers = {
    ch: [(tag, rx) for tag, rx in rs if tag != 'tag:yaml.org,2002:bool']
    for ch, rs in yaml.SafeLoader.yaml_implicit_resolvers.items()}
Loader.add_implicit_resolver(
    'tag:yaml.org,2002:bool', re.compile(r'^(?:true|True|TRUE|false|False|FALSE)$'),
    list('tTfF'))


def top_permissions(name: str, doc: dict) -> list[str]:
    """Rule 1: a top-level `permissions:` that grants no write scope."""
    if 'permissions' not in doc:
        return [f'{name}: no top-level permissions: (add `permissions: contents: read`, '
                'or `permissions: {}`)']
    p = doc['permissions']
    if p == 'read-all' or p == {}:
        return []
    if not isinstance(p, dict):
        return [f'{name}: top-level permissions is {p!r}; use a mapping of read scopes '
                'or {} (grant writes on the job that uses them)']
    bad = [f'{k}: {v!r}' for k, v in p.items() if v not in SCOPE_VALUES]
    if bad:
        return [f'{name}: top-level permissions has unknown values: {", ".join(bad)}']
    writes = sorted(str(k) for k, v in p.items() if v == 'write')
    if writes:
        return [f'{name}: top-level permissions grant write on {", ".join(writes)} '
                '(grant it on the job that uses it)']
    return []


def is_checkout(uses: object) -> bool:
    """`uses:` names the actions/checkout repository, in any case and with
    any action path (`/.`, `/dist/..` resolve to its root), so every spelling
    that could run checkout is held to the rule."""
    if not isinstance(uses, str):
        return False
    if '${{' in uses:  # an expression may evaluate to checkout: held to the rule
        return True
    if '@' not in uses:
        return False
    # The runner splits on either slash and drops empty segments, so
    # `actions//checkout` and `actions\\checkout` are checkout too.
    parts = [x for x in uses.rsplit('@', 1)[0].replace('\\', '/').split('/') if x]
    return len(parts) >= 2 and [x.lower() for x in parts[:2]] == ['actions', 'checkout']


def steps_by_job(doc: dict, is_workflow: bool) -> list[tuple[str, list]]:
    if is_workflow:
        jobs = doc.get('jobs') or {}
        return [(str(j), b.get('steps') or []) for j, b in jobs.items()
                if isinstance(b, dict)]
    runs = doc.get('runs') or {}
    return [('-', runs.get('steps') or [])] if isinstance(runs, dict) else []


def walk(x: object) -> list[dict]:
    """Every mapping under x, in document order: steps, and steps nested in
    any group of steps."""
    if isinstance(x, dict):
        return [x] + [m for v in x.values() for m in walk(v)]
    if isinstance(x, list):
        return [m for v in x for m in walk(v)]
    return []


def checkouts(doc: dict, is_workflow: bool) -> list[tuple[str, int, bool]]:
    """Each checkout as (job id, n within the job, persist-credentials off)."""
    out = []
    for job, steps in steps_by_job(doc, is_workflow):
        n = 0
        for step in walk(steps):
            if not is_checkout(step.get('uses')):
                continue
            n += 1
            w = step.get('with')
            v = w.get('persist-credentials') if isinstance(w, dict) else None
            out.append((job, n, v is False or v == 'false'))
    return out


def check(files: list[tuple[str, str, bool]],
          allow: dict[tuple[str, str, int], str]) -> tuple[int, int, list[str]]:
    """(workflows seen, checkouts seen, findings) over (name, text, is_workflow)."""
    wf, seen, bad, used = 0, 0, [], set()
    for name, text, is_workflow in files:
        try:
            doc = yaml.load(text, Loader=Loader)  # noqa: S506 -- a SafeLoader subclass
        except yaml.YAMLError as e:
            bad.append(f'{name}: not parseable YAML: {e}')
            continue
        if not isinstance(doc, dict):
            bad.append(f'{name}: not a YAML mapping')
            continue
        if is_workflow:
            wf += 1
            bad += top_permissions(name, doc)
        base = name.rsplit('/', 1)[-1]
        for job, n, off in checkouts(doc, is_workflow):
            seen += 1
            key = (base, job, n)
            if key in allow:
                used.add(key)
                if off:
                    bad.append(f'{name}: job {job} checkout #{n} is in ALLOW but already '
                               'sets persist-credentials: false; drop the entry')
                elif not allow[key].strip():
                    bad.append(f'{name}: ALLOW entry for job {job} checkout #{n} has no reason')
                continue
            if not off:
                bad.append(f'{name}: job {job} checkout #{n} lacks '
                           'with: persist-credentials: false')
    for key in sorted(set(allow) - used):
        bad.append(f'ALLOW entry {key} matches no checkout')
    return wf, seen, bad


def manifests(root: Path) -> list[Path]:
    """Every action.yml|action.yaml in the repository: git's tracked files in a
    work tree, else every file under root. A local action runs from wherever a
    checkout put it (`uses: ./src/x` after `path: src`), so it is found by name,
    not by following `uses:`."""
    try:
        out = subprocess.run(
            ['git', '-C', str(root), 'ls-files', '-z', '--', ':(glob)**/action.yml',
             ':(glob)**/action.yaml'], capture_output=True, check=True).stdout
        return [root / x for x in out.decode().split('\0') if x]
    except (OSError, subprocess.CalledProcessError):
        return [p for p in root.rglob('action.y*ml') if p.name in ('action.yml', 'action.yaml')]


def tree(root: Path) -> list[tuple[str, str, bool]]:
    """The workflows (both rules) and every action manifest (rule 2)."""
    found = [(p, True) for p in sorted((root / '.github/workflows').glob('*'))
             if p.suffix in ('.yml', '.yaml')]
    found += [(p, False) for p in sorted(manifests(root))]
    return [(str(p.relative_to(root)), p.read_text(), w) for p, w in found]


CO = 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1'
GOOD = f'''name: x
on: push
permissions:
  contents: read
jobs:
  a:
    permissions:
      pages: write
    steps:
      - uses: {CO} # v7
        with:
          persist-credentials: false
      - name: Second
        # a comment between keys
        uses: {CO}
        with: {{repository: o/r, persist-credentials: false}}
      - {{uses: {CO}, with: {{persist-credentials: false}}}}
  b:
    steps:
      - uses: {CO}
        with:
          persist-credentials: "false"
'''

# Each must yield exactly one finding.
BAD = [
    # no top-level permissions (a job-level one does not count)
    GOOD.replace('permissions:\n  contents: read\n', ''),
    # ... nor one inside a multi-line string
    GOOD.replace('name: x\n', 'name: "x\npermissions: {}\n"\n')
        .replace('permissions:\n  contents: read\n', ''),
    # a write scope at the top, however it is spelled
    GOOD.replace('  contents: read\n', '  contents: write\n'),
    GOOD.replace('  contents: read\n', '  contents: "wr\\u0069te"\n'),
    GOOD.replace('permissions:\n  contents: read\n', 'permissions: write-all\n'),
    GOOD.replace('    permissions:\n      pages: write\n',
                 '    permissions: &w\n      pages: write\n')
        .replace('permissions:\n  contents: read\n', '') + 'permissions: *w\n',
    GOOD.replace('  contents: read\n', '  <<: {contents: write}\n'),
    # a checkout that keeps the token
    GOOD.replace('        with:\n          persist-credentials: false\n', '', 1),
    GOOD.replace('persist-credentials: "false"', 'persist-credentials: true'),
    GOOD.replace('persist-credentials: false}}', 'fetch-depth: 0}}'),
    # ... however the action is spelled
    GOOD.replace('persist-credentials: false}}', 'fetch-depth: 0}}')
        .replace('{uses: actions/checkout@', '{uses: Actions/Checkout@'),
    GOOD.replace('persist-credentials: false}}', 'fetch-depth: 0}}')
        .replace('{uses: actions/checkout@', '{uses: actions/checkout/.@'),
    GOOD.replace('persist-credentials: false}}', 'fetch-depth: 0}}')
        .replace('{uses: actions/checkout@', '{uses: ACTIONS/checkout//@'),
    # a comment, an env var, a nested key or a name is not the input
    GOOD.replace('        with:\n          persist-credentials: "false"\n', '')
        .replace(f'      - uses: {CO}\n', f'      - uses: {CO} # persist-credentials: false\n'),
    GOOD.replace('        with:\n          persist-credentials: "false"',
                 '        env:\n          persist-credentials: "false"'),
    GOOD.replace('          persist-credentials: "false"',
                 '          x:\n            persist-credentials: false'),
    GOOD.replace('with: {persist-credentials: false}}',
                 'name: "with: {persist-credentials: false}"}'),
    GOOD.replace('          persist-credentials: "false"',
                 '          # persist-credentials: false\n          fetch-depth: 0'),
    GOOD.replace('persist-credentials: false}}', 'fetch-depth: 0}}')
        .replace('{uses: actions/checkout@', '{uses: actions/checkout/dist/..@'),
    GOOD.replace('persist-credentials: false}}', 'fetch-depth: 0}}')
        .replace('{uses: actions/checkout@', '{uses: actions//checkout@'),
    GOOD.replace('persist-credentials: false}}', 'fetch-depth: 0}}')
        .replace('{uses: actions/checkout@', '{uses: "actions\\\\checkout@').replace(
            'checkout@3d3c42e5aac5ba805825da76410c181273ba90b1, with: {fetch',
            'checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", with: {fetch'),
    # a checkout behind an expression
    GOOD.replace('persist-credentials: false}}', 'fetch-depth: 0}}').replace(
        '{uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1,',
        '{"us\\u0065s": "${{ \'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\' }}",'),
    # a checkout nested in a group of steps
    GOOD.replace('      - {uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1, with: {persist-credentials: false}}',
                 '      - parallel:\n          - {uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1}'),
    # job ids YAML 1.1 would read as one boolean key are two jobs to GitHub
    GOOD.replace('  b:\n', '  on:\n') + GOOD.split('  b:\n')[1].join(['  yes:\n', ''])
        .replace('persist-credentials: "false"', 'persist-credentials: true'),
]


def self_test() -> str | None:
    r = check([('g.yaml', GOOD, True)], {})
    if r != (1, 4, []):
        return f'a compliant workflow was rejected: {r}'
    for k, text in enumerate(BAD):
        r = check([('b.yaml', text, True)], {})
        if len(r[2]) != 1 or 'YAML' in r[2][0]:
            return f'bad fixture {k} gave {r[2]}, expected exactly one finding'
    dup = GOOD + GOOD.split('  b:\n')[1].join(['  b:\n', ''])
    r = check([('d.yaml', dup, True)], {})
    if len(r[2]) != 1 or 'duplicate key' not in r[2][0]:
        return f'a duplicate job id was not rejected: {r[2]}'
    with tempfile.TemporaryDirectory() as tmp:
        r0 = Path(tmp)
        (r0 / '.github/workflows').mkdir(parents=True)
        (r0 / 'tool/lc').mkdir(parents=True)
        (r0 / '.github/workflows/w.yaml').write_text(
            'permissions: {}\njobs:\n  a:\n    steps:\n      - uses: ./src/tool/lc\n')
        (r0 / 'tool/lc/action.yml').write_text(
            f'runs:\n  using: composite\n  steps:\n    - uses: {CO}\n')
        r = check(tree(r0), {})
        if r[1:] != (1, ['tool/lc/action.yml: job - checkout #1 lacks '
                         'with: persist-credentials: false']):
            return f'an action manifest outside .github/actions was not checked: {r}'
    keep = GOOD.replace('persist-credentials: "false"', 'fetch-depth: 0')
    if check([('k.yaml', keep, True)], {('k.yaml', 'b', 1): 'pushes tags'})[2]:
        return 'an ALLOW entry did not excuse its checkout'
    if len(check([('k.yaml', keep, True)], {('k.yaml', 'b', 1): ' '})[2]) != 1:
        return 'an ALLOW entry without a reason was accepted'
    if len(check([('g.yaml', GOOD, True)], {('g.yaml', 'c', 1): 'gone'})[2]) != 1:
        return 'a stale ALLOW entry was accepted'
    return None


def main() -> int:
    err = self_test()
    if err:
        print(f'FAIL: self-test -- {err}')
        return 1
    wf, seen, bad = check(tree(ROOT), ALLOW)
    if wf == 0 or seen == 0:
        print(f'FAIL: found {wf} workflows and {seen} checkouts under .github -- '
              'the scan is not looking where the workflows are.')
        return 1
    if bad:
        print(f'FAIL: {len(bad)} token-scope findings in {wf} workflows ({seen} checkouts):')
        for b in bad:
            print(f'    {b}')
        print('  Give each workflow `permissions: contents: read` (or `{}`) at the top and')
        print('  grant writes per job; give each checkout `with: persist-credentials: false`,')
        print('  or list it in ALLOW in tool/check_workflow_tokens.py with the reason.')
        return 1
    kept = f', {len(ALLOW)} allowed to keep credentials' if ALLOW else ''
    print(f'PASS -- {wf} workflows scope their token; all {seen} checkouts drop '
          f'credentials{kept}.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
