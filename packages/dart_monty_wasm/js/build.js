#!/usr/bin/env node
/**
 * build.js — Bundles dart_monty_wasm JS bridge and Worker.
 *
 * 1. esbuild worker_src.js → ../assets/dart_monty_worker.js (ESM)
 * 2. Patch bare specifier for sub-worker URL
 * 3. esbuild bridge.js → ../assets/dart_monty_bridge.js (IIFE)
 * 4. Copy wasi-worker-browser.mjs → ../assets/
 * 5. Copy .wasm binary → ../assets/
 */

const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const ASSETS = path.resolve(__dirname, '..', 'assets');
const NODE_MODULES = path.resolve(__dirname, 'node_modules');

// Ensure assets directory exists
fs.mkdirSync(ASSETS, { recursive: true });

// Step 1: Bundle Worker (ESM, external *.wasm)
console.log('[build] Bundling worker...');
execSync(
  `npx esbuild src/worker_src.js ` +
    `--bundle --format=esm ` +
    `--outfile=${path.join(ASSETS, 'dart_monty_worker.js')} ` +
    `--platform=browser ` +
    `--external:*.wasm ` +
    `--log-level=warning`,
  { cwd: __dirname, stdio: 'inherit' },
);

// Step 2: Patch bare specifier for sub-worker
console.log('[build] Patching worker bare specifier...');
const workerPath = path.join(ASSETS, 'dart_monty_worker.js');
let workerSrc = fs.readFileSync(workerPath, 'utf8');
workerSrc = workerSrc.replace(
  /new URL\("@pydantic\/monty-wasm32-wasi\/wasi-worker-browser\.mjs"/g,
  'new URL("./wasi-worker-browser.mjs"',
);
fs.writeFileSync(workerPath, workerSrc);

// Step 3: Bundle bridge (IIFE)
console.log('[build] Bundling bridge...');
execSync(
  `npx esbuild src/bridge.js ` +
    `--bundle --format=iife ` +
    `--outfile=${path.join(ASSETS, 'dart_monty_bridge.js')} ` +
    `--platform=browser ` +
    `--log-level=warning`,
  { cwd: __dirname, stdio: 'inherit' },
);

// Step 4: Copy wasi-worker-browser.mjs
console.log('[build] Copying wasi-worker-browser.mjs...');
const wasiWorkerSrc = path.join(
  NODE_MODULES,
  '@pydantic',
  'monty-wasm32-wasi',
  'wasi-worker-browser.mjs',
);
if (fs.existsSync(wasiWorkerSrc)) {
  fs.copyFileSync(wasiWorkerSrc, path.join(ASSETS, 'wasi-worker-browser.mjs'));
} else {
  console.warn('[build] WARN: wasi-worker-browser.mjs not found, skipping.');
}

// Step 5: Copy .wasm binary
console.log('[build] Copying WASM binary...');
const wasmDir = path.join(NODE_MODULES, '@pydantic', 'monty-wasm32-wasi');
const wasmFiles = fs.readdirSync(wasmDir).filter((f) => f.endsWith('.wasm'));
for (const wasmFile of wasmFiles) {
  fs.copyFileSync(path.join(wasmDir, wasmFile), path.join(ASSETS, wasmFile));
  console.log(`  Copied ${wasmFile}`);
}

console.log('[build] Done. Assets in ../assets/');
