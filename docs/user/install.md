# Installation

Add `dart_monty` to your project:

```bash
dart pub add dart_monty
```

## Platform Requirements

### Native (Desktop/Server)
- **macOS, Linux, Windows:** No manual setup. The native binary is automatically downloaded or built.
- **iOS/Android:** Support planned.

### Web (Browser)
Copy the WASM assets to your `web/` directory:

```bash
cp packages/dart_monty_wasm/assets/dart_monty_bridge.js web/
cp packages/dart_monty_wasm/assets/dart_monty_worker.js web/
cp packages/dart_monty_wasm/assets/dart_monty_native.wasm web/
```

**Security Headers:**
Serve your web app with these headers (required for `SharedArrayBuffer`):
- `Cross-Origin-Opener-Policy: same-origin`
- `Cross-Origin-Embedder-Policy: require-corp`
