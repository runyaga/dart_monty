"""Opt the CI root into core's hook, retaining the shared package artifacts."""
import hashlib
import json
from pathlib import Path
import subprocess
from urllib.parse import unquote, urljoin, urlparse

config = Path('.dart_tool/package_config.json').resolve()
package = next(p for p in json.loads(config.read_text())['packages']
               if p['name'] == 'dart_monty_core')
root = Path(unquote(urlparse(urljoin(config.as_uri(), package['rootUri'])).path))
identity = {}
lock = Path('pubspec.lock').read_text()
# package_config identifies the installed package; pub records the resolved pin.
resolved = next(line.split(':', 1)[1].strip().strip('"')
                for line in lock.split('\n  dart_monty_core:\n', 1)[1].splitlines()
                if 'resolved-ref:' in line)
identity['core_pin'] = resolved
identity['dm_commit'] = subprocess.check_output(
    ['git', 'rev-parse', 'HEAD'], text=True).strip()
for name in ('dart_monty_worker', 'libdart_monty_worker.so'):
    delivered = Path('.worker') / name
    installed = root / 'lib/src/bin/linux-x64' / name
    assert delivered.is_file() and installed.is_file(), name
    digest = hashlib.sha256(installed.read_bytes()).hexdigest()
    assert digest == hashlib.sha256(delivered.read_bytes()).hexdigest(), name
    identity[name] = {'path': str(installed), 'sha256': digest}
Path('build').mkdir(exist_ok=True)
Path('build/d4b-native-identity.json').write_text(json.dumps(identity, indent=2) + '\n')
pubspec = Path('pubspec.yaml')
text = pubspec.read_text()
assert '\nhooks:' not in text, 'review existing hook configuration explicitly'
pubspec.write_text(text.rstrip() + '''

# D4b disk job: build the mount-service code asset from the reviewed core pin.
hooks:
  user_defines:
    dart_monty_core:
      build_worker: true
''')
print(json.dumps(identity, indent=2))
