# Changelog

## 0.1.1

- Remove `libraryPath` parameter from `NativeBindingsFfi` calls (native library now resolved automatically via `@Native` annotations)

## 0.1.0

- Initial implementation: MCP server with `monty_run`, session management tools
- Bridge event adapter (`Stream<BridgeEvent>` to `CallToolResult`)
- Session manager with per-session request serialization
- Stdio transport entry point
- **Host functions**: Register Dart functions as Python-callable host functions and direct MCP tools
- **Plugin system**: `MontyPlugin` base class for grouping related host functions
- **Session persistence**: Fix session state across `monty_session_exec` calls via `MontySession` restore/persist
- **Documentation**: README, 6 docs (client setup, host functions, session persistence, architecture, startup modes, Python subset)
- **Testable examples**: 4 example files with mirror tests in `examples_test.dart`
- **68 unit tests**, integration test suite with 18 host function tests
