"""Require and fingerprint the hook's actual JIT mount-service code asset."""
import hashlib
import json
from pathlib import Path

manifest = Path('.dart_tool/native_assets.yaml').read_text()
assets = json.loads('\n'.join(line for line in manifest.splitlines()
                              if not line.lstrip().startswith('#')))
key = 'package:dart_monty_core/src/worker/self_relaunch.dart'
matches = [(target, mapping[key])
           for target, mapping in assets['native-assets'].items()
           if key in mapping]
assert len(matches) == 1, 'missing or ambiguous core hook asset'
target, entry = matches[0]
assert entry[0] == 'absolute', 'expected an absolute JIT code asset'
library = Path(entry[1])
assert library.is_absolute() and library.is_file(), entry
identity_file = Path('build/d4b-native-identity.json')
identity = json.loads(identity_file.read_text())
identity['hook_asset'] = {
    'target': target,
    'path': str(library),
    'sha256': hashlib.sha256(library.read_bytes()).hexdigest(),
}
identity_file.write_text(json.dumps(identity, indent=2) + '\n')
print(json.dumps(identity['hook_asset'], indent=2))
