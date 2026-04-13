# Installation

Add `dart_monty` to your project:

```bash
dart pub add dart_monty
```

## Quick Start

The fastest way to get started is with `AgentSession`, which provides stateful Python execution and easy plugin support.

```dart
import 'package:dart_monty/dart_monty.dart';

void main() async {
  // 1. Create a stateful session
  final session = AgentSession();

  // 2. Execute Python code
  await session.execute('x = 42');
  final result = await session.execute('x + 1');

  print(result.value); // 43
  
  // 3. Clean up
  await session.dispose();
}
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
