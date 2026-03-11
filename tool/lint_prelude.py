#!/usr/bin/env python3
"""Lint pythonPrelude for Monty-unsafe Python patterns.

Usage:
    python3 tool/lint_prelude.py <plugin_dart_file>

Extracts the pythonPrelude string from a MontyPlugin .dart file and checks
for patterns that are NOT supported by the Monty Python subset.

Exit codes:
    0 — No violations found
    1 — Violations found (printed to stdout)
    2 — Could not extract prelude from file
"""

import re
import sys


# Forbidden patterns with human-readable descriptions.
FORBIDDEN = [
    (r'\bfor\s+\w+\s+in\b', 'for-in loop (use while + index)'),
    (r'\brange\s*\(', 'range() (use while + index)'),
    (r'(?<!\w)f"', 'f-string (use str() + concatenation)'),
    (r"(?<!\w)f'", 'f-string (use str() + concatenation)'),
    (r'^\s*import\s+', 'import statement (not available)'),
    (r'^\s*from\s+\w+\s+import\b', 'from-import statement (not available)'),
    (r'\[.*\bfor\b.*\bin\b.*\]', 'list comprehension (use while + append)'),
    (r'\{.*\bfor\b.*\bin\b.*\}', 'dict/set comprehension (not available)'),
    (r'\btry\s*:', 'try block (not available)'),
    (r'\bexcept\b', 'except block (not available)'),
    (r'^\s*class\s+\w+', 'class definition (not available)'),
    (r'\blambda\b', 'lambda (use def instead)'),
    (r'^\s*assert\s+', 'assert (not available)'),
    (r'\btype\s*\(', 'type() (not available)'),
    (r'\bwith\s+\w+', 'with statement (not available)'),
    (r'\*args', '*args (use explicit params)'),
    (r'\*\*kwargs', '**kwargs (use explicit params)'),
    (r'^\s*@\w+', 'decorator (not available)'),
]


def extract_prelude(dart_source: str) -> str | None:
    """Extract the pythonPrelude string from a MontyPlugin Dart source file."""
    # Match: String get pythonPrelude => '''...''';
    # or: String get pythonPrelude => """...""";
    pattern = r"get\s+pythonPrelude\s*=>\s*'''(.*?)'''"
    match = re.search(pattern, dart_source, re.DOTALL)
    if match:
        return match.group(1)

    pattern = r'get\s+pythonPrelude\s*=>\s*"""(.*?)"""'
    match = re.search(pattern, dart_source, re.DOTALL)
    if match:
        return match.group(1)

    return None


def lint_prelude(prelude: str) -> list[tuple[int, str, str]]:
    """Check prelude for forbidden patterns.

    Returns list of (line_number, line_text, violation_description).
    """
    violations = []
    lines = prelude.split('\n')

    for line_num, line in enumerate(lines, start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue

        for pattern, description in FORBIDDEN:
            if re.search(pattern, line):
                violations.append((line_num, stripped, description))
                break  # One violation per line is enough.

    return violations


def main():
    if len(sys.argv) != 2:
        print(f'Usage: {sys.argv[0]} <plugin_dart_file>', file=sys.stderr)
        sys.exit(2)

    with open(sys.argv[1]) as f:
        dart_source = f.read()

    prelude = extract_prelude(dart_source)
    if prelude is None:
        print('ERROR: Could not extract pythonPrelude from file.', file=sys.stderr)
        sys.exit(2)

    if not prelude.strip():
        print('OK: pythonPrelude is empty — nothing to lint.')
        sys.exit(0)

    violations = lint_prelude(prelude)

    if not violations:
        line_count = len([l for l in prelude.split('\n') if l.strip()])
        print(f'OK: pythonPrelude ({line_count} lines) — no Monty-unsafe patterns found.')
        sys.exit(0)

    print(f'FAIL: {len(violations)} Monty-unsafe pattern(s) in pythonPrelude:\n')
    for line_num, line_text, description in violations:
        print(f'  line {line_num}: {description}')
        print(f'    → {line_text}')
        print()

    sys.exit(1)


if __name__ == '__main__':
    main()
