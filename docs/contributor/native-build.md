# Native Build Hook

The `dart_monty_ffi` package uses Dart's native build hooks (`hook/build.dart`)
to automatically provide the Rust native library at build time. No manual
binary copying or environment variables are needed.

## How It Works

The build hook detects whether you are a **contributor** (have the Rust source)
or a **consumer** (installed via `dart pub add`) and takes the appropriate path.

### Contributor Path

Triggered when `native/Cargo.toml` exists relative to the package root
(i.e. you cloned the full monorepo).

1. Runs `cargo build --release` with the appropriate `--target` triple
2. Copies the built `.dylib`/`.so`/`.dll` to the Dart output directory
3. Registers it as a `CodeAsset` with `DynamicLoadingBundled`

Cargo handles incremental builds internally, so repeated `dart test` runs
only rebuild if Rust source changed (~200ms no-op otherwise).

### Consumer Path

Triggered when `native/Cargo.toml` does **not** exist (typical for pub.dev
consumers who don't have the Rust source).

1. Downloads a pre-built binary from GitHub Releases
2. Uses atomic `.tmp` file + content-length validation to prevent corrupt downloads
3. Registers the downloaded binary as a `CodeAsset`

No Rust toolchain required for consumers.

## Platform Support

| Platform | Status | Details |
|----------|--------|---------|
| macOS (arm64, x64) | Supported | `.dylib` built or downloaded |
| Linux (arm64, x64) | Supported | `.so` built or downloaded |
| Windows (arm64, x64) | Supported | `.dll` built or downloaded |
| iOS | Skipped | Hook returns early; future PR |
| Android | Skipped | Hook returns early; future PR |
| Web/WASM | N/A | Handled by `dart_monty_web` package |

## GitHub Releases Binary Naming

Pre-built binaries are hosted on GitHub Releases with tag `native-lib-v<version>`.
The naming convention is:

```text
libdart_monty_native-macos-arm64.dylib
libdart_monty_native-macos-x64.dylib
libdart_monty_native-linux-arm64.so
libdart_monty_native-linux-x64.so
dart_monty_native-windows-arm64.dll
dart_monty_native-windows-x64.dll
```

The version in `hook/build.dart` (`_version = '0.8.0'`) must match the
GitHub Release tag (`native-lib-v0.8.0`).

## Contributor Setup

```bash
git clone https://github.com/runyaga/dart_monty.git
cd dart_monty/packages/dart_monty_ffi
dart pub get
dart test  # cargo build runs automatically via the hook
```

Prerequisites: Rust toolchain (`rustup`, `cargo`).

## Consumer Setup

```bash
dart pub add dart_monty_ffi
dart test  # binary downloads automatically from GitHub Releases
```

No Rust toolchain needed.

## Troubleshooting

### cargo build fails

The build hook now prints both `stdout` and `stderr` from cargo. Check:
- Is `cargo` on your PATH? (`which cargo`)
- Is the Rust toolchain installed? (`rustup show`)
- Are cross-compilation targets installed? (`rustup target list --installed`)

### Download fails (consumer)

- Check your network connection and firewall/proxy settings
- Verify the release exists: `https://github.com/runyaga/dart_monty/releases/tag/native-lib-v0.8.0`
- Corrupt `.tmp` files are automatically cleaned up; re-run the build

### Stale hook cache

If the hook behaves unexpectedly after code changes:

```bash
rm -rf .dart_tool/hooks_runner/
dart test  # forces hook recompilation
```
