/**
 * worker_src.js — Runs dart_monty_native.wasm inside a Web Worker via C-ABI.
 *
 * Replaces the NAPI-RS class-based approach with direct calls to the 28
 * exported C functions. String marshalling via monty_alloc/monty_dealloc.
 *
 * Bundled by esbuild into dart_monty_worker.js for the browser.
 */

import {
  instantiateMonty,
  getExports,
  allocCString,
  readCString,
  readAndFreeCString,
  allocOutPtr,
  PROGRESS_COMPLETE,
  PROGRESS_PENDING,
  PROGRESS_ERROR,
  PROGRESS_RESOLVE_FUTURES,
  RESULT_OK,
} from './wasm_glue.js';

let wasm = null;

// ---------------------------------------------------------------------------
// Initialization
// ---------------------------------------------------------------------------

async function initWasm() {
  const wasmUrl = new URL('./dart_monty_native.wasm', import.meta.url);
  wasm = await instantiateMonty(wasmUrl);
  self.postMessage({
    type: 'ready',
    exports: Object.keys(wasm).filter((k) => k.startsWith('monty_')),
  });
}

// ---------------------------------------------------------------------------
// Error schema adapter (C-ABI → Dart-expected format)
// ---------------------------------------------------------------------------

/**
 * Flatten C-ABI result JSON for Dart consumption.
 *
 * C-ABI: { value, error: { message, exc_type, traceback }, usage, print_output }
 * Dart:  { ok, value?, print_output?, error?, errorType?, excType?, traceback? }
 */
function adaptResultForDart(cabiResultJson, isError) {
  const parsed = JSON.parse(cabiResultJson);
  if (isError) {
    const err = (parsed.error && typeof parsed.error === 'object')
      ? parsed.error
      : { message: parsed.error ? String(parsed.error) : 'Unknown error' };
    return {
      ok: false,
      error: err.message || String(err),
      errorType: err.exc_type || 'MontyException',
      excType: err.exc_type || null,
      traceback: err.traceback || null,
    };
  }
  return {
    ok: true,
    value: parsed.value,
    print_output: parsed.print_output || null,
  };
}

// ---------------------------------------------------------------------------
// Progress reading (shared by start, resume, resumeAsFuture, resumeFutures)
// ---------------------------------------------------------------------------

/**
 * Read progress state from a handle after a C-ABI progress call.
 * @returns {Object} message payload to send back to main thread.
 */
function readProgress(id, handle, tag, errMsg) {
  switch (tag) {
    case PROGRESS_COMPLETE: {
      const isErr = wasm.monty_complete_is_error(handle);
      const ptr = wasm.monty_complete_result_json(handle);
      const json = readAndFreeCString(ptr);
      if (json) {
        const adapted = adaptResultForDart(json, isErr === 1);
        return { type: 'result', id, ...adapted, state: adapted.ok ? 'complete' : undefined };
      }
      if (isErr === 1) {
        return {
          type: 'result', id, ok: false,
          error: 'Execution failed (no error context)',
          errorType: 'MontyException',
        };
      }
      return { type: 'result', id, ok: true, state: 'complete', value: null };
    }

    case PROGRESS_PENDING: {
      const fnName = readAndFreeCString(wasm.monty_pending_fn_name(handle));
      const argsJson = readAndFreeCString(wasm.monty_pending_fn_args_json(handle));
      const kwargsJson = readAndFreeCString(wasm.monty_pending_fn_kwargs_json(handle));
      const callId = wasm.monty_pending_call_id(handle);
      const methodCall = wasm.monty_pending_method_call(handle);

      return {
        type: 'result',
        id,
        ok: true,
        state: 'pending',
        functionName: fnName,
        args: argsJson ? JSON.parse(argsJson) : [],
        kwargs: kwargsJson ? JSON.parse(kwargsJson) : {},
        callId,
        methodCall: methodCall === 1,
      };
    }

    case PROGRESS_RESOLVE_FUTURES: {
      const idsPtr = wasm.monty_pending_future_call_ids(handle);
      const idsJson = readAndFreeCString(idsPtr);
      return {
        type: 'result',
        id,
        ok: true,
        state: 'resolve_futures',
        pendingCallIds: idsJson ? JSON.parse(idsJson) : [],
      };
    }

    case PROGRESS_ERROR:
      return {
        type: 'result',
        id,
        ok: false,
        error: errMsg || 'Unknown error',
        errorType: 'MontyException',
      };

    default:
      return {
        type: 'result',
        id,
        ok: false,
        error: `Unknown progress tag: ${tag}`,
        errorType: 'InternalError',
      };
  }
}

