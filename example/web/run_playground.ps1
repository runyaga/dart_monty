# =============================================================================
# Web Playground Runner (Windows)
# =============================================================================
# Builds the JS bridge, compiles Dart to JS, starts a COOP/COEP server,
# and opens the playground in your default browser.
#
# Usage: powershell example/web/run_playground.ps1
# =============================================================================

$ErrorActionPreference = "Stop"

$ROOT = git rev-parse --show-toplevel
$WASM_PKG = Join-Path $ROOT "packages/dart_monty_wasm"
$EXAMPLE = Join-Path $ROOT "example/web"
$WEB_DIR = Join-Path $EXAMPLE "web"
$PORT = 8088

Write-Host "=== dart_monty Web Playground ===" -ForegroundColor Cyan

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

# ── Step 2: Copy assets to web dir ───────────────────────────────────────
Write-Host ""
Write-Host "--- Copying assets ---" -ForegroundColor Yellow
Copy-Item (Join-Path $WASM_PKG "assets/dart_monty_bridge.js") $WEB_DIR
Copy-Item (Join-Path $WASM_PKG "assets/dart_monty_worker.js") $WEB_DIR
Copy-Item (Join-Path $WASM_PKG "assets/wasi-worker-browser.mjs") $WEB_DIR
Copy-Item (Join-Path $WASM_PKG "assets/*.wasm") $WEB_DIR
Write-Host "  Assets copied."

# ── Step 3: Compile Dart to JS ───────────────────────────────────────────
Write-Host ""
Write-Host "--- Compiling Dart to JS ---" -ForegroundColor Yellow
Push-Location $EXAMPLE
dart pub get
dart compile js bin/playground.dart -o (Join-Path $WEB_DIR "playground.dart.js")
Write-Host "  Compiled: web/playground.dart.js"
Pop-Location

# ── Step 4: Start COOP/COEP server ──────────────────────────────────────
Write-Host ""
Write-Host "--- Starting server on http://localhost:$PORT ---" -ForegroundColor Yellow

$serverScript = @"
import http.server, functools

class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
        self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()
    def guess_type(self, path):
        if path.endswith('.mjs'): return 'application/javascript'
        if path.endswith('.wasm'): return 'application/wasm'
        return super().guess_type(path)

handler = functools.partial(H, directory='$($WEB_DIR -replace '\\','/')')
http.server.HTTPServer(('127.0.0.1', $PORT), handler).serve_forever()
"@

$serverJob = Start-Job -ScriptBlock {
    param($script)
    python -c $script
} -ArgumentList $serverScript

Start-Sleep -Seconds 1

Write-Host ""
Write-Host "  Playground: http://localhost:$PORT/playground.html" -ForegroundColor Green
Write-Host "  Press Ctrl+C to stop." -ForegroundColor Gray
Write-Host ""

# Open browser
Start-Process "http://localhost:$PORT/playground.html"

# ── Cleanup on exit ──────────────────────────────────────────────────────
try {
    # Wait until Ctrl+C
    while ($true) { Start-Sleep -Seconds 1 }
} finally {
    Write-Host "`n--- Cleaning up ---" -ForegroundColor Yellow
    Stop-Job $serverJob -ErrorAction SilentlyContinue
    Remove-Job $serverJob -Force -ErrorAction SilentlyContinue

    # Remove copied files
    $cleanupFiles = @(
        "dart_monty_bridge.js",
        "dart_monty_worker.js",
        "wasi-worker-browser.mjs",
        "playground.dart.js",
        "playground.dart.js.deps",
        "playground.dart.js.map"
    )
    foreach ($f in $cleanupFiles) {
        $path = Join-Path $WEB_DIR $f
        if (Test-Path $path) { Remove-Item $path }
    }
    # Remove WASM files
    Get-ChildItem (Join-Path $WEB_DIR "*.wasm") -ErrorAction SilentlyContinue |
        Remove-Item -ErrorAction SilentlyContinue

    Write-Host "  Cleaned up."
}
