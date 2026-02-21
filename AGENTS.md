# Agents

Instructions for AI coding agents working on this repository.

## Before Writing Code

1. Read `CLAUDE.md` for project conventions and commands.
2. Read `PLAN.md` for the current milestone and implementation status.
3. Check `docs/milestones/` for detailed requirements of each milestone.

## Validation Workflow

Run these commands from the repository root after every change:

```bash
dart format --set-exit-if-changed .
python3 tool/analyze_packages.py
cd packages/<package_name> && dart test
```

Do not commit unless all three pass with zero errors.

For Rust changes in `native/`, also run:

```bash
cd native
cargo fmt --check
cargo clippy -- -D warnings
cargo test
```

## Package-Level Development

Each sub-package resolves its own dependencies. Always run `dart pub get`
inside the target package directory before running tests or analysis.

```bash
cd packages/dart_monty_platform_interface
dart pub get
dart test
```

## Linting Tools

| Tool | Command | Scope |
|------|---------|-------|
| Dart analyzer | `python3 tool/analyze_packages.py` | All sub-packages |
| DCM | `dcm analyze packages` | All sub-packages |
| Rust fmt | `cd native && cargo fmt --check` | `native/` |
| Rust clippy | `cd native && cargo clippy -- -D warnings` | `native/` |
| Rust tests | `cd native && cargo test` | `native/` |
| Markdown | `pymarkdown scan **/*.md` | All `.md` files |
| Secrets | `gitleaks detect` | Entire repo |

Use `pymarkdown` (Python) for markdown linting. Do not use `markdownlint-cli` (JavaScript/npx).

## Commit Messages

Follow conventional commits with scope:

```text
<type>(<scope>): <description>
```

Types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`

## Architecture Constraints

- Keep `dart_monty_platform_interface` as pure Dart (no Flutter SDK imports).
- Never add `// ignore:` directives to suppress analyzer warnings.
- Resolve warnings by fixing the underlying issue.
- Run `dart format` before committing; the CI enforces `--set-exit-if-changed`.
