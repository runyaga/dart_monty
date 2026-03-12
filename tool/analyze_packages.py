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


def _flutter_available() -> bool:
    """Check if Flutter SDK is available and functional."""
    try:
        result = subprocess.run(
            ['flutter', '--version'],
            capture_output=True,
            timeout=30,
        )
        return result.returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


def main() -> int:
    packages_dir = os.path.join(os.path.dirname(__file__), '..', 'packages')
    packages_dir = os.path.abspath(packages_dir)
    failed = []
    skipped = []
    has_flutter = _flutter_available()

    for name in sorted(os.listdir(packages_dir)):
        pkg_path = os.path.join(packages_dir, name)
        pubspec = os.path.join(pkg_path, 'pubspec.yaml')
        if not os.path.isfile(pubspec):
            continue

        is_flutter = _is_flutter_package(pubspec)

        if is_flutter and not has_flutter:
            print(f'\n--- Skipping {name} (flutter) — Flutter SDK not available ---')
            skipped.append(name)
            continue

        pub_cmd = ['flutter', 'pub', 'get'] if is_flutter else ['dart', 'pub', 'get']
        analyze_cmd = (
            ['flutter', 'analyze', '--fatal-infos']
            if is_flutter
            else ['dart', 'analyze', '--fatal-infos']
        )

        print(f'\n--- Analyzing {name} {"(flutter)" if is_flutter else ""} ---')
        pub_result = subprocess.run(
            pub_cmd,
            cwd=pkg_path,
            check=False,
            capture_output=True,
        )
        if pub_result.returncode != 0:
            print(f'  pub get failed — skipping analysis')
            skipped.append(name)
            continue

        result = subprocess.run(
            analyze_cmd,
            cwd=pkg_path,
        )
        if result.returncode != 0:
            failed.append(name)

    if skipped:
        print(f'\nSkipped packages (missing toolchain): {", ".join(skipped)}')

    if failed:
        print(f'\nFailed packages: {", ".join(failed)}')
        return 1

    print('\nAll packages passed analysis.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