// ---------------------------------------------------------------------------
// Per-session handle state
// ---------------------------------------------------------------------------

let activeHandle = null;

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

function handleRun(id, code, limits, scriptName) {
  let cCode = null;
  let cName = null;
  let outError = null;

  let handle;
  try {
    outError = allocOutPtr();
    cCode = allocCString(code);
    cName = scriptName ? allocCString(scriptName) : null;
    handle = wasm.monty_create(cCode.ptr, 0, cName ? cName.ptr : 0, outError.ptr);
  } catch (e) {
    if (outError) outError.free();
    throw e;
  } finally {
    if (cCode) wasm.monty_dealloc(cCode.ptr, cCode.size);
    if (cName) wasm.monty_dealloc(cName.ptr, cName.size);
  }

  if (handle === 0) {
    const errPtr = outError.read();
    const errMsg = readAndFreeCString(errPtr);
    outError.free();
    self.postMessage({
      type: 'result', id, ok: false,
      error: errMsg || 'monty_create failed',
      errorType: 'CompileError',
    });
    return;
  }
  outError.free();

  // Apply limits
  if (limits) {
    if (limits.memory_bytes != null) wasm.monty_set_memory_limit(handle, limits.memory_bytes);
    if (limits.timeout_ms != null) wasm.monty_set_time_limit_ms(handle, BigInt(limits.timeout_ms));
    if (limits.stack_depth != null) wasm.monty_set_stack_limit(handle, limits.stack_depth);
  }

  let outResult = null;
  let outErrMsg = null;

  let resultTag;
  try {
    outResult = allocOutPtr();
    outErrMsg = allocOutPtr();
    resultTag = wasm.monty_run(handle, outResult.ptr, outErrMsg.ptr);
  } catch (e) {
    // WebAssembly.RuntimeError = panic trap (panic=abort on wasm32-wasip1)
    if (outResult) outResult.free();
    if (outErrMsg) outErrMsg.free();
    wasm.monty_free(handle);
    self.postMessage({
      type: 'result', id, ok: false,
      error: e.message || String(e),
      errorType: 'Panic',
    });
    return;
  }

  const resultPtr = outResult.read();
  const errorPtr = outErrMsg.read();
  const resultJson = readAndFreeCString(resultPtr);
  const errorMsg = readAndFreeCString(errorPtr);
  outResult.free();
  outErrMsg.free();
  wasm.monty_free(handle);

  if (resultTag === RESULT_OK && resultJson) {
    const adapted = adaptResultForDart(resultJson, false);
    self.postMessage({ type: 'result', id, ...adapted });
  } else if (resultJson) {
    const adapted = adaptResultForDart(resultJson, true);
    self.postMessage({ type: 'result', id, ...adapted });
  } else {
    self.postMessage({
      type: 'result', id, ok: false,
      error: errorMsg || 'monty_run failed',
      errorType: 'MontyException',
    });
  }
}

