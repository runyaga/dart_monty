#!/usr/bin/env python3
"""Derive Pages identity from the package and the resolved core package."""
import argparse
import json
from pathlib import Path
import re
from urllib.parse import urljoin, urlparse
from urllib.request import url2pathname


def metadata():
    version = re.search(r'^version:\s*(\S+)', Path('pubspec.yaml').read_text(), re.M)[1]
    config = Path('example/web/.dart_tool/package_config.json').resolve()
    packages = json.loads(config.read_text())['packages']
    core = next(p for p in packages if p['name'] == 'dart_monty_core')
    # url2pathname: `/C:/...` is not a usable path on Windows.
    directory = Path(url2pathname(urlparse(urljoin(config.as_uri(), core['rootUri'])).path))
    core_version = re.search(r'^version:\s*(\S+)', (directory / 'pubspec.yaml').read_text(), re.M)[1]
    # Release provenance is recorded here because hosted core omits tool/.
    assert core_version == '0.120.0', f'Update release provenance for core {core_version}'
    import yaml
    lock = yaml.safe_load(Path('example/web/pubspec.lock').read_text())
    resolved = lock['packages']['dart_monty_core']
    assert resolved['source'] in ('hosted', 'path'), resolved
    assert resolved['version'] == core_version, resolved
    return dict(runtime=version, coreVersion=core_version, coreRef='hosted',
                upstream='1.2.0', upstreamCommit='e8db9aef41aa73f4f709c15a4bc8a2d198be5ead')



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
    assert expected['runtime'] in docs and 'dart_monty_core ' + expected['coreVersion'] in docs
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
