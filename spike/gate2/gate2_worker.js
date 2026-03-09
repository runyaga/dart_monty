/**
 * gate2_worker.js — GATE-2 spike: Load dart_monty_native.wasm via C-ABI.
 *
 * Tests: monty_create("2+2") -> monty_run -> parse result JSON.
 * No NAPI-RS, no npm packages — just WASI shim + C-ABI exports.
 */

import { createWasiImports } from './wasi_shim.js';

let wasm = null; // WebAssembly.Instance exports

/**
 * Read a NUL-terminated C string from WASM memory at the given pointer.
 * Returns null if ptr is 0.
 */
function readCString(ptr) {
  if (ptr === 0) return null;
  const mem = new Uint8Array(wasm.memory.buffer);
  let end = ptr;
  while (mem[end] !== 0) end++;
  return new TextDecoder().decode(mem.subarray(ptr, end));
}

/**
 * Write a JS string into WASM memory using monty_alloc.
 * Returns the pointer to the NUL-terminated C string.
 */
function writeCString(str) {
  const encoded = new TextEncoder().encode(str);
  const ptr = wasm.monty_alloc(encoded.length + 1); // +1 for NUL
  if (ptr === 0) throw new Error('monty_alloc returned null');
  const mem = new Uint8Array(wasm.memory.buffer);
  mem.set(encoded, ptr);
  mem[ptr + encoded.length] = 0; // NUL terminator
  return ptr;
}

/**
 * Allocate a pointer-sized slot in WASM memory (4 bytes for wasm32).
 * Returns { ptr, read() } where read() dereferences the pointer.
 */
function allocOutPtr() {
  const ptr = wasm.monty_alloc(4);
  if (ptr === 0) throw new Error('monty_alloc returned null for out-pointer');
  return {
    ptr,
    read() {
      const mem = new DataView(wasm.memory.buffer);
      return mem.getUint32(ptr, true); // little-endian, unsigned
    },
    free() {
      wasm.monty_dealloc(ptr, 4);
    },
  };
}

async function loadWasm() {
  // Resolve WASM URL relative to worker script location
  const wasmUrl = new URL('./dart_monty_native.wasm', import.meta.url);

  let memory; // will be set after instantiation
  const wasiImports = createWasiImports(() => memory);

  const { instance } = await WebAssembly.instantiateStreaming(
    fetch(wasmUrl),
    { wasi_snapshot_preview1: wasiImports },
  );

  wasm = instance.exports;
  memory = wasm.memory;

  return wasm;
}

async function runGate2() {
  self.postMessage({ type: 'log', message: 'Loading WASM...' });
  await loadWasm();
  self.postMessage({ type: 'log', message: `WASM loaded. Exports: ${Object.keys(wasm).join(', ')}` });

  // --- Test 1: monty_create + monty_run("2+2") ---
  const code = '2+2';
  const codePtr = writeCString(code);
  const outError = allocOutPtr();

  self.postMessage({ type: 'log', message: `Calling monty_create("${code}")...` });
  const handle = wasm.monty_create(codePtr, 0, 0, outError.ptr);

  // Free the code string
  wasm.monty_dealloc(codePtr, new TextEncoder().encode(code).length + 1);

  if (handle === 0) {
    const errPtr = outError.read();
    const errMsg = readCString(errPtr);
    if (errPtr) wasm.monty_string_free(errPtr);
    outError.free();
    self.postMessage({ type: 'error', message: `monty_create failed: ${errMsg}` });
    return;
  }

  self.postMessage({ type: 'log', message: `monty_create returned handle at ${handle}` });

  // Allocate out-pointers for monty_run
  const outResultJson = allocOutPtr();
  const outErrorMsg = allocOutPtr();

  self.postMessage({ type: 'log', message: 'Calling monty_run...' });
  const resultTag = wasm.monty_run(handle, outResultJson.ptr, outErrorMsg.ptr);

  // MONTY_RESULT_OK = 0, MONTY_RESULT_ERROR = 1
  const resultJsonPtr = outResultJson.read();
  const errorMsgPtr = outErrorMsg.read();

  const resultJson = readCString(resultJsonPtr);
  const errorMsg = readCString(errorMsgPtr);

  if (resultJsonPtr) wasm.monty_string_free(resultJsonPtr);
  if (errorMsgPtr) wasm.monty_string_free(errorMsgPtr);
  outResultJson.free();
  outErrorMsg.free();
  outError.free();

  // Free the handle
  wasm.monty_free(handle);

  if (resultTag === 0) {
    self.postMessage({
      type: 'result',
      ok: true,
      resultTag,
      resultJson,
      parsed: JSON.parse(resultJson),
    });
  } else {
    self.postMessage({
      type: 'result',
      ok: false,
      resultTag,
      errorMsg,
      resultJson,
    });
  }
}

runGate2().catch((e) => {
  self.postMessage({ type: 'error', message: `Worker crash: ${e.message}\n${e.stack}` });
});
