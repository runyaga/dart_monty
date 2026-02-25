# Developer Setup

Everything needed to build, test, and contribute to dart\_monty.

## Required Tools

### Dart SDK

Used for the platform interface and FFI packages (M1-M4, pure Dart).

```bash
# macOS
brew install dart-sdk
# or via Flutter (includes Dart)
brew install --cask flutter
```

Verify: `dart --version` (>= 3.5)

### Flutter SDK

Required from M5 onward (Flutter plugin packages). Optional for M1-M4.

```bash
brew install --cask flutter
```

Verify: `flutter --version`

### Rust (via rustup)

Required from M2 onward. The project pins the toolchain in
`native/rust-toolchain.toml` (stable channel + wasm32 target).

```bash
# Install rustup
brew install rustup

# Initialize with stable toolchain
rustup default stable

# WASM target (installed automatically by rust-toolchain.toml)
rustup target add wasm32-wasip1-threads
```

Verify: `rustc --version` (>= 1.91)

**Important:** Do **not** install Homebrew's standalone `rust` formula
(`brew install rust`). It conflicts with rustup by placing a stale
`rustc`/`cargo` in `/opt/homebrew/bin/` that shadows rustup's managed
toolchain. If you have it installed, remove it:

```bash
brew uninstall rust
```

Ensure `~/.cargo/bin` is in your PATH (rustup installs proxy binaries
there). Add to `~/.zprofile`:

```bash
export PATH="$HOME/.cargo/bin:$PATH"
```

### Python 3

Used for developer scripts and linting tools.

```bash
brew install python@3.12
```

Verify: `python3 --version` (>= 3.10)

### pre-commit

Git hook framework that runs linters on every commit.

```bash
pip install pre-commit
# or
brew install pre-commit

# Install hooks in this repo
pre-commit install
```

Verify: `pre-commit --version`

## Linting and Analysis Tools

### pymarkdown

Python-based markdown linter (not markdownlint-cli from npm).

```bash
pip install pymarkdownlnt
```

Verify: `pymarkdown --version`

Usage:

```bash
pymarkdown \
  --set extensions.front-matter.enabled=\$!True \
  --disable-rules MD013,MD024,MD033,MD036,MD041,MD060 \
  scan **/*.md
```

### gitleaks

Secret scanning tool — runs in pre-commit and CI.

```bash
brew install gitleaks
```

Verify: `gitleaks version`

### DCM (Dart Code Metrics)

Commercial Dart analysis tool. Optional for local development
(CI handles it), but useful for deeper analysis.

```bash
# See https://dcm.dev/docs/getting-started/installation/
brew tap nicklockwood/formulae
brew install dcm
```

Verify: `dcm --version`

### cargo-tarpaulin (optional)

Rust code coverage. Required for the M2 coverage gate in CI.
Optional locally — CI runs it.

```bash
cargo install cargo-tarpaulin
```

Verify: `cargo tarpaulin --version`

## LSP / Editor Setup

### Dart / Flutter

- **VS Code:** Install the [Dart](https://marketplace.visualstudio.com/items?itemName=Dart-Code.dart-code)
  and [Flutter](https://marketplace.visualstudio.com/items?itemName=Dart-Code.flutter)
  extensions. The Dart Analysis Server starts automatically.
- **Neovim / other:** Use `dart language-server` or `analysis_server`.

### Rust

- **VS Code:** Install
  [rust-analyzer](https://marketplace.visualstudio.com/items?itemName=rust-lang.rust-analyzer).
  Open `native/` as a workspace folder for best results.
- **Neovim:** `rust-analyzer` via mason or manual install.

Configure `rust-analyzer` to use the `native/` directory:

```json
{
  "rust-analyzer.linkedProjects": ["native/Cargo.toml"]
}
```

## Quick Verification

After installing everything, run these from the repo root:

```bash
# Dart
dart format --set-exit-if-changed .
python3 tool/analyze_packages.py
cd packages/dart_monty_platform_interface && dart pub get && dart test && cd ../..

# Rust
cd native && cargo fmt --check && cargo clippy -- -D warnings && cargo test && cd ..

# Full gate scripts
bash tool/test_platform_interface.sh
bash tool/test_rust.sh
```

## Tool Summary

| Tool | Version | Purpose | Required From |
|------|---------|---------|---------------|
| Dart SDK | >= 3.5 | Dart compilation, analysis, testing | M1 |
| Flutter SDK | >= 3.24 | Flutter plugin testing | M5 |
| Rust (rustup) | >= 1.91 | Native + WASM compilation | M2 |
| Python 3 | >= 3.10 | Developer scripts, linting | M1 |
| pre-commit | any | Git hook automation | M1 |
| pymarkdown | any | Markdown linting | M1 |
| gitleaks | any | Secret scanning | M1 |
| DCM | any | Dart code metrics (optional locally) | M1 |
| cargo-tarpaulin | any | Rust coverage (optional locally) | M2 |
| Node.js | >= 18 | WASM smoke tests (future) | M3 |
| Chrome | headless | Browser integration tests (future) | M3 |
