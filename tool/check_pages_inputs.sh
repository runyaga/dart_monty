#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
python3 - <<'PY'
from pathlib import Path
from html.parser import HTMLParser
from urllib.parse import urlparse
import re

web = Path('example/web/web')
pages = list(web.glob('*.html'))
entries = list(Path('example/web/bin').glob('*.dart'))
assert len(pages) >= 9 and len(entries) >= 8, 'Empty or incomplete demo discovery'
workflow = Path('.github/workflows/pages.yaml').read_text()
assert 'tool/check_demo_pages.sh --build-only' in workflow
assert 'tool/check_demo_pages.sh --smoke-only' in workflow
builder = Path('tool/check_demo_pages.sh').read_text()
assert 'for entry in example/web/bin/*.dart' in builder
assert '--packages=example/web/.dart_tool/package_config.json' in builder
for name in re.findall(r'pip install -r ([\w./-]+)', workflow):
    assert Path(name).is_file(), name
assert 'llmstxt:' in Path('mkdocs.yml').read_text()
assert 'mkdocs-llmstxt' in Path('requirements-docs.lock').read_text()
class Inputs(HTMLParser):
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == 'script' and a.get('src', '').endswith('.dart.js'):
            assert Path('example/web/bin', a['src'].replace('.dart.js', '.dart')).is_file(), a['src']
        if tag == 'a' and 'href' in a:
            u = urlparse(a['href'])
            if u.scheme or not u.path.endswith('.html'): return
            assert (web / u.path).is_file() or Path('docs', u.path.replace('.html', '.md')).is_file(), a['href']
for page in [*pages, web / 'nav.inc']:
    Inputs().feed(page.read_text())
assert len(list(Path('test/fixtures/python_ladder').glob('tier_*.json'))) > 0
assert Path('docs/assets').is_dir()
print(f'PASS — {len(pages)} demo pages, {len(entries)} entry points, shared navigation and build inputs')
PY
