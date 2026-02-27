# =============================================================================
# Charting Playground Runner (Windows)
# =============================================================================
# Copies WASM assets, runs flutter pub get, and launches in Chrome.
#
# Usage: powershell example/charting_playground/run_playground.ps1
# =============================================================================

$ErrorActionPreference = "Stop"

$ROOT = git rev-parse --show-toplevel
$WASM_PKG = Join-Path $ROOT "packages/dart_monty_wasm"
$EXAMPLE = Join-Path $ROOT "example/charting_playground"
$WEB_DIR = Join-Path $EXAMPLE "web"
$PORT = 8089

Write-Host "=== Charting Playground ===" -ForegroundColor Cyan

# ── Step 1: Build JS bridge (if assets missing) ─────────────────────────
$bridgeFile = Join-Path $WASM_PKG "assets/dart_monty_bridge.js"
if (-not (Test-Path $bridgeFile)) {
    Write-Host ""
    Write-Host "--- Building JS bridge ---" -ForegroundColor Yellow
    Push-Location (Join-Path $WASM_PKG "js")
    npm install
    npm run build
    Pop-Location
    Write-Host "  JS build: OK"
}

# ── Step 2: Copy WASM assets to web dir ──────────────────────────────────
Write-Host ""
Write-Host "--- Copying WASM assets ---" -ForegroundColor Yellow
Copy-Item (Join-Path $WASM_PKG "assets/dart_monty_bridge.js") $WEB_DIR
Copy-Item (Join-Path $WASM_PKG "assets/dart_monty_worker.js") $WEB_DIR
Copy-Item (Join-Path $WASM_PKG "assets/wasi-worker-browser.mjs") $WEB_DIR
Copy-Item (Join-Path $WASM_PKG "assets/*.wasm") $WEB_DIR
Write-Host "  Assets copied."

# ── Step 3: Flutter pub get + run ────────────────────────────────────────
Write-Host ""
Write-Host "--- Starting Flutter web app ---" -ForegroundColor Yellow
Push-Location $EXAMPLE
flutter pub get
Write-Host ""
Write-Host "  App: http://localhost:$PORT" -ForegroundColor Green
Write-Host "  Press Ctrl+C to stop." -ForegroundColor Gray
Write-Host ""
flutter run -d chrome --web-port=$PORT
Pop-Location
