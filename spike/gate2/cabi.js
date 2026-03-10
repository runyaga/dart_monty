/**
 * cabi.js — C-ABI wrapper for dart_monty_native.wasm.
 *
 * Provides high-level JS functions that call the raw WASM exports,
 * handling string marshalling, out-pointers, and memory management.
 */

import { createWasiImports } from './wasi_shim.js';

let wasm = null;

/** Load and instantiate the WASM module. */
export async function loadWasm(wasmUrl) {
  let memory;
  const wasiImports = createWasiImports(() => memory);

  const { instance } = await WebAssembly.instantiateStreaming(
    fetch(wasmUrl),
    { wasi_snapshot_preview1: wasiImports },
  );

  wasm = instance.exports;
  memory = wasm.memory;
  return wasm;
}

/** Read a NUL-terminated C string from WASM memory. Returns null if ptr is 0. */
export function readCString(ptr) {
  if (ptr === 0) return null;
  const mem = new Uint8Array(wasm.memory.buffer);
  let end = ptr;
  while (mem[end] !== 0) end++;
  return new TextDecoder().decode(mem.subarray(ptr, end));
}

/** Write a JS string into WASM memory via monty_alloc. Returns pointer. */
export function writeCString(str) {
  const encoded = new TextEncoder().encode(str);
  const ptr = wasm.monty_alloc(encoded.length + 1);
  if (ptr === 0) throw new Error('monty_alloc returned null');
  const mem = new Uint8Array(wasm.memory.buffer);
  mem.set(encoded, ptr);
  mem[ptr + encoded.length] = 0;
  return { ptr, size: encoded.length + 1 };
}

/** Allocate a 4-byte out-pointer slot. */
export function allocOutPtr() {
  const ptr = wasm.monty_alloc(4);
  if (ptr === 0) throw new Error('monty_alloc returned null for out-pointer');
  return {
    ptr,
    read() {
      return new DataView(wasm.memory.buffer).getUint32(ptr, true);
    },
    free() {
      wasm.monty_dealloc(ptr, 4);
    },
  };
}

/** Free a C string allocated by writeCString. */
export function freeCString(cstr) {
  wasm.monty_dealloc(cstr.ptr, cstr.size);
}

// ProgressTag enum
export const PROGRESS_COMPLETE = 0;
export const PROGRESS_PENDING = 1;
export const PROGRESS_ERROR = 2;
export const PROGRESS_RESOLVE_FUTURES = 3;

// ResultTag enum
export const RESULT_OK = 0;
export const RESULT_ERROR = 1;

// ---------------------------------------------------------------------------
// High-level API
// ---------------------------------------------------------------------------

/**
 * Create a Monty handle from Python source.
 * @returns {{ handle: number } | { error: string }}
 */
export function create(code, extFns, scriptName) {
  const cCode = writeCString(code);
  const cExtFns = extFns ? writeCString(extFns) : null;
  const cName = scriptName ? writeCString(scriptName) : null;
  const outError = allocOutPtr();

  const handle = wasm.monty_create(
    cCode.ptr,
    cExtFns ? cExtFns.ptr : 0,
    cName ? cName.ptr : 0,
    outError.ptr,
  );

  freeCString(cCode);
  if (cExtFns) freeCString(cExtFns);
  if (cName) freeCString(cName);

  if (handle === 0) {
    const errPtr = outError.read();
    const errMsg = readCString(errPtr);
    if (errPtr) wasm.monty_string_free(errPtr);
    outError.free();
    return { error: errMsg || 'monty_create returned null' };
  }

  outError.free();
  return { handle };
}

/**
 * Run code to completion.
 * @returns {{ ok: true, json: string, parsed: object } | { ok: false, error: string, json?: string }}
 */
export function run(handle) {
  const outResult = allocOutPtr();
  const outError = allocOutPtr();

  const tag = wasm.monty_run(handle, outResult.ptr, outError.ptr);

  const resultPtr = outResult.read();
  const errorPtr = outError.read();
  const resultJson = readCString(resultPtr);
  const errorMsg = readCString(errorPtr);

  if (resultPtr) wasm.monty_string_free(resultPtr);
  if (errorPtr) wasm.monty_string_free(errorPtr);
  outResult.free();
  outError.free();

  if (tag === RESULT_OK) {
    return { ok: true, json: resultJson, parsed: JSON.parse(resultJson) };
  }
  return { ok: false, error: errorMsg, json: resultJson };
}

/**
 * Start iterative execution.
 * @returns progress result object
 */
export function start(handle) {
  const outError = allocOutPtr();
  const tag = wasm.monty_start(handle, outError.ptr);
  const errPtr = outError.read();
  const errMsg = readCString(errPtr);
  if (errPtr) wasm.monty_string_free(errPtr);
  outError.free();

  return _readProgress(handle, tag, errMsg);
}

/**
 * Resume with a JSON value.
 * @returns progress result object
 */
