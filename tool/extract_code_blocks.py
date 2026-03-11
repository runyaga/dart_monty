#!/usr/bin/env python3
"""Extract fenced Dart code blocks from LLM markdown output.

Usage:
    python3 tool/extract_code_blocks.py <response_file> <plugin_out> <test_out>

Looks for ```dart code blocks. Identifies plugin vs test by content heuristics:
- Contains 'extends MontyPlugin' → plugin file
- Contains "import 'package:test/" → test file
- Filename hints in code fence (```dart:foo_plugin.dart) also used

Exits 0 if both files extracted, 1 if plugin missing, 2 if test missing.
"""

import re
import sys


def extract_blocks(text: str) -> list[tuple[str, str]]:
    """Return list of (hint, code) tuples from fenced code blocks."""
    pattern = r'```dart(?::([^\n]*))?[ \t]*\n(.*?)```'
    matches = re.findall(pattern, text, re.DOTALL)
    return [(hint.strip(), code.strip()) for hint, code in matches]


def classify(blocks: list[tuple[str, str]]) -> tuple[str | None, str | None]:
    """Classify blocks into plugin source and test source."""
    plugin_src = None
    test_src = None

    for hint, code in blocks:
        hint_lower = hint.lower()

        # Filename hint classification
        if 'test' in hint_lower:
            test_src = code
            continue
        if 'plugin' in hint_lower and 'test' not in hint_lower:
            plugin_src = code
            continue

        # Content heuristic classification
        if "extends MontyPlugin" in code:
            plugin_src = code
        elif "import 'package:test/" in code or 'import "package:test/' in code:
            test_src = code

    # Handle single-block-concatenated case (LLM put both files in one block).
    if len(blocks) == 1 and plugin_src is None and test_src is None:
        _, code = blocks[0]
        test_markers = [
            "import 'package:test/test.dart';",
            'import "package:test/test.dart";',
        ]
        for marker in test_markers:
            if marker in code:
                parts = code.split(marker, 1)
                potential_plugin = parts[0].strip()
                potential_test = marker + parts[1]
                if 'extends MontyPlugin' in potential_plugin:
                    plugin_src = potential_plugin
                    test_src = potential_test.strip()
                    break

    # Fallback: if exactly 2 blocks and one is unclassified
    if len(blocks) == 2:
        if plugin_src is None and test_src is not None:
            other = [c for _, c in blocks if c != test_src]
            if other:
                plugin_src = other[0]
        elif test_src is None and plugin_src is not None:
            other = [c for _, c in blocks if c != plugin_src]
            if other:
                test_src = other[0]
        elif plugin_src is None and test_src is None:
            # Guess: first block is plugin, second is test
            plugin_src = blocks[0][1]
            test_src = blocks[1][1]

    return plugin_src, test_src


def main():
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <response_file> <plugin_out> <test_out>",
              file=sys.stderr)
        sys.exit(3)

    response_file, plugin_out, test_out = sys.argv[1], sys.argv[2], sys.argv[3]

    with open(response_file) as f:
        text = f.read()

    blocks = extract_blocks(text)
    if not blocks:
        print("ERROR: No ```dart code blocks found in response.", file=sys.stderr)
        sys.exit(1)

    plugin_src, test_src = classify(blocks)

    exit_code = 0
    if plugin_src:
        with open(plugin_out, 'w') as f:
            f.write(plugin_src + '\n')
        print(f"OK: Plugin written to {plugin_out} ({len(plugin_src)} chars)")
    else:
        print("ERROR: Could not identify plugin code block.", file=sys.stderr)
        exit_code = 1

    if test_src:
        with open(test_out, 'w') as f:
            f.write(test_src + '\n')
        print(f"OK: Test written to {test_out} ({len(test_src)} chars)")
    else:
        print("ERROR: Could not identify test code block.", file=sys.stderr)
        exit_code = max(exit_code, 2)

    sys.exit(exit_code)


if __name__ == '__main__':
    main()
