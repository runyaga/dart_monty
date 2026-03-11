#!/usr/bin/env python3
"""Generate JSON report for wrap process test harness.

Usage:
    python3 tool/generate_report.py <package_name> <version> <timestamp> \
        <model> <max_iter> <iter_used> <duration> <status> <run_dir> \
        <iterations_json_file>

Reads iteration data from a JSON file (not inline) to avoid shell quoting.
"""

import json
import sys


def main():
    if len(sys.argv) != 11:
        print(
            f"Usage: {sys.argv[0]} <package_name> <version> <timestamp> "
            "<model> <max_iter> <iter_used> <duration> <status> <run_dir> "
            "<iterations_json_file>",
            file=sys.stderr,
        )
        sys.exit(1)

    (
        package_name,
        version,
        timestamp,
        model,
        max_iter,
        iter_used,
        duration,
        status,
        run_dir,
        iterations_file,
    ) = sys.argv[1:]

    with open(iterations_file) as f:
        iterations = json.load(f)

    report = {
        "package_name": package_name,
        "package_version": version,
        "run_timestamp": timestamp,
        "gemini_model": model,
        "max_iterations": int(max_iter),
        "iterations_used": int(iter_used),
        "total_duration_seconds": int(duration),
        "status": status,
        "run_dir": run_dir,
        "iterations": iterations,
    }

    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