export function resume(handle, valueJson) {
  const cVal = writeCString(valueJson);
  const outError = allocOutPtr();
  const tag = wasm.monty_resume(handle, cVal.ptr, outError.ptr);
  freeCString(cVal);

  const errPtr = outError.read();
  const errMsg = readCString(errPtr);
  if (errPtr) wasm.monty_string_free(errPtr);
  outError.free();

  return _readProgress(handle, tag, errMsg);
}

/**
 * Resume with an error message.
 * @returns progress result object
 */
export function resumeWithError(handle, errorMessage) {
  const cErr = writeCString(errorMessage);
  const outError = allocOutPtr();
  const tag = wasm.monty_resume_with_error(handle, cErr.ptr, outError.ptr);
  freeCString(cErr);

  const errPtr = outError.read();
  const errMsg = readCString(errPtr);
  if (errPtr) wasm.monty_string_free(errPtr);
  outError.free();

  return _readProgress(handle, tag, errMsg);
}

/**
 * Resume as future (for async/await support).
 * @returns progress result object
 */
export function resumeAsFuture(handle) {
  const outError = allocOutPtr();
  const tag = wasm.monty_resume_as_future(handle, outError.ptr);

  const errPtr = outError.read();
  const errMsg = readCString(errPtr);
  if (errPtr) wasm.monty_string_free(errPtr);
  outError.free();

  return _readProgress(handle, tag, errMsg);
}

/**
 * Get pending future call IDs (when in RESOLVE_FUTURES state).
 * @returns {number[]|null}
 */
export function pendingFutureCallIds(handle) {
  const ptr = wasm.monty_pending_future_call_ids(handle);
  if (ptr === 0) return null;
  const json = readCString(ptr);
  wasm.monty_string_free(ptr);
  return JSON.parse(json);
}

/**
 * Resume futures with results and errors.
 * @param {object} results - { "callId": value, ... }
 * @param {object} errors - { "callId": "errorMsg", ... }
 * @returns progress result object
 */
export function resumeFutures(handle, results, errors) {
  const cResults = writeCString(JSON.stringify(results || {}));
  const cErrors = writeCString(JSON.stringify(errors || {}));
  const outError = allocOutPtr();

  const tag = wasm.monty_resume_futures(
    handle, cResults.ptr, cErrors.ptr, outError.ptr,
  );

  freeCString(cResults);
  freeCString(cErrors);

  const errPtr = outError.read();
  const errMsg = readCString(errPtr);
  if (errPtr) wasm.monty_string_free(errPtr);
  outError.free();

  return _readProgress(handle, tag, errMsg);
}

/** Set resource limits on a handle. */
export function setLimits(handle, limits) {
  if (!limits) return;
  if (limits.memory_bytes != null) {
    wasm.monty_set_memory_limit(handle, limits.memory_bytes);
  }
  if (limits.timeout_ms != null) {
    wasm.monty_set_time_limit_ms(handle, BigInt(limits.timeout_ms));
  }
  if (limits.stack_depth != null) {
    wasm.monty_set_stack_limit(handle, limits.stack_depth);
  }
}

/** Free a handle. */
export function free(handle) {
  wasm.monty_free(handle);
}

// ---------------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------------

function _readProgress(handle, tag, errMsg) {
  switch (tag) {
    case PROGRESS_COMPLETE: {
      const isErr = wasm.monty_complete_is_error(handle);
      const ptr = wasm.monty_complete_result_json(handle);
      const json = readCString(ptr);
      if (ptr) wasm.monty_string_free(ptr);
      return {
        state: 'complete',
        isError: isErr === 1,
        json,
        parsed: json ? JSON.parse(json) : null,
      };
    }
    case PROGRESS_PENDING: {
      const fnNamePtr = wasm.monty_pending_fn_name(handle);
      const argsPtr = wasm.monty_pending_fn_args_json(handle);
      const kwargsPtr = wasm.monty_pending_fn_kwargs_json(handle);
      const callId = wasm.monty_pending_call_id(handle);

      const fnName = readCString(fnNamePtr);
      const argsJson = readCString(argsPtr);
      const kwargsJson = readCString(kwargsPtr);

      if (fnNamePtr) wasm.monty_string_free(fnNamePtr);
      if (argsPtr) wasm.monty_string_free(argsPtr);
      if (kwargsPtr) wasm.monty_string_free(kwargsPtr);

      return {
        state: 'pending',
        functionName: fnName,
        args: argsJson ? JSON.parse(argsJson) : [],
        kwargs: kwargsJson ? JSON.parse(kwargsJson) : {},
        callId,
      };
    }
    case PROGRESS_RESOLVE_FUTURES:
      return { state: 'resolve_futures' };
    case PROGRESS_ERROR:
      return { state: 'error', error: errMsg };
    default:
      return { state: 'unknown', tag, error: errMsg };
  }
}
