#!/usr/bin/env python3
"""Print dart_monty_core's package root, as resolved by a package_config.json.

Usage: python3 tool/core_root.py PACKAGE_CONFIG

Works for hosted, git and path dependencies (`dart pub cache dir` was removed
in newer SDKs). Prints nothing when the config or the package is missing, so
the caller reports that itself.

rootUri is resolved against the config file, because a path dependency's is
relative to it. url2pathname turns the URL path into a native one: on Windows
the bare URL path is `/C:/...`, which is not a usable path.
"""
import json
from pathlib import Path
import sys
from urllib.parse import urljoin, urlparse
from urllib.request import url2pathname


def core_root(config_path):
    """dart_monty_core's root directory, or None when it is not resolved."""
    config = Path(config_path).resolve()
    try:
        packages = json.loads(config.read_text())['packages']
    except OSError:
        return None
    core = next((p for p in packages if p['name'] == 'dart_monty_core'), None)
    if core is None:
        return None
    return Path(url2pathname(urlparse(urljoin(config.as_uri(), core['rootUri'])).path))


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit('usage: python3 tool/core_root.py PACKAGE_CONFIG')
    root = core_root(sys.argv[1])
    if root is not None:
        print(root)
