#!/usr/bin/env python3
"""Analyze all sub-packages in packages/ directory."""

import os
import subprocess
import sys


def _is_flutter_package(pubspec_path: str) -> bool:
    """Check if a pubspec.yaml declares a Flutter SDK dependency."""
    with open(pubspec_path) as f:
        content = f.read()
    return 'sdk: flutter' in content


def main() -> int:
    packages_dir = os.path.join(os.path.dirname(__file__), '..', 'packages')
    packages_dir = os.path.abspath(packages_dir)
    failed = []

    for name in sorted(os.listdir(packages_dir)):
        pkg_path = os.path.join(packages_dir, name)
        pubspec = os.path.join(pkg_path, 'pubspec.yaml')
        if not os.path.isfile(pubspec):
            continue

        is_flutter = _is_flutter_package(pubspec)
        pub_cmd = ['flutter', 'pub', 'get'] if is_flutter else ['dart', 'pub', 'get']

        print(f'\n--- Analyzing {name} {"(flutter)" if is_flutter else ""} ---')
        subprocess.run(
            pub_cmd,
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
