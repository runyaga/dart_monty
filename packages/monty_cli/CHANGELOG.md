# Changelog

## 0.1.0

- Initial release of `dmonty` CLI.
- `eval` command — evaluate inline Python expressions.
- `run` command — execute Python files.
- `repl` command — interactive REPL with persistent state and slash-commands.
- `demo` command — showcase host function dispatch with built-in functions.
- `--prompt / -p` global option — chain multiple expressions in a single session.
- `--library-path` flag and `MONTY_LIBRARY_PATH` env var for native lib resolution.
- `--json` and `--verbose` output modes.
- `--timeout`, `--memory`, `--stack-depth` resource limit flags with validation.
