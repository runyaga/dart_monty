#!/usr/bin/env node
/**
 * build.js — Bundles dart_monty_core JS bridge and Worker.
 *
 * Direct C-ABI — zero npm runtime dependencies at runtime.
 *
 * 1. esbuild worker_src.js + wasm_glue.js → ../assets/dart_monty_core_worker.js (ESM)
 * 2. esbuild bridge.js → ../assets/dart_monty_core_bridge.js (IIFE)
 * 3. Copy dart_monty_core_native.wasm from native/target/ → ../assets/
 * 4. Run wasm-opt -Oz (if available)
 *
 * Directory layout (relative to this file at dart_monty_core/js/build.js):
 *   ../assets/  → dart_monty_core/assets/
 *   ../native/  → dart_monty_core/native/
 */

const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const ASSETS = path.resolve(__dirname, '..', 'assets');
// dart_monty_core/js/build.js → one level up = dart_monty_core/native/
const NATIVE_TARGET = path.resolve(
  __dirname, '..', 'native', 'target',
  'wasm32-wasip1', 'release',
);
const WASM_NAME = 'dart_monty_native.wasm';

// Ensure assets directory exists
fs.mkdirSync(ASSETS, { recursive: true });

// Step 1: Bundle Worker (ESM) — includes wasm_glue.js via import
console.log('[build] Bundling worker (C-ABI)...');
execSync(
  `npx esbuild src/worker_src.js ` +
    `--bundle --format=esm ` +
    `--outfile=${path.join(ASSETS, 'dart_monty_worker.js')} ` +
    `--platform=browser ` +
    `--external:*.wasm ` +
    `--log-level=warning`,
  { cwd: __dirname, stdio: 'inherit' },
);

// Step 2: Bundle bridge (IIFE)
console.log('[build] Bundling bridge...');
execSync(
  `npx esbuild src/bridge.js ` +
    `--bundle --format=iife ` +
    `--outfile=${path.join(ASSETS, 'dart_monty_bridge.js')} ` +
    `--platform=browser ` +
    `--log-level=warning`,
  { cwd: __dirname, stdio: 'inherit' },
);

// Step 3: Copy WASM binary from native build
console.log('[build] Copying WASM binary...');
const wasmSrc = path.join(NATIVE_TARGET, WASM_NAME);
const wasmDst = path.join(ASSETS, WASM_NAME);

if (!fs.existsSync(wasmSrc)) {
  console.error(
    `[build] FATAL: ${wasmSrc} not found.\n` +
      `  Run: cd native && cargo build --release --target wasm32-wasip1`,
  );
  process.exit(1);
}

fs.copyFileSync(wasmSrc, wasmDst);
const sizeMB = (fs.statSync(wasmDst).size / 1024 / 1024).toFixed(1);
console.log(`  Copied ${WASM_NAME} (${sizeMB} MB)`);

// Step 4: Optimize with wasm-opt (optional — skip if not installed)
try {
  const wasmOptDst = wasmDst + '.opt';
  execSync(
    `wasm-opt -Oz ` +
      `--enable-bulk-memory --enable-nontrapping-float-to-int ` +
      `--enable-sign-ext --enable-mutable-globals ` +
      `${wasmDst} -o ${wasmOptDst}`,
    { stdio: 'pipe' },
  );
  // Replace with optimized version
  fs.renameSync(wasmOptDst, wasmDst);
  const optSizeMB = (fs.statSync(wasmDst).size / 1024 / 1024).toFixed(1);
  console.log(`  Optimized with wasm-opt: ${sizeMB} MB → ${optSizeMB} MB`);
} catch (_) {
  console.log('  wasm-opt not found — skipping optimization');
}

console.log('[build] Done. Assets in ../assets/');
console.log('[build] Zero npm runtime dependencies.');