function handleStart(id, code, extFns, limits, scriptName) {
  // Free any abandoned execution before starting a new one.
  if (activeHandle) {
    wasm.monty_free(activeHandle);
    activeHandle = null;
  }

  let cCode = null;
  let cExtFns = null;
  let cName = null;
  let outError = null;

  let handle;
  try {
    outError = allocOutPtr();
    cCode = allocCString(code);
    cExtFns = extFns && extFns.length > 0 ? allocCString(extFns.join(',')) : null;
    cName = scriptName ? allocCString(scriptName) : null;
    handle = wasm.monty_create(
      cCode.ptr, cExtFns ? cExtFns.ptr : 0, cName ? cName.ptr : 0, outError.ptr,
    );
  } catch (e) {
    if (outError) outError.free();
    throw e;
  } finally {
    if (cCode) wasm.monty_dealloc(cCode.ptr, cCode.size);
    if (cExtFns) wasm.monty_dealloc(cExtFns.ptr, cExtFns.size);
    if (cName) wasm.monty_dealloc(cName.ptr, cName.size);
  }

  if (handle === 0) {
    const errPtr = outError.read();
    const errMsg = readAndFreeCString(errPtr);
    outError.free();
    self.postMessage({
      type: 'result', id, ok: false,
      error: errMsg || 'monty_create failed',
      errorType: 'CompileError',
    });
    return;
  }
  outError.free();

  // Apply limits
  if (limits) {
    if (limits.memory_bytes != null) wasm.monty_set_memory_limit(handle, limits.memory_bytes);
    if (limits.timeout_ms != null) wasm.monty_set_time_limit_ms(handle, BigInt(limits.timeout_ms));
    if (limits.stack_depth != null) wasm.monty_set_stack_limit(handle, limits.stack_depth);
  }

  activeHandle = handle;

  let outErr;
  let tag;
  try {
    outErr = allocOutPtr();
    tag = wasm.monty_start(handle, outErr.ptr);
  } catch (e) {
    if (outErr) outErr.free();
    activeHandle = null;
    wasm.monty_free(handle);
    self.postMessage({
      type: 'result', id, ok: false,
      error: e.message || String(e),
      errorType: 'Panic',
    });
    return;
  }

  const errPtr = outErr.read();
  const errMsg = readAndFreeCString(errPtr);
  outErr.free();

  let msg;
  try {
    msg = readProgress(id, handle, tag, errMsg);
  } catch (e) {
    activeHandle = null;
    wasm.monty_free(handle);
    throw e;
  }
  if (tag === PROGRESS_COMPLETE || tag === PROGRESS_ERROR) {
    activeHandle = null;
    wasm.monty_free(handle);
  }
  self.postMessage(msg);
}

function handleResume(id, value) {
  if (!activeHandle) {
    self.postMessage({
      type: 'result', id, ok: false,
      error: 'No active handle to resume.',
      errorType: 'StateError',
    });
    return;
  }

  let cVal = null;
  let outErr = null;

  let tag;
  try {
    cVal = allocCString(JSON.stringify(value));
    outErr = allocOutPtr();
    tag = wasm.monty_resume(activeHandle, cVal.ptr, outErr.ptr);
  } catch (e) {
    if (cVal) wasm.monty_dealloc(cVal.ptr, cVal.size);
    if (outErr) outErr.free();
    wasm.monty_free(activeHandle);
    activeHandle = null;
    self.postMessage({
      type: 'result', id, ok: false,
      error: e.message || String(e),
      errorType: 'Panic',
    });
    return;
  }
  wasm.monty_dealloc(cVal.ptr, cVal.size);

  const errPtr = outErr.read();
  const errMsg = readAndFreeCString(errPtr);
  outErr.free();

  let msg;
  try {
    msg = readProgress(id, activeHandle, tag, errMsg);
  } catch (e) {
    wasm.monty_free(activeHandle);
    activeHandle = null;
    throw e;
  }
  if (tag === PROGRESS_COMPLETE || tag === PROGRESS_ERROR) {
    wasm.monty_free(activeHandle);
    activeHandle = null;
  }
  self.postMessage(msg);
}

function handleResumeWithError(id, errorMessage) {
  if (!activeHandle) {
    self.postMessage({
      type: 'result', id, ok: false,
      error: 'No active handle to resume.',
      errorType: 'StateError',
    });
    return;
  }

  let cErr = null;
  let outErr = null;

  let tag;
  try {
    cErr = allocCString(errorMessage);
    outErr = allocOutPtr();
    tag = wasm.monty_resume_with_error(activeHandle, cErr.ptr, outErr.ptr);
  } catch (e) {
    if (cErr) wasm.monty_dealloc(cErr.ptr, cErr.size);
    if (outErr) outErr.free();
    wasm.monty_free(activeHandle);
    activeHandle = null;
    self.postMessage({
      type: 'result', id, ok: false,
      error: e.message || String(e),
      errorType: 'Panic',
    });
    return;
  }
  wasm.monty_dealloc(cErr.ptr, cErr.size);

  const errPtr = outErr.read();
  const errMsg = readAndFreeCString(errPtr);
  outErr.free();

  let msg;
  try {
    msg = readProgress(id, activeHandle, tag, errMsg);
  } catch (e) {
    wasm.monty_free(activeHandle);
    activeHandle = null;
    throw e;
  }
  if (tag === PROGRESS_COMPLETE || tag === PROGRESS_ERROR) {
    wasm.monty_free(activeHandle);
    activeHandle = null;
  }
  self.postMessage(msg);
}

