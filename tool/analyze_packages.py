#!/usr/bin/env python3
"""Analyze all sub-packages in packages/ directory."""

import os
import subprocess
import sys


def main() -> int:
    packages_dir = os.path.join(os.path.dirname(__file__), '..', 'packages')
    packages_dir = os.path.abspath(packages_dir)
    failed = []

    for name in sorted(os.listdir(packages_dir)):
        pkg_path = os.path.join(packages_dir, name)
        pubspec = os.path.join(pkg_path, 'pubspec.yaml')
        if not os.path.isfile(pubspec):
            continue

        print(f'\n--- Analyzing {name} ---')
        subprocess.run(
            ['dart', 'pub', 'get'],
            cwd=pkg_path,
            check=False,
        )
        result = subprocess.run(
            ['dart', 'analyze', '--fatal-infos'],
            cwd=pkg_path,
        )
        if result.returncode != 0:
            failed.append(name)

    if failed:
        print(f'\nFailed packages: {", ".join(failed)}')
        return 1

    print('\nAll packages passed analysis.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
