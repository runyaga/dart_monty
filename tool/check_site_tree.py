#!/usr/bin/env python3
"""Inventory every assembled page and reject broken local links/assets."""
from pathlib import Path
from html.parser import HTMLParser
from urllib.parse import unquote, urlparse
import json
import os
import sys

root = Path(sys.argv[1]).resolve()
interactive = {p.name for p in Path('example/web/web').glob('*.html')}
manifest = []
problems = []
class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []
        self.ids = set()
        self.heading = False
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if 'id' in a: self.ids.add(a['id'])
        if tag in ('h1', 'h2'): self.heading = True
        if tag in ('a', 'script', 'link', 'img', 'iframe'):
            self.links.extend(a[k] for k in ('href', 'src') if k in a)

pages = sorted(root.rglob('*.html'))
assert pages, 'Empty assembled site'
import re
meta = json.loads((root / 'build-meta.json').read_text())
pubspec = Path('pubspec.yaml').read_text()
assert meta['runtime'] == re.search(r'^version:\s*(\S+)', pubspec, re.M)[1]
assert meta['coreRef'] == 'hosted'
assert meta['coreVersion'] == '0.120.0'
assert json.loads((root / 'examples.json').read_text()) == json.loads(Path('example/web/web/examples.json').read_text())
for required in ['nav.inc', 'site.css', 'site.js', 'runtime-page.js', 'dart_monty_core_worker.js', 'dart_monty_core_worker.wasm', 'search/search_index.json', 'llms.txt', 'llms-full.txt']:
    assert (root / required).is_file(), f'Missing artifact input: {required}'

parsed = {}
for p in pages:
    text = p.read_text()
    if 'site.js' not in text:
        base = os.path.relpath(root, p.parent).replace(os.sep, '/')
        text = text.replace('</head>', f'<link rel="stylesheet" href="{base}/site.css"><script defer src="{base}/site.js"></script></head>')
        import re
        text = re.sub(r'(<body[^>]*>)', r'\1<div id="site-nav"></div>', text, count=1)
        p.write_text(text)
    doc = Links(); doc.feed(text); parsed[p] = doc
for p, doc in parsed.items():
    relative = p.relative_to(root).as_posix()
    kind = 'executable' if relative in interactive else 'utility' if p.name in ('404.html', 'search.html') else 'reference'
    if kind == 'reference' and not doc.heading: problems.append(f'{relative}: no heading')
    manifest.append(dict(path=relative, kind=kind))
    for link in doc.links:
        u = urlparse(link)
        if u.scheme or u.netloc: continue
        local_path = u.path.removeprefix('/dart_monty') if u.path.startswith('/dart_monty/') else u.path
        dest = (root / unquote(local_path.lstrip('/')) if local_path.startswith('/') else p.parent / unquote(local_path)).resolve() if local_path else p
        if dest.is_dir(): dest /= 'index.html'
        if not dest.is_relative_to(root) or not dest.exists():
            problems.append(f'{relative}: missing {link}')
        elif u.fragment and dest in parsed and unquote(u.fragment) not in parsed[dest].ids:
            problems.append(f'{relative}: missing fragment {link}')
(root / 'page-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
assert not problems, '\n'.join(problems)
print(f'PASS — {len(manifest)} assembled HTML pages classified; local links and fragments resolve')