function handleResumeAsFuture(id) {
  if (!activeHandle) {
    self.postMessage({
      type: 'result', id, ok: false,
      error: 'No active handle for resumeAsFuture.',
      errorType: 'StateError',
    });
    return;
  }

  const outErr = allocOutPtr();
  let tag;
  try {
    tag = wasm.monty_resume_as_future(activeHandle, outErr.ptr);
  } catch (e) {
    outErr.free();
    wasm.monty_free(activeHandle);
    activeHandle = null;
    self.postMessage({
      type: 'result', id, ok: false,
      error: e.message || String(e),
      errorType: 'Panic',
    });
    return;
  }

  const errPtr = outErr.read();
  const errMsg = readAndFreeCString(errPtr);
  outErr.free();

  let msg;
  try {
    msg = readProgress(id, activeHandle, tag, errMsg);
  } catch (e) {
    wasm.monty_free(activeHandle);
    activeHandle = null;
    throw e;
  }
  if (tag === PROGRESS_COMPLETE || tag === PROGRESS_ERROR) {
    wasm.monty_free(activeHandle);
    activeHandle = null;
  }
  self.postMessage(msg);
}

function handleResolveFutures(id, resultsJson, errorsJson) {
  if (!activeHandle) {
    self.postMessage({
      type: 'result', id, ok: false,
      error: 'No active handle for resolveFutures.',
      errorType: 'StateError',
    });
    return;
  }

  let cResults = null;
  let cErrors = null;
  let outErr = null;

  let tag;
  try {
    cResults = allocCString(resultsJson);
    cErrors = allocCString(errorsJson);
    outErr = allocOutPtr();
    tag = wasm.monty_resume_futures(activeHandle, cResults.ptr, cErrors.ptr, outErr.ptr);
  } catch (e) {
    if (cResults) wasm.monty_dealloc(cResults.ptr, cResults.size);
    if (cErrors) wasm.monty_dealloc(cErrors.ptr, cErrors.size);
    if (outErr) outErr.free();
    wasm.monty_free(activeHandle);
    activeHandle = null;
    self.postMessage({
      type: 'result', id, ok: false,
      error: e.message || String(e),
      errorType: 'Panic',
    });
    return;
  }
  wasm.monty_dealloc(cResults.ptr, cResults.size);
  wasm.monty_dealloc(cErrors.ptr, cErrors.size);

  const errPtr = outErr.read();
  const errMsg = readAndFreeCString(errPtr);
  outErr.free();

  let msg;
  try {
    msg = readProgress(id, activeHandle, tag, errMsg);
  } catch (e) {
    wasm.monty_free(activeHandle);
    activeHandle = null;
    throw e;
  }
  if (tag === PROGRESS_COMPLETE || tag === PROGRESS_ERROR) {
    wasm.monty_free(activeHandle);
    activeHandle = null;
  }
  self.postMessage(msg);
}

