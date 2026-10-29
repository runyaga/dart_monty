#!/usr/bin/env python3
"""Derive Pages identity from the package and the resolved core checkout."""
import argparse
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import urljoin, urlparse


def metadata():
    version = re.search(r'^version:\s*(\S+)', Path('pubspec.yaml').read_text(), re.M)[1]
    config = Path('example/web/.dart_tool/package_config.json').resolve()
    packages = json.loads(config.read_text())['packages']
    core = next(p for p in packages if p['name'] == 'dart_monty_core')
    directory = Path(urlparse(urljoin(config.as_uri(), core['rootUri'])).path)
    pin = json.loads((directory / 'tool/upstream/upstream-pin.json').read_text())
    ref = re.search(r'\bref:\s*(\S+)', Path('pubspec.yaml').read_text())[1]
    head = subprocess.check_output(['git', '-C', str(directory), 'rev-parse', 'HEAD'], text=True).strip()
    assert head == ref, f'Resolved checkout {head} differs from pin {ref}'
    lock = Path('example/web/pubspec.lock').read_text()
    assert re.search(r'resolved-ref:\s*["\']?' + re.escape(ref), lock), 'Resolved core differs from declared pin'
    core_version = re.search(r'^version:\s*(\S+)', (directory / 'pubspec.yaml').read_text(), re.M)[1]
    return dict(runtime=version, coreVersion=core_version, coreRef=ref, upstream=pin['version'], upstreamCommit=pin['commit'])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    tier_files = re.findall(r"'([^']+\.json)'", Path('example/web/bin/ladder_showcase.dart').read_text().split('const _tierFiles = [')[1].split('];')[0])
    tier_manifest = Path('example/web/web/ladder-manifest.json')
    if args.check:
        assert json.loads(tier_manifest.read_text()) == tier_files
    else:
        tier_manifest.write_text(json.dumps(tier_files, indent=2) + '\n')
    target = Path('example/web/web/build-meta.json')
    expected = metadata()
    if args.check:
        assert json.loads(target.read_text()) == expected, 'Stale build-meta.json'
    else:
        target.write_text(json.dumps(expected, indent=2) + '\n')
    docs = Path('docs/index.md').read_text().replace('`', '')
    assert expected['runtime'] in docs and 'dart_monty_core ' + expected['coreRef'] in docs
    examples = json.loads(Path('example/web/web/examples.json').read_text())
    ids = [e['id'] for e in examples]
    assert len(ids) == len(set(ids)) and ids
    for e in examples:
        assert all(k in e for k in ('code', 'setup', 'expected', 'pages'))
        assert not re.search(r'\bdel\b|globals\(', e['code'])
        for page in e['pages']:
            assert (Path('example/web/web') / (page + '.html')).exists()
    for page in Path('example/web/web').glob('*.html'):
        if page.stem not in ('visualizer', 'async_matrix', 'ladder'):
            markup = re.sub(r'<script\b[^>]*>.*?</script>|<!--.*?-->', '', page.read_text(), flags=re.S | re.I)
            options = re.findall(r'<option value="([^"]+)">', markup)
            assert options == [e['id'] for e in examples if page.stem in e['pages'] and e['setup'] != 'bridge-walkthrough'], f'{page}: catalog/selector drift'

        text = page.read_text()
        assert 'site.js' in text and 'site.css' in text, f'{page}: missing shared presentation'
        assert not re.search(r'__[A-Z][A-Z_]+__|Monty\.exec|MontyRepl|createPlatformMonty|lib/src/repl/', text), page
    print(f'PASS — metadata {expected}; {sum(not e.get('legacy', False) for e in examples)} exact-output examples; {sum(e.get('legacy', False) for e in examples)} restored walkthrough examples')


if __name__ == '__main__':
    main()
