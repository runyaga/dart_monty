/**
 * worker_src.js — Runs dart_monty_core_native.wasm inside a Web Worker via C-ABI.
 *
 * Replaces the NAPI-RS class-based approach with direct calls to the 28
 * exported C functions. String marshalling via monty_alloc/monty_dealloc.
 *
 * Bundled by esbuild into dart_monty_core_worker.js for the browser.
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
  PROGRESS_OS_CALL,
  PROGRESS_NAME_LOOKUP,
  RESULT_OK,
} from './wasm_glue.js';

let wasm = null;

// ---------------------------------------------------------------------------
// Initialization
// ---------------------------------------------------------------------------

async function initWasm() {
  const wasmUrl = new URL('./dart_monty_core_native.wasm', import.meta.url);
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

/**
 * Extract an exception type name from a compile-error message.
 *
 * monty_create writes exc.summary() into out_error on failure, which looks
 * like "SyntaxError: 'break' outside loop". Extract the prefix so Dart can
 * match on excType the same way it does for runtime errors.
 *
 * Returns null when the message has no recognisable "TypeName:" prefix.
 */
function excTypeFromMsg(msg) {
  if (!msg) return null;
  const colon = msg.indexOf(':');
  if (colon <= 0) return null;
  const prefix = msg.substring(0, colon).trim();
  // Sanity-check: exception type names are PascalCase identifiers.
  return /^[A-Z][A-Za-z]+$/.test(prefix) ? prefix : null;
}

// ---------------------------------------------------------------------------
// Progress API vtables — typed accessors per handle kind
// ---------------------------------------------------------------------------
// MontyHandle* (session) and MontyReplHandle* (REPL) are distinct Rust types
// with parallel but separate C exports. Passing the wrong handle type to a C
// function is undefined behaviour — the struct layout differs. These vtables
// make readProgress() handle-type-aware: non-REPL handlers pass
// SESSION_PROGRESS, REPL handlers pass REPL_PROGRESS. Adding a new progress
// tag requires only one change inside readProgress().
//
// The closures capture the module-level `wasm` variable by reference so they
// always use the post-init value; they are safe to define before initWasm().

const SESSION_PROGRESS = {
  completeIsError:      (h) => wasm.monty_complete_is_error(h),
  completeResultJson:   (h) => wasm.monty_complete_result_json(h),
  pendingFnName:        (h) => wasm.monty_pending_fn_name(h),
  pendingFnArgsJson:    (h) => wasm.monty_pending_fn_args_json(h),
  pendingFnKwargsJson:  (h) => wasm.monty_pending_fn_kwargs_json(h),
  pendingCallId:        (h) => wasm.monty_pending_call_id(h),
  pendingMethodCall:    (h) => wasm.monty_pending_method_call(h),
  pendingFutureCallIds: (h) => wasm.monty_pending_future_call_ids(h),
  osCallFnName:         (h) => wasm.monty_os_call_fn_name(h),
  osCallArgsJson:       (h) => wasm.monty_os_call_args_json(h),
  osCallKwargsJson:     (h) => wasm.monty_os_call_kwargs_json(h),
  osCallId:             (h) => wasm.monty_os_call_id(h),
  nameLookupName:       (h) => wasm.monty_name_lookup_name(h),
};

const REPL_PROGRESS = {
  completeIsError:      (h) => wasm.monty_repl_complete_is_error(h),
  completeResultJson:   (h) => wasm.monty_repl_complete_result_json(h),
  pendingFnName:        (h) => wasm.monty_repl_pending_fn_name(h),
  pendingFnArgsJson:    (h) => wasm.monty_repl_pending_fn_args_json(h),
  pendingFnKwargsJson:  (h) => wasm.monty_repl_pending_fn_kwargs_json(h),
  pendingCallId:        (h) => wasm.monty_repl_pending_call_id(h),
  pendingMethodCall:    (h) => wasm.monty_repl_pending_method_call(h),
  pendingFutureCallIds: (h) => wasm.monty_repl_pending_future_call_ids(h),
  osCallFnName:         (h) => wasm.monty_repl_os_call_fn_name(h),
  osCallArgsJson:       (h) => wasm.monty_repl_os_call_args_json(h),
  osCallKwargsJson:     (h) => wasm.monty_repl_os_call_kwargs_json(h),
  osCallId:             (h) => wasm.monty_repl_os_call_id(h),
  // REPL auto-resolves NameLookup internally (process_repl_progress loop);
  // PROGRESS_NAME_LOOKUP never surfaces to JS for REPL handles.
  nameLookupName:       null,
};