function handleSnapshot(id) {
  if (!activeHandle) {
    self.postMessage({
      type: 'result', id, ok: false,
      error: 'No active handle to snapshot.',
      errorType: 'StateError',
    });
    return;
  }

  const outLen = allocOutPtr();
  let ptr;
  try {
    ptr = wasm.monty_snapshot(activeHandle, outLen.ptr);
  } catch (e) {
    outLen.free();
    self.postMessage({
      type: 'result', id, ok: false,
      error: e.message || String(e),
      errorType: 'Panic',
    });
    return;
  }

  if (ptr === 0) {
    outLen.free();
    self.postMessage({
      type: 'result', id, ok: false,
      error: 'monty_snapshot returned null',
      errorType: 'StateError',
    });
    return;
  }

  const len = outLen.read();
  outLen.free();

  // Copy bytes out of WASM memory before freeing.
  // try/finally ensures WASM buffer is freed even if slice() OOMs.
  const wasmBytes = new Uint8Array(wasm.memory.buffer, ptr, len);
  let copy;
  try {
    copy = wasmBytes.slice();
  } finally {
    wasm.monty_bytes_free(ptr, len);
  }

  // Transfer ArrayBuffer to main thread (zero-copy move)
  self.postMessage(
    { type: 'result', id, ok: true, snapshotBuffer: copy.buffer },
    [copy.buffer],
  );
}

function handleRestore(id, dataBase64) {
  // Free any abandoned execution before restoring.
  if (activeHandle) {
    wasm.monty_free(activeHandle);
    activeHandle = null;
  }

  // Decode base64 to Uint8Array
  const binary = atob(dataBase64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }

  // Allocate out-pointer first (small, likely to succeed) so that a
  // subsequent OOM on the large buffer doesn't leak it.
  const outError = allocOutPtr();

  const ptr = wasm.monty_alloc(bytes.length);
  if (ptr === 0) {
    outError.free();
    self.postMessage({
      type: 'result', id, ok: false,
      error: `monty_alloc(${bytes.length}) returned null — OOM`,
      errorType: 'MemoryError',
    });
    return;
  }
  new Uint8Array(wasm.memory.buffer).set(bytes, ptr);

  let handle;
  try {
    handle = wasm.monty_restore(ptr, bytes.length, outError.ptr);
  } catch (e) {
    outError.free();
    throw e;
  } finally {
    wasm.monty_dealloc(ptr, bytes.length);
  }

  if (handle === 0) {
    const errPtr = outError.read();
    const errMsg = readAndFreeCString(errPtr);
    outError.free();
    self.postMessage({
      type: 'result', id, ok: false,
      error: errMsg || 'monty_restore failed',
      errorType: 'RestoreError',
    });
    return;
  }
  outError.free();
  activeHandle = handle;
  self.postMessage({ type: 'result', id, ok: true });
}

function handleDispose(id) {
  if (activeHandle) {
    wasm.monty_free(activeHandle);
    activeHandle = null;
  }
  self.postMessage({ type: 'result', id, ok: true });
}

// ---------------------------------------------------------------------------
// Message dispatch
// ---------------------------------------------------------------------------

self.onmessage = (e) => {
  const { type, id, code, extFns, value, errorMessage, limits,
    dataBase64, scriptName, resultsJson, errorsJson } = e.data;
  try {
    switch (type) {
      case 'run':
        handleRun(id, code, limits, scriptName);
        break;
      case 'start':
        handleStart(id, code, extFns, limits, scriptName);
        break;
      case 'resume':
        handleResume(id, value);
        break;
      case 'resumeWithError':
        handleResumeWithError(id, errorMessage);
        break;
      case 'resumeAsFuture':
        handleResumeAsFuture(id);
        break;
      case 'resolveFutures':
        handleResolveFutures(id, resultsJson, errorsJson);
        break;
      case 'snapshot':
        handleSnapshot(id);
        break;
      case 'restore':
        handleRestore(id, dataBase64);
        break;
      case 'dispose':
        handleDispose(id);
        break;
      default:
        self.postMessage({
          type: 'result', id, ok: false,
          error: `Unknown message type: ${type}`,
          errorType: 'UnknownType',
        });
    }
  } catch (e) {
    // Catch-all for WebAssembly.RuntimeError (panic trap) or other crashes
    self.postMessage({
      type: 'result', id, ok: false,
      error: e.message || String(e),
      errorType: e instanceof WebAssembly.RuntimeError ? 'Panic' : 'InternalError',
    });
  }
};

// Boot
initWasm().catch((e) => {
  self.postMessage({
    type: 'error',
    message: `WASM init failed: ${e.message}`,
  });
});