// ---------------------------------------------------------------------------
// Progress reading (shared by start, resume, resumeAsFuture, resumeFutures)
// ---------------------------------------------------------------------------

/**
 * Read progress state from a handle after a C-ABI progress call.
 *
 * @param {number}  id      - Dart request ID to echo back.
 * @param {number}  handle  - C handle pointer (MontyHandle* or MontyReplHandle*).
 * @param {number}  tag     - PROGRESS_* constant returned by the C call.
 * @param {string}  errMsg  - Error string from the out-error pointer, if any.
 * @param {object}  api     - SESSION_PROGRESS or REPL_PROGRESS vtable.
 * @returns {Object} message payload to send back to main thread.
 */
function readProgress(id, handle, tag, errMsg, api) {
  switch (tag) {
    case PROGRESS_COMPLETE: {
      const isErr = api.completeIsError(handle);
      const ptr = api.completeResultJson(handle);
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
      const fnName = readAndFreeCString(api.pendingFnName(handle));
      const argsJson = readAndFreeCString(api.pendingFnArgsJson(handle));
      const kwargsJson = readAndFreeCString(api.pendingFnKwargsJson(handle));
      const callId = api.pendingCallId(handle);
      const methodCall = api.pendingMethodCall(handle);

      return {
        type: 'result', id, ok: true, state: 'pending',
        functionName: fnName,
        args: argsJson ? JSON.parse(argsJson) : [],
        kwargs: kwargsJson ? JSON.parse(kwargsJson) : {},
        callId,
        methodCall: methodCall === 1,
      };
    }

    case PROGRESS_RESOLVE_FUTURES: {
      const idsPtr = api.pendingFutureCallIds(handle);
      const idsJson = readAndFreeCString(idsPtr);
      return {
        type: 'result', id, ok: true, state: 'resolve_futures',
        pendingCallIds: idsJson ? JSON.parse(idsJson) : [],
      };
    }

    case PROGRESS_OS_CALL: {
      const fnName = readAndFreeCString(api.osCallFnName(handle));
      const argsJson = readAndFreeCString(api.osCallArgsJson(handle));
      const kwargsJson = readAndFreeCString(api.osCallKwargsJson(handle));
      const callId = api.osCallId(handle);
      return {
        type: 'result', id, ok: true, state: 'os_call',
        functionName: fnName,
        args: argsJson ? JSON.parse(argsJson) : [],
        kwargs: kwargsJson ? JSON.parse(kwargsJson) : {},
        callId,
      };
    }

    case PROGRESS_NAME_LOOKUP: {
      if (!api.nameLookupName) {
        // REPL auto-resolves NameLookup internally — this tag should never reach JS.
        return {
          type: 'result', id, ok: false,
          error: 'Unexpected PROGRESS_NAME_LOOKUP for REPL handle',
          errorType: 'InternalError',
        };
      }
      const namePtr = api.nameLookupName(handle);
      const variableName = readAndFreeCString(namePtr);
      return {
        type: 'result', id, ok: true, state: 'name_lookup',
        variableName,
      };
    }

    case PROGRESS_ERROR: {
      // Python runtime exceptions: handle_exception() sets state to Complete
      // (is_error=true) before returning PROGRESS_ERROR. Read the full result
      // JSON so exc_type, traceback, etc. are available to Dart.
      const isErrState = api.completeIsError(handle);
      const errPtr2 = api.completeResultJson(handle);
      const errJson = readAndFreeCString(errPtr2);
      if (errJson && isErrState === 1) {
        const adapted = adaptResultForDart(errJson, true);
        return { type: 'result', id, ...adapted };
      }
      // Fallback for internal Rust errors (no complete JSON available).
      return {
        type: 'result', id, ok: false,
        error: errMsg || 'Unknown error',
        errorType: 'MontyException',
        excType: excTypeFromMsg(errMsg),
      };
    }

    default:
      return {
        type: 'result', id, ok: false,
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
      excType: excTypeFromMsg(errMsg),
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
      excType: excTypeFromMsg(errMsg),
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
    msg = readProgress(id, handle, tag, errMsg, SESSION_PROGRESS);
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
    msg = readProgress(id, activeHandle, tag, errMsg, SESSION_PROGRESS);
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
    msg = readProgress(id, activeHandle, tag, errMsg, SESSION_PROGRESS);
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

function handleResumeWithException(id, excType, errorMessage) {
  if (!activeHandle) {
    self.postMessage({
      type: 'result', id, ok: false,
      error: 'No active handle to resume.',
      errorType: 'StateError',
    });
    return;
  }

  let cExcType = null;
  let cErr = null;
  let outErr = null;

  let tag;
  try {
    cExcType = allocCString(excType);
    cErr = allocCString(errorMessage);
    outErr = allocOutPtr();
    tag = wasm.monty_resume_with_exception(activeHandle, cExcType.ptr, cErr.ptr, outErr.ptr);
  } catch (e) {
    if (cExcType) wasm.monty_dealloc(cExcType.ptr, cExcType.size);
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
  wasm.monty_dealloc(cExcType.ptr, cExcType.size);
  wasm.monty_dealloc(cErr.ptr, cErr.size);

  const errPtr = outErr.read();
  const errMsg = readAndFreeCString(errPtr);
  outErr.free();

  let msg;
  try {
    msg = readProgress(id, activeHandle, tag, errMsg, SESSION_PROGRESS);
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

function handleResumeNotFound(id, fnName) {
  if (!activeHandle) {
    self.postMessage({
      type: 'result', id, ok: false,
      error: 'No active handle to resume.',
      errorType: 'StateError',
    });
    return;
  }

  let cFnName = null;
  let outErr = null;

  let tag;
  try {
    cFnName = allocCString(fnName);
    outErr = allocOutPtr();
    tag = wasm.monty_resume_not_found(activeHandle, cFnName.ptr, outErr.ptr);
  } catch (e) {
    if (cFnName) wasm.monty_dealloc(cFnName.ptr, cFnName.size);
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
  wasm.monty_dealloc(cFnName.ptr, cFnName.size);

  const errPtr = outErr.read();
  const errMsg = readAndFreeCString(errPtr);
  outErr.free();

  let msg;
  try {
    msg = readProgress(id, activeHandle, tag, errMsg, SESSION_PROGRESS);
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
    msg = readProgress(id, activeHandle, tag, errMsg, SESSION_PROGRESS);
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
    msg = readProgress(id, activeHandle, tag, errMsg, SESSION_PROGRESS);
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

function handleCompile(id, code, scriptName) {
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
      excType: excTypeFromMsg(errMsg),
    });
    return;
  }
  outError.free();

  // Snapshot the compiled (pre-execution) handle — captures bytecode only.
  // Does NOT set activeHandle; handle is freed after snapshotting.
  const outLen = allocOutPtr();
  let ptr;
  try {
    ptr = wasm.monty_snapshot(handle, outLen.ptr);
  } catch (e) {
    outLen.free();
    wasm.monty_free(handle);
    self.postMessage({
      type: 'result', id, ok: false,
      error: e.message || String(e),
      errorType: 'Panic',
    });
    return;
  }
  wasm.monty_free(handle);

  if (ptr === 0) {
    outLen.free();
    self.postMessage({
      type: 'result', id, ok: false,
      error: 'monty_snapshot returned null after compile',
      errorType: 'StateError',
    });
    return;
  }

  const len = outLen.read();
  outLen.free();

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

function handleRunPrecompiled(id, dataBase64, limits, scriptName) {
  // Decode base64 to Uint8Array
  const binary = atob(dataBase64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }

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

function handleStartPrecompiled(id, dataBase64, limits, scriptName) {
  // Free any abandoned execution before starting a new one.
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
    msg = readProgress(id, handle, tag, errMsg, SESSION_PROGRESS);
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

function handleResumeNameLookupValue(id, valueJson) {
  if (!activeHandle) {
    self.postMessage({
      type: 'result', id, ok: false,
      error: 'No active handle for resumeNameLookupValue.',
      errorType: 'StateError',
    });
    return;
  }

  let cVal = null;
  let outErr = null;

  let tag;
  try {
    cVal = allocCString(valueJson);
    outErr = allocOutPtr();
    tag = wasm.monty_resume_name_lookup_value(activeHandle, cVal.ptr, outErr.ptr);
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
    msg = readProgress(id, activeHandle, tag, errMsg, SESSION_PROGRESS);
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

function handleResumeNameLookupUndefined(id) {
  if (!activeHandle) {
    self.postMessage({
      type: 'result', id, ok: false,
      error: 'No active handle for resumeNameLookupUndefined.',
      errorType: 'StateError',
    });
    return;
  }

  const outErr = allocOutPtr();
  let tag;
  try {
    tag = wasm.monty_resume_name_lookup_undefined(activeHandle, outErr.ptr);
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
    msg = readProgress(id, activeHandle, tag, errMsg, SESSION_PROGRESS);
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

function handleDispose(id) {
  if (activeHandle) {
    wasm.monty_free(activeHandle);
    activeHandle = null;
  }
  self.postMessage({ type: 'result', id, ok: true });
}

// ---------------------------------------------------------------------------
// REPL Handlers
// ---------------------------------------------------------------------------

const replHandles = new Map(); // replId (string) -> i32 Rust handle

function handleReplCreate(id, replId, scriptName) {
  if (!replId) {
    self.postMessage({
      type: 'result', id, ok: false,
      error: 'replId is required for replCreate',
      errorType: 'StateError',
    });
    return;
  }

  let cName = null;
  let outError = null;
  let handle;
  try {
    outError = allocOutPtr();
    cName = scriptName ? allocCString(scriptName) : null;
    handle = wasm.monty_repl_create(cName ? cName.ptr : 0, outError.ptr);
  } catch (e) {
    if (outError) outError.free();
    throw e;
  } finally {
    if (cName) wasm.monty_dealloc(cName.ptr, cName.size);
  }

  if (handle === 0) {
    const errPtr = outError.read();
    const errMsg = readAndFreeCString(errPtr);
    outError.free();
    self.postMessage({
      type: 'result', id, ok: false,
      error: errMsg || 'monty_repl_create failed',
      errorType: 'CompileError',
    });
    return;
  }
  outError.free();
  replHandles.set(replId, handle);
  self.postMessage({ type: 'result', id, ok: true });
}

function handleReplFeedRun(id, replId, code) {
  const handle = replHandles.get(replId);
  if (!handle) {
    self.postMessage({ type: 'result', id, ok: false,
      error: `No REPL session for replId: ${replId}`, errorType: 'StateError' });
    return;
  }

  let cCode = null;
  let outResult = null;
  let outError = null;
  try {
    cCode = allocCString(code);
    outResult = allocOutPtr();
    outError = allocOutPtr();
    const tag = wasm.monty_repl_feed_run(handle, cCode.ptr, outResult.ptr, outError.ptr);

    const resultPtr = outResult.read();
    const errorPtr = outError.read();
    const resultJson = readAndFreeCString(resultPtr);
    const errorMsg = readAndFreeCString(errorPtr);

    if (tag === RESULT_OK && resultJson) {
      const adapted = adaptResultForDart(resultJson, false);
      self.postMessage({ type: 'result', id, ...adapted });
    } else if (resultJson) {
      const adapted = adaptResultForDart(resultJson, true);
      self.postMessage({ type: 'result', id, ...adapted });
    } else {
      self.postMessage({ type: 'result', id, ok: false, error: errorMsg || 'repl_feed_run failed', errorType: 'MontyException' });
    }
  } finally {
    if (cCode) wasm.monty_dealloc(cCode.ptr, cCode.size);
    if (outResult) outResult.free();
    if (outError) outError.free();
  }
}

function handleReplFeedStart(id, replId, code) {
  const handle = replHandles.get(replId);
  if (!handle) {
    self.postMessage({ type: 'result', id, ok: false,
      error: `No REPL session for replId: ${replId}`, errorType: 'StateError' });
    return;
  }
  let cCode = null;
  let outError = null;
  try {
    cCode = allocCString(code);
    outError = allocOutPtr();
    const tag = wasm.monty_repl_feed_start(handle, cCode.ptr, outError.ptr);
    const errPtr = outError.read();
    const errMsg = readAndFreeCString(errPtr);
    self.postMessage(readProgress(id, handle, tag, errMsg, REPL_PROGRESS));
  } finally {
    if (cCode) wasm.monty_dealloc(cCode.ptr, cCode.size);
    if (outError) outError.free();
  }
}

function handleReplSetExtFns(id, replId, extFns) {
  const handle = replHandles.get(replId);
  if (!handle) {
    self.postMessage({ type: 'result', id, ok: false,
      error: `No REPL session for replId: ${replId}`, errorType: 'StateError' });
    return;
  }
  let cExtFns = null;
  try {
    cExtFns = extFns && extFns.length > 0 ? allocCString(extFns.join(',')) : null;
    wasm.monty_repl_set_ext_fns(handle, cExtFns ? cExtFns.ptr : 0);
    self.postMessage({ type: 'result', id, ok: true });
  } finally {
    if (cExtFns) wasm.monty_dealloc(cExtFns.ptr, cExtFns.size);
  }
}

function handleReplResume(id, replId, value) {
  const handle = replHandles.get(replId);
  if (!handle) {
    self.postMessage({ type: 'result', id, ok: false,
      error: `No REPL session for replId: ${replId}`, errorType: 'StateError' });
    return;
  }
  let cVal = null;
  let outError = null;
  try {
    cVal = allocCString(JSON.stringify(value));
    outError = allocOutPtr();
    const tag = wasm.monty_repl_resume(handle, cVal.ptr, outError.ptr);
    const errPtr = outError.read();
    const errMsg = readAndFreeCString(errPtr);
    self.postMessage(readProgress(id, handle, tag, errMsg, REPL_PROGRESS));
  } finally {
    if (cVal) wasm.monty_dealloc(cVal.ptr, cVal.size);
    if (outError) outError.free();
  }
}

function handleReplResumeWithError(id, replId, errorMessage) {
  const handle = replHandles.get(replId);
  if (!handle) {
    self.postMessage({ type: 'result', id, ok: false,
      error: `No REPL session for replId: ${replId}`, errorType: 'StateError' });
    return;
  }
  let cErr = null;
  let outError = null;
  try {
    cErr = allocCString(errorMessage);
    outError = allocOutPtr();
    const tag = wasm.monty_repl_resume_with_error(handle, cErr.ptr, outError.ptr);
    const errPtr = outError.read();
    const errMsg = readAndFreeCString(errPtr);
    self.postMessage(readProgress(id, handle, tag, errMsg, REPL_PROGRESS));
  } finally {
    if (cErr) wasm.monty_dealloc(cErr.ptr, cErr.size);
    if (outError) outError.free();
  }
}

function handleReplResumeNotFound(id, replId, fnName) {
  const handle = replHandles.get(replId);
  if (!handle) {
    self.postMessage({ type: 'result', id, ok: false,
      error: `No REPL session for replId: ${replId}`, errorType: 'StateError' });
    return;
  }
  let cFnName = null;
  let outError = null;
  try {
    cFnName = allocCString(fnName);
    outError = allocOutPtr();
    const tag = wasm.monty_repl_resume_not_found(handle, cFnName.ptr, outError.ptr);
    const errPtr = outError.read();
    const errMsg = readAndFreeCString(errPtr);
    self.postMessage(readProgress(id, handle, tag, errMsg, REPL_PROGRESS));
  } finally {
    if (cFnName) wasm.monty_dealloc(cFnName.ptr, cFnName.size);
    if (outError) outError.free();
  }
}

function handleReplDetectContinuation(id, source) {
  let cSource = null;
  try {
    cSource = allocCString(source);
    const mode = wasm.monty_repl_detect_continuation(cSource.ptr);
    self.postMessage({ type: 'result', id, ok: true, value: mode });
  } finally {
    if (cSource) wasm.monty_dealloc(cSource.ptr, cSource.size);
  }
}

function handleReplDispose(id, replId) {
  const handle = replHandles.get(replId);
  if (!handle) {
    self.postMessage({ type: 'result', id, ok: false,
      error: `No REPL session for replId: ${replId}`, errorType: 'StateError' });
    return;
  }
  wasm.monty_repl_free(handle);
  replHandles.delete(replId);
  self.postMessage({ type: 'result', id, ok: true });
}

function handleReplSnapshot(id, replId) {
  const handle = replHandles.get(replId);
  if (!handle) {
    self.postMessage({
      type: 'result', id, ok: false,
      error: `No REPL session for replId: ${replId}`,
      errorType: 'StateError',
    });
    return;
  }

  const outLen = allocOutPtr();
  let ptr;
  try {
    ptr = wasm.monty_repl_snapshot(handle, outLen.ptr);
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
      error: 'monty_repl_snapshot returned null — REPL may be mid-execution',
      errorType: 'StateError',
    });
    return;
  }

  const len = outLen.read();
  outLen.free();

  const wasmBytes = new Uint8Array(wasm.memory.buffer, ptr, len);
  let copy;
  try {
    copy = wasmBytes.slice();
  } finally {
    wasm.monty_bytes_free(ptr, len);
  }

  self.postMessage(
    { type: 'result', id, ok: true, snapshotBuffer: copy.buffer },
    [copy.buffer],
  );
}

function handleReplRestore(id, replId, dataBase64) {
  // Free existing handle for this replId, if any.
  const existing = replHandles.get(replId);
  if (existing) {
    wasm.monty_repl_free(existing);
    replHandles.delete(replId);
  }

  // Decode base64 to Uint8Array.
  const binary = atob(dataBase64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }

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
    handle = wasm.monty_repl_restore(ptr, bytes.length, outError.ptr);
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
      error: errMsg || 'monty_repl_restore failed',
      errorType: 'RestoreError',
    });
    return;
  }
  outError.free();
  replHandles.set(replId, handle);
  self.postMessage({ type: 'result', id, ok: true });
}

// ---------------------------------------------------------------------------
// Message dispatch
// ---------------------------------------------------------------------------

self.onmessage = (e) => {
  const { type, id, code, extFns, value, errorMessage, excType, fnName, limits,
    dataBase64, scriptName, resultsJson, errorsJson, valueJson, source,
    replId } = e.data;
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
      case 'resumeWithException':
        handleResumeWithException(id, excType, errorMessage);
        break;
      case 'resumeNotFound':
        handleResumeNotFound(id, fnName);
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
      case 'compile':
        handleCompile(id, code, scriptName);
        break;
      case 'runPrecompiled':
        handleRunPrecompiled(id, dataBase64, limits, scriptName);
        break;
      case 'startPrecompiled':
        handleStartPrecompiled(id, dataBase64, limits, scriptName);
        break;
      case 'resumeNameLookupValue':
        handleResumeNameLookupValue(id, valueJson);
        break;
      case 'resumeNameLookupUndefined':
        handleResumeNameLookupUndefined(id);
        break;
      case 'dispose':
        handleDispose(id);
        break;
      case 'replCreate':
        handleReplCreate(id, replId, scriptName);
        break;
      case 'replFeedRun':
        handleReplFeedRun(id, replId, code);
        break;
      case 'replFeedStart':
        handleReplFeedStart(id, replId, code);
        break;
      case 'replSetExtFns':
        handleReplSetExtFns(id, replId, extFns);
        break;
      case 'replResume':
        handleReplResume(id, replId, value);
        break;
      case 'replResumeWithError':
        handleReplResumeWithError(id, replId, errorMessage);
        break;
      case 'replResumeNotFound':
        handleReplResumeNotFound(id, replId, fnName);
        break;
      case 'replDetectContinuation':
        handleReplDetectContinuation(id, source);
        break;
      case 'replDispose':
        handleReplDispose(id, replId);
        break;
      case 'replSnapshot':
        handleReplSnapshot(id, replId);
        break;
      case 'replRestore':
        handleReplRestore(id, replId, dataBase64);
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
