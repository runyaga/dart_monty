// src/wasm_glue.js
function createWasiImports(getMemory) {
  return {
    random_get(buf, bufLen) {
      const mem = new Uint8Array(getMemory().buffer);
      for (let i = 0; i < bufLen; i += 65536) {
        const chunk = Math.min(65536, bufLen - i);
        crypto.getRandomValues(mem.subarray(buf + i, buf + i + chunk));
      }
      return 0;
    },
    // CLOCK_REALTIME = 0, CLOCK_MONOTONIC = 1
    clock_time_get(id, _precision, out) {
      const mem = new DataView(getMemory().buffer);
      let nowNs;
      if (id === 0) {
        nowNs = BigInt(Date.now()) * 1000000n;
      } else {
        nowNs = BigInt(Math.round(performance.now() * 1e6));
      }
      mem.setBigUint64(out, nowNs, true);
      return 0;
    },
    fd_write(fd, iovs, iovsLen, nwritten) {
      const mem = new DataView(getMemory().buffer);
      const bytes = new Uint8Array(getMemory().buffer);
      let totalWritten = 0;
      const parts = [];
      for (let i = 0; i < iovsLen; i++) {
        const ptr = mem.getUint32(iovs + i * 8, true);
        const len = mem.getUint32(iovs + i * 8 + 4, true);
        parts.push(new TextDecoder().decode(bytes.subarray(ptr, ptr + len)));
        totalWritten += len;
      }
      const text = parts.join("");
      if (fd === 1) console.log("[monty]", text);
      else if (fd === 2) console.warn("[monty]", text);
      mem.setUint32(nwritten, totalWritten, true);
      return 0;
    },
    environ_get() {
      return 0;
    },
    environ_sizes_get(countOut, bufsizeOut) {
      const mem = new DataView(getMemory().buffer);
      mem.setUint32(countOut, 0, true);
      mem.setUint32(bufsizeOut, 0, true);
      return 0;
    },
    proc_exit(code) {
      throw new Error(`WASI proc_exit called with code ${code}`);
    }
  };
}
var wasm = null;
async function instantiateMonty(wasmUrl) {
  let memory;
  const wasiImports = createWasiImports(() => memory);
  const imports = { wasi_snapshot_preview1: wasiImports };
  let instance;
  try {
    const result = await WebAssembly.instantiateStreaming(
      fetch(wasmUrl),
      imports
    );
    instance = result.instance;
  } catch (e) {
    if (e instanceof TypeError || e.message && e.message.includes("Mime")) {
      const resp = await fetch(wasmUrl);
      const bytes = await resp.arrayBuffer();
      const result = await WebAssembly.instantiate(bytes, imports);
      instance = result.instance;
    } else {
      throw e;
    }
  }
  wasm = instance.exports;
  memory = wasm.memory;
  return wasm;
}
var encoder = new TextEncoder();
var decoder = new TextDecoder();
function allocCString(str) {
  const encoded = encoder.encode(str);
  const size = encoded.length + 1;
  const ptr = wasm.monty_alloc(size);
  if (ptr === 0) throw new Error(`monty_alloc(${size}) returned null \u2014 OOM`);
  const mem = new Uint8Array(wasm.memory.buffer);
  mem.set(encoded, ptr);
  mem[ptr + encoded.length] = 0;
  return { ptr, size };
}
function readCString(ptr) {
  if (ptr === 0) return null;
  const mem = new Uint8Array(wasm.memory.buffer);
  let end = ptr;
  while (end < mem.length && mem[end] !== 0) end++;
  return decoder.decode(mem.subarray(ptr, end));
}
function readAndFreeCString(ptr) {
  if (ptr === 0) return null;
  const str = readCString(ptr);
  wasm.monty_string_free(ptr);
  return str;
}
function allocOutPtr() {
  const ptr = wasm.monty_alloc(4);
  if (ptr === 0) throw new Error("monty_alloc(4) returned null \u2014 OOM");
  return {
    ptr,
    read() {
      return new DataView(wasm.memory.buffer).getUint32(ptr, true);
    },
    free() {
      wasm.monty_dealloc(ptr, 4);
    }
  };
}
var PROGRESS_COMPLETE = 0;
var PROGRESS_PENDING = 1;
var PROGRESS_ERROR = 2;
var PROGRESS_RESOLVE_FUTURES = 3;
var PROGRESS_OS_CALL = 4;
var PROGRESS_NAME_LOOKUP = 5;
var RESULT_OK = 0;

// src/worker_src.js
var wasm2 = null;
async function initWasm() {
  const wasmUrl = new URL("./dart_monty_core_native.wasm", import.meta.url);
  wasm2 = await instantiateMonty(wasmUrl);
  self.postMessage({
    type: "ready",
    exports: Object.keys(wasm2).filter((k) => k.startsWith("monty_"))
  });
}
function adaptResultForDart(cabiResultJson, isError) {
  const parsed = JSON.parse(cabiResultJson);
  if (isError) {
    const err = parsed.error && typeof parsed.error === "object" ? parsed.error : { message: parsed.error ? String(parsed.error) : "Unknown error" };
    return {
      ok: false,
      error: err.message || String(err),
      errorType: err.exc_type || "MontyException",
      excType: err.exc_type || null,
      traceback: err.traceback || null
    };
  }
  return {
    ok: true,
    value: parsed.value,
    print_output: parsed.print_output || null
  };
}
function excTypeFromMsg(msg) {
  if (!msg) return null;
  const colon = msg.indexOf(":");
  if (colon <= 0) return null;
  const prefix = msg.substring(0, colon).trim();
  return /^[A-Z][A-Za-z]+$/.test(prefix) ? prefix : null;
}
var SESSION_PROGRESS = {
  completeIsError: (h) => wasm2.monty_complete_is_error(h),
  completeResultJson: (h) => wasm2.monty_complete_result_json(h),
  pendingFnName: (h) => wasm2.monty_pending_fn_name(h),
  pendingFnArgsJson: (h) => wasm2.monty_pending_fn_args_json(h),
  pendingFnKwargsJson: (h) => wasm2.monty_pending_fn_kwargs_json(h),
  pendingCallId: (h) => wasm2.monty_pending_call_id(h),
  pendingMethodCall: (h) => wasm2.monty_pending_method_call(h),
  pendingFutureCallIds: (h) => wasm2.monty_pending_future_call_ids(h),
  osCallFnName: (h) => wasm2.monty_os_call_fn_name(h),
  osCallArgsJson: (h) => wasm2.monty_os_call_args_json(h),
  osCallKwargsJson: (h) => wasm2.monty_os_call_kwargs_json(h),
  osCallId: (h) => wasm2.monty_os_call_id(h),
  nameLookupName: (h) => wasm2.monty_name_lookup_name(h)
};
var REPL_PROGRESS = {
  completeIsError: (h) => wasm2.monty_repl_complete_is_error(h),
  completeResultJson: (h) => wasm2.monty_repl_complete_result_json(h),
  pendingFnName: (h) => wasm2.monty_repl_pending_fn_name(h),
  pendingFnArgsJson: (h) => wasm2.monty_repl_pending_fn_args_json(h),
  pendingFnKwargsJson: (h) => wasm2.monty_repl_pending_fn_kwargs_json(h),
  pendingCallId: (h) => wasm2.monty_repl_pending_call_id(h),
  pendingMethodCall: (h) => wasm2.monty_repl_pending_method_call(h),
  pendingFutureCallIds: (h) => wasm2.monty_repl_pending_future_call_ids(h),
  osCallFnName: (h) => wasm2.monty_repl_os_call_fn_name(h),
  osCallArgsJson: (h) => wasm2.monty_repl_os_call_args_json(h),
  osCallKwargsJson: (h) => wasm2.monty_repl_os_call_kwargs_json(h),
  osCallId: (h) => wasm2.monty_repl_os_call_id(h),
  // REPL auto-resolves NameLookup internally (process_repl_progress loop);
  // PROGRESS_NAME_LOOKUP never surfaces to JS for REPL handles.
  nameLookupName: null
};
function readProgress(id, handle, tag, errMsg, api) {
  switch (tag) {
    case PROGRESS_COMPLETE: {
      const isErr = api.completeIsError(handle);
      const ptr = api.completeResultJson(handle);
      const json = readAndFreeCString(ptr);
      if (json) {
        const adapted = adaptResultForDart(json, isErr === 1);
        return { type: "result", id, ...adapted, state: adapted.ok ? "complete" : void 0 };
      }
      if (isErr === 1) {
        return {
          type: "result",
          id,
          ok: false,
          error: "Execution failed (no error context)",
          errorType: "MontyException"
        };
      }
      return { type: "result", id, ok: true, state: "complete", value: null };
    }
    case PROGRESS_PENDING: {
      const fnName = readAndFreeCString(api.pendingFnName(handle));
      const argsJson = readAndFreeCString(api.pendingFnArgsJson(handle));
      const kwargsJson = readAndFreeCString(api.pendingFnKwargsJson(handle));
      const callId = api.pendingCallId(handle);
      const methodCall = api.pendingMethodCall(handle);
      return {
        type: "result",
        id,
        ok: true,
        state: "pending",
        functionName: fnName,
        args: argsJson ? JSON.parse(argsJson) : [],
        kwargs: kwargsJson ? JSON.parse(kwargsJson) : {},
        callId,
        methodCall: methodCall === 1
      };
    }
    case PROGRESS_RESOLVE_FUTURES: {
      const idsPtr = api.pendingFutureCallIds(handle);
      const idsJson = readAndFreeCString(idsPtr);
      return {
        type: "result",
        id,
        ok: true,
        state: "resolve_futures",
        pendingCallIds: idsJson ? JSON.parse(idsJson) : []
      };
    }
    case PROGRESS_OS_CALL: {
      const fnName = readAndFreeCString(api.osCallFnName(handle));
      const argsJson = readAndFreeCString(api.osCallArgsJson(handle));
      const kwargsJson = readAndFreeCString(api.osCallKwargsJson(handle));
      const callId = api.osCallId(handle);
      return {
        type: "result",
        id,
        ok: true,
        state: "os_call",
        functionName: fnName,
        args: argsJson ? JSON.parse(argsJson) : [],
        kwargs: kwargsJson ? JSON.parse(kwargsJson) : {},
        callId
      };
    }
    case PROGRESS_NAME_LOOKUP: {
      if (!api.nameLookupName) {
        return {
          type: "result",
          id,
          ok: false,
          error: "Unexpected PROGRESS_NAME_LOOKUP for REPL handle",
          errorType: "InternalError"
        };
      }
      const namePtr = api.nameLookupName(handle);
      const variableName = readAndFreeCString(namePtr);
      return {
        type: "result",
        id,
        ok: true,
        state: "name_lookup",
        variableName
      };
    }
    case PROGRESS_ERROR: {
      const isErrState = api.completeIsError(handle);
      const errPtr2 = api.completeResultJson(handle);
      const errJson = readAndFreeCString(errPtr2);
      if (errJson && isErrState === 1) {
        const adapted = adaptResultForDart(errJson, true);
        return { type: "result", id, ...adapted };
      }
      return {
        type: "result",
        id,
        ok: false,
        error: errMsg || "Unknown error",
        errorType: "MontyException",
        excType: excTypeFromMsg(errMsg)
      };
    }
    default:
      return {
        type: "result",
        id,
        ok: false,
        error: `Unknown progress tag: ${tag}`,
        errorType: "InternalError"
      };
  }
}
var activeHandle = null;
function handleRun(id, code, limits, scriptName) {
  let cCode = null;
  let cName = null;
  let outError = null;
  let handle;
  try {
    outError = allocOutPtr();
    cCode = allocCString(code);
    cName = scriptName ? allocCString(scriptName) : null;
    handle = wasm2.monty_create(cCode.ptr, 0, cName ? cName.ptr : 0, outError.ptr);
  } catch (e) {
    if (outError) outError.free();
    throw e;
  } finally {
    if (cCode) wasm2.monty_dealloc(cCode.ptr, cCode.size);
    if (cName) wasm2.monty_dealloc(cName.ptr, cName.size);
  }
  if (handle === 0) {
    const errPtr = outError.read();
    const errMsg = readAndFreeCString(errPtr);
    outError.free();
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: errMsg || "monty_create failed",
      errorType: "CompileError",
      excType: excTypeFromMsg(errMsg)
    });
    return;
  }
  outError.free();
  if (limits) {
    if (limits.memory_bytes != null) wasm2.monty_set_memory_limit(handle, limits.memory_bytes);
    if (limits.timeout_ms != null) wasm2.monty_set_time_limit_ms(handle, BigInt(limits.timeout_ms));
    if (limits.stack_depth != null) wasm2.monty_set_stack_limit(handle, limits.stack_depth);
  }
  let outResult = null;
  let outErrMsg = null;
  let resultTag;
  try {
    outResult = allocOutPtr();
    outErrMsg = allocOutPtr();
    resultTag = wasm2.monty_run(handle, outResult.ptr, outErrMsg.ptr);
  } catch (e) {
    if (outResult) outResult.free();
    if (outErrMsg) outErrMsg.free();
    wasm2.monty_free(handle);
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: e.message || String(e),
      errorType: "Panic"
    });
    return;
  }
  const resultPtr = outResult.read();
  const errorPtr = outErrMsg.read();
  const resultJson = readAndFreeCString(resultPtr);
  const errorMsg = readAndFreeCString(errorPtr);
  outResult.free();
  outErrMsg.free();
  wasm2.monty_free(handle);
  if (resultTag === RESULT_OK && resultJson) {
    const adapted = adaptResultForDart(resultJson, false);
    self.postMessage({ type: "result", id, ...adapted });
  } else if (resultJson) {
    const adapted = adaptResultForDart(resultJson, true);
    self.postMessage({ type: "result", id, ...adapted });
  } else {
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: errorMsg || "monty_run failed",
      errorType: "MontyException"
    });
  }
}
function handleStart(id, code, extFns, limits, scriptName) {
  if (activeHandle) {
    wasm2.monty_free(activeHandle);
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
    cExtFns = extFns && extFns.length > 0 ? allocCString(extFns.join(",")) : null;
    cName = scriptName ? allocCString(scriptName) : null;
    handle = wasm2.monty_create(
      cCode.ptr,
      cExtFns ? cExtFns.ptr : 0,
      cName ? cName.ptr : 0,
      outError.ptr
    );
  } catch (e) {
    if (outError) outError.free();
    throw e;
  } finally {
    if (cCode) wasm2.monty_dealloc(cCode.ptr, cCode.size);
    if (cExtFns) wasm2.monty_dealloc(cExtFns.ptr, cExtFns.size);
    if (cName) wasm2.monty_dealloc(cName.ptr, cName.size);
  }
  if (handle === 0) {
    const errPtr2 = outError.read();
    const errMsg2 = readAndFreeCString(errPtr2);
    outError.free();
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: errMsg2 || "monty_create failed",
      errorType: "CompileError",
      excType: excTypeFromMsg(errMsg2)
    });
    return;
  }
  outError.free();
  if (limits) {
    if (limits.memory_bytes != null) wasm2.monty_set_memory_limit(handle, limits.memory_bytes);
    if (limits.timeout_ms != null) wasm2.monty_set_time_limit_ms(handle, BigInt(limits.timeout_ms));
    if (limits.stack_depth != null) wasm2.monty_set_stack_limit(handle, limits.stack_depth);
  }
  activeHandle = handle;
  let outErr;
  let tag;
  try {
    outErr = allocOutPtr();
    tag = wasm2.monty_start(handle, outErr.ptr);
  } catch (e) {
    if (outErr) outErr.free();
    activeHandle = null;
    wasm2.monty_free(handle);
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: e.message || String(e),
      errorType: "Panic"
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
    wasm2.monty_free(handle);
    throw e;
  }
  if (tag === PROGRESS_COMPLETE || tag === PROGRESS_ERROR) {
    activeHandle = null;
    wasm2.monty_free(handle);
  }
  self.postMessage(msg);
}
function handleResume(id, value) {
  if (!activeHandle) {
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: "No active handle to resume.",
      errorType: "StateError"
    });
    return;
  }
  let cVal = null;
  let outErr = null;
  let tag;
  try {
    cVal = allocCString(JSON.stringify(value));
    outErr = allocOutPtr();
    tag = wasm2.monty_resume(activeHandle, cVal.ptr, outErr.ptr);
  } catch (e) {
    if (cVal) wasm2.monty_dealloc(cVal.ptr, cVal.size);
    if (outErr) outErr.free();
    wasm2.monty_free(activeHandle);
    activeHandle = null;
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: e.message || String(e),
      errorType: "Panic"
    });
    return;
  }
  wasm2.monty_dealloc(cVal.ptr, cVal.size);
  const errPtr = outErr.read();
  const errMsg = readAndFreeCString(errPtr);
  outErr.free();
  let msg;
  try {
    msg = readProgress(id, activeHandle, tag, errMsg, SESSION_PROGRESS);
  } catch (e) {
    wasm2.monty_free(activeHandle);
    activeHandle = null;
    throw e;
  }
  if (tag === PROGRESS_COMPLETE || tag === PROGRESS_ERROR) {
    wasm2.monty_free(activeHandle);
    activeHandle = null;
  }
  self.postMessage(msg);
}
function handleResumeWithError(id, errorMessage) {
  if (!activeHandle) {
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: "No active handle to resume.",
      errorType: "StateError"
    });
    return;
  }
  let cErr = null;
  let outErr = null;
  let tag;
  try {
    cErr = allocCString(errorMessage);
    outErr = allocOutPtr();
    tag = wasm2.monty_resume_with_error(activeHandle, cErr.ptr, outErr.ptr);
  } catch (e) {
    if (cErr) wasm2.monty_dealloc(cErr.ptr, cErr.size);
    if (outErr) outErr.free();
    wasm2.monty_free(activeHandle);
    activeHandle = null;
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: e.message || String(e),
      errorType: "Panic"
    });
    return;
  }
  wasm2.monty_dealloc(cErr.ptr, cErr.size);
  const errPtr = outErr.read();
  const errMsg = readAndFreeCString(errPtr);
  outErr.free();
  let msg;
  try {
    msg = readProgress(id, activeHandle, tag, errMsg, SESSION_PROGRESS);
  } catch (e) {
    wasm2.monty_free(activeHandle);
    activeHandle = null;
    throw e;
  }
  if (tag === PROGRESS_COMPLETE || tag === PROGRESS_ERROR) {
    wasm2.monty_free(activeHandle);
    activeHandle = null;
  }
  self.postMessage(msg);
}
function handleResumeWithException(id, excType, errorMessage) {
  if (!activeHandle) {
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: "No active handle to resume.",
      errorType: "StateError"
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
    tag = wasm2.monty_resume_with_exception(activeHandle, cExcType.ptr, cErr.ptr, outErr.ptr);
  } catch (e) {
    if (cExcType) wasm2.monty_dealloc(cExcType.ptr, cExcType.size);
    if (cErr) wasm2.monty_dealloc(cErr.ptr, cErr.size);
    if (outErr) outErr.free();
    wasm2.monty_free(activeHandle);
    activeHandle = null;
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: e.message || String(e),
      errorType: "Panic"
    });
    return;
  }
  wasm2.monty_dealloc(cExcType.ptr, cExcType.size);
  wasm2.monty_dealloc(cErr.ptr, cErr.size);
  const errPtr = outErr.read();
  const errMsg = readAndFreeCString(errPtr);
  outErr.free();
  let msg;
  try {
    msg = readProgress(id, activeHandle, tag, errMsg, SESSION_PROGRESS);
  } catch (e) {
    wasm2.monty_free(activeHandle);
    activeHandle = null;
    throw e;
  }
  if (tag === PROGRESS_COMPLETE || tag === PROGRESS_ERROR) {
    wasm2.monty_free(activeHandle);
    activeHandle = null;
  }
  self.postMessage(msg);
}
function handleResumeNotFound(id, fnName) {
  if (!activeHandle) {
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: "No active handle to resume.",
      errorType: "StateError"
    });
    return;
  }
  let cFnName = null;
  let outErr = null;
  let tag;
  try {
    cFnName = allocCString(fnName);
    outErr = allocOutPtr();
    tag = wasm2.monty_resume_not_found(activeHandle, cFnName.ptr, outErr.ptr);
  } catch (e) {
    if (cFnName) wasm2.monty_dealloc(cFnName.ptr, cFnName.size);
    if (outErr) outErr.free();
    wasm2.monty_free(activeHandle);
    activeHandle = null;
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: e.message || String(e),
      errorType: "Panic"
    });
    return;
  }
  wasm2.monty_dealloc(cFnName.ptr, cFnName.size);
  const errPtr = outErr.read();
  const errMsg = readAndFreeCString(errPtr);
  outErr.free();
  let msg;
  try {
    msg = readProgress(id, activeHandle, tag, errMsg, SESSION_PROGRESS);
  } catch (e) {
    wasm2.monty_free(activeHandle);
    activeHandle = null;
    throw e;
  }
  if (tag === PROGRESS_COMPLETE || tag === PROGRESS_ERROR) {
    wasm2.monty_free(activeHandle);
    activeHandle = null;
  }
  self.postMessage(msg);
}
function handleResumeAsFuture(id) {
  if (!activeHandle) {
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: "No active handle for resumeAsFuture.",
      errorType: "StateError"
    });
    return;
  }
  const outErr = allocOutPtr();
  let tag;
  try {
    tag = wasm2.monty_resume_as_future(activeHandle, outErr.ptr);
  } catch (e) {
    outErr.free();
    wasm2.monty_free(activeHandle);
    activeHandle = null;
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: e.message || String(e),
      errorType: "Panic"
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
    wasm2.monty_free(activeHandle);
    activeHandle = null;
    throw e;
  }
  if (tag === PROGRESS_COMPLETE || tag === PROGRESS_ERROR) {
    wasm2.monty_free(activeHandle);
    activeHandle = null;
  }
  self.postMessage(msg);
}
function handleResolveFutures(id, resultsJson, errorsJson) {
  if (!activeHandle) {
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: "No active handle for resolveFutures.",
      errorType: "StateError"
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
    tag = wasm2.monty_resume_futures(activeHandle, cResults.ptr, cErrors.ptr, outErr.ptr);
  } catch (e) {
    if (cResults) wasm2.monty_dealloc(cResults.ptr, cResults.size);
    if (cErrors) wasm2.monty_dealloc(cErrors.ptr, cErrors.size);
    if (outErr) outErr.free();
    wasm2.monty_free(activeHandle);
    activeHandle = null;
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: e.message || String(e),
      errorType: "Panic"
    });
    return;
  }
  wasm2.monty_dealloc(cResults.ptr, cResults.size);
  wasm2.monty_dealloc(cErrors.ptr, cErrors.size);
  const errPtr = outErr.read();
  const errMsg = readAndFreeCString(errPtr);
  outErr.free();
  let msg;
  try {
    msg = readProgress(id, activeHandle, tag, errMsg, SESSION_PROGRESS);
  } catch (e) {
    wasm2.monty_free(activeHandle);
    activeHandle = null;
    throw e;
  }
  if (tag === PROGRESS_COMPLETE || tag === PROGRESS_ERROR) {
    wasm2.monty_free(activeHandle);
    activeHandle = null;
  }
  self.postMessage(msg);
}
function handleSnapshot(id) {
  if (!activeHandle) {
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: "No active handle to snapshot.",
      errorType: "StateError"
    });
    return;
  }
  const outLen = allocOutPtr();
  let ptr;
  try {
    ptr = wasm2.monty_snapshot(activeHandle, outLen.ptr);
  } catch (e) {
    outLen.free();
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: e.message || String(e),
      errorType: "Panic"
    });
    return;
  }
  if (ptr === 0) {
    outLen.free();
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: "monty_snapshot returned null",
      errorType: "StateError"
    });
    return;
  }
  const len = outLen.read();
  outLen.free();
  const wasmBytes = new Uint8Array(wasm2.memory.buffer, ptr, len);
  let copy;
  try {
    copy = wasmBytes.slice();
  } finally {
    wasm2.monty_bytes_free(ptr, len);
  }
  self.postMessage(
    { type: "result", id, ok: true, snapshotBuffer: copy.buffer },
    [copy.buffer]
  );
}
function handleRestore(id, dataBase64) {
  if (activeHandle) {
    wasm2.monty_free(activeHandle);
    activeHandle = null;
  }
  const binary = atob(dataBase64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  const outError = allocOutPtr();
  const ptr = wasm2.monty_alloc(bytes.length);
  if (ptr === 0) {
    outError.free();
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: `monty_alloc(${bytes.length}) returned null \u2014 OOM`,
      errorType: "MemoryError"
    });
    return;
  }
  new Uint8Array(wasm2.memory.buffer).set(bytes, ptr);
  let handle;
  try {
    handle = wasm2.monty_restore(ptr, bytes.length, outError.ptr);
  } catch (e) {
    outError.free();
    throw e;
  } finally {
    wasm2.monty_dealloc(ptr, bytes.length);
  }
  if (handle === 0) {
    const errPtr = outError.read();
    const errMsg = readAndFreeCString(errPtr);
    outError.free();
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: errMsg || "monty_restore failed",
      errorType: "RestoreError"
    });
    return;
  }
  outError.free();
  activeHandle = handle;
  self.postMessage({ type: "result", id, ok: true });
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
    handle = wasm2.monty_create(cCode.ptr, 0, cName ? cName.ptr : 0, outError.ptr);
  } catch (e) {
    if (outError) outError.free();
    throw e;
  } finally {
    if (cCode) wasm2.monty_dealloc(cCode.ptr, cCode.size);
    if (cName) wasm2.monty_dealloc(cName.ptr, cName.size);
  }
  if (handle === 0) {
    const errPtr = outError.read();
    const errMsg = readAndFreeCString(errPtr);
    outError.free();
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: errMsg || "monty_create failed",
      errorType: "CompileError",
      excType: excTypeFromMsg(errMsg)
    });
    return;
  }
  outError.free();
  const outLen = allocOutPtr();
  let ptr;
  try {
    ptr = wasm2.monty_snapshot(handle, outLen.ptr);
  } catch (e) {
    outLen.free();
    wasm2.monty_free(handle);
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: e.message || String(e),
      errorType: "Panic"
    });
    return;
  }
  wasm2.monty_free(handle);
  if (ptr === 0) {
    outLen.free();
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: "monty_snapshot returned null after compile",
      errorType: "StateError"
    });
    return;
  }
  const len = outLen.read();
  outLen.free();
  const wasmBytes = new Uint8Array(wasm2.memory.buffer, ptr, len);
  let copy;
  try {
    copy = wasmBytes.slice();
  } finally {
    wasm2.monty_bytes_free(ptr, len);
  }
  self.postMessage(
    { type: "result", id, ok: true, snapshotBuffer: copy.buffer },
    [copy.buffer]
  );
}
function handleRunPrecompiled(id, dataBase64, limits, scriptName) {
  const binary = atob(dataBase64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  const outError = allocOutPtr();
  const ptr = wasm2.monty_alloc(bytes.length);
  if (ptr === 0) {
    outError.free();
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: `monty_alloc(${bytes.length}) returned null \u2014 OOM`,
      errorType: "MemoryError"
    });
    return;
  }
  new Uint8Array(wasm2.memory.buffer).set(bytes, ptr);
  let handle;
  try {
    handle = wasm2.monty_restore(ptr, bytes.length, outError.ptr);
  } catch (e) {
    outError.free();
    throw e;
  } finally {
    wasm2.monty_dealloc(ptr, bytes.length);
  }
  if (handle === 0) {
    const errPtr = outError.read();
    const errMsg = readAndFreeCString(errPtr);
    outError.free();
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: errMsg || "monty_restore failed",
      errorType: "RestoreError"
    });
    return;
  }
  outError.free();
  if (limits) {
    if (limits.memory_bytes != null) wasm2.monty_set_memory_limit(handle, limits.memory_bytes);
    if (limits.timeout_ms != null) wasm2.monty_set_time_limit_ms(handle, BigInt(limits.timeout_ms));
    if (limits.stack_depth != null) wasm2.monty_set_stack_limit(handle, limits.stack_depth);
  }
  let outResult = null;
  let outErrMsg = null;
  let resultTag;
  try {
    outResult = allocOutPtr();
    outErrMsg = allocOutPtr();
    resultTag = wasm2.monty_run(handle, outResult.ptr, outErrMsg.ptr);
  } catch (e) {
    if (outResult) outResult.free();
    if (outErrMsg) outErrMsg.free();
    wasm2.monty_free(handle);
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: e.message || String(e),
      errorType: "Panic"
    });
    return;
  }
  const resultPtr = outResult.read();
  const errorPtr = outErrMsg.read();
  const resultJson = readAndFreeCString(resultPtr);
  const errorMsg = readAndFreeCString(errorPtr);
  outResult.free();
  outErrMsg.free();
  wasm2.monty_free(handle);
  if (resultTag === RESULT_OK && resultJson) {
    const adapted = adaptResultForDart(resultJson, false);
    self.postMessage({ type: "result", id, ...adapted });
  } else if (resultJson) {
    const adapted = adaptResultForDart(resultJson, true);
    self.postMessage({ type: "result", id, ...adapted });
  } else {
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: errorMsg || "monty_run failed",
      errorType: "MontyException"
    });
  }
}
function handleStartPrecompiled(id, dataBase64, limits, scriptName) {
  if (activeHandle) {
    wasm2.monty_free(activeHandle);
    activeHandle = null;
  }
  const binary = atob(dataBase64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  const outError = allocOutPtr();
  const ptr = wasm2.monty_alloc(bytes.length);
  if (ptr === 0) {
    outError.free();
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: `monty_alloc(${bytes.length}) returned null \u2014 OOM`,
      errorType: "MemoryError"
    });
    return;
  }
  new Uint8Array(wasm2.memory.buffer).set(bytes, ptr);
  let handle;
  try {
    handle = wasm2.monty_restore(ptr, bytes.length, outError.ptr);
  } catch (e) {
    outError.free();
    throw e;
  } finally {
    wasm2.monty_dealloc(ptr, bytes.length);
  }
  if (handle === 0) {
    const errPtr2 = outError.read();
    const errMsg2 = readAndFreeCString(errPtr2);
    outError.free();
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: errMsg2 || "monty_restore failed",
      errorType: "RestoreError"
    });
    return;
  }
  outError.free();
  if (limits) {
    if (limits.memory_bytes != null) wasm2.monty_set_memory_limit(handle, limits.memory_bytes);
    if (limits.timeout_ms != null) wasm2.monty_set_time_limit_ms(handle, BigInt(limits.timeout_ms));
    if (limits.stack_depth != null) wasm2.monty_set_stack_limit(handle, limits.stack_depth);
  }
  activeHandle = handle;
  let outErr;
  let tag;
  try {
    outErr = allocOutPtr();
    tag = wasm2.monty_start(handle, outErr.ptr);
  } catch (e) {
    if (outErr) outErr.free();
    activeHandle = null;
    wasm2.monty_free(handle);
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: e.message || String(e),
      errorType: "Panic"
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
    wasm2.monty_free(handle);
    throw e;
  }
  if (tag === PROGRESS_COMPLETE || tag === PROGRESS_ERROR) {
    activeHandle = null;
    wasm2.monty_free(handle);
  }
  self.postMessage(msg);
}
function handleResumeNameLookupValue(id, valueJson) {
  if (!activeHandle) {
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: "No active handle for resumeNameLookupValue.",
      errorType: "StateError"
    });
    return;
  }
  let cVal = null;
  let outErr = null;
  let tag;
  try {
    cVal = allocCString(valueJson);
    outErr = allocOutPtr();
    tag = wasm2.monty_resume_name_lookup_value(activeHandle, cVal.ptr, outErr.ptr);
  } catch (e) {
    if (cVal) wasm2.monty_dealloc(cVal.ptr, cVal.size);
    if (outErr) outErr.free();
    wasm2.monty_free(activeHandle);
    activeHandle = null;
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: e.message || String(e),
      errorType: "Panic"
    });
    return;
  }
  wasm2.monty_dealloc(cVal.ptr, cVal.size);
  const errPtr = outErr.read();
  const errMsg = readAndFreeCString(errPtr);
  outErr.free();
  let msg;
  try {
    msg = readProgress(id, activeHandle, tag, errMsg, SESSION_PROGRESS);
  } catch (e) {
    wasm2.monty_free(activeHandle);
    activeHandle = null;
    throw e;
  }
  if (tag === PROGRESS_COMPLETE || tag === PROGRESS_ERROR) {
    wasm2.monty_free(activeHandle);
    activeHandle = null;
  }
  self.postMessage(msg);
}
function handleResumeNameLookupUndefined(id) {
  if (!activeHandle) {
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: "No active handle for resumeNameLookupUndefined.",
      errorType: "StateError"
    });
    return;
  }
  const outErr = allocOutPtr();
  let tag;
  try {
    tag = wasm2.monty_resume_name_lookup_undefined(activeHandle, outErr.ptr);
  } catch (e) {
    outErr.free();
    wasm2.monty_free(activeHandle);
    activeHandle = null;
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: e.message || String(e),
      errorType: "Panic"
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
    wasm2.monty_free(activeHandle);
    activeHandle = null;
    throw e;
  }
  if (tag === PROGRESS_COMPLETE || tag === PROGRESS_ERROR) {
    wasm2.monty_free(activeHandle);
    activeHandle = null;
  }
  self.postMessage(msg);
}
function handleDispose(id) {
  if (activeHandle) {
    wasm2.monty_free(activeHandle);
    activeHandle = null;
  }
  self.postMessage({ type: "result", id, ok: true });
}
var replHandles = /* @__PURE__ */ new Map();
function handleReplCreate(id, replId, scriptName) {
  if (!replId) {
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: "replId is required for replCreate",
      errorType: "StateError"
    });
    return;
  }
  let cName = null;
  let outError = null;
  let handle;
  try {
    outError = allocOutPtr();
    cName = scriptName ? allocCString(scriptName) : null;
    handle = wasm2.monty_repl_create(cName ? cName.ptr : 0, outError.ptr);
  } catch (e) {
    if (outError) outError.free();
    throw e;
  } finally {
    if (cName) wasm2.monty_dealloc(cName.ptr, cName.size);
  }
  if (handle === 0) {
    const errPtr = outError.read();
    const errMsg = readAndFreeCString(errPtr);
    outError.free();
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: errMsg || "monty_repl_create failed",
      errorType: "CompileError"
    });
    return;
  }
  outError.free();
  replHandles.set(replId, handle);
  self.postMessage({ type: "result", id, ok: true });
}
function handleReplFeedRun(id, replId, code) {
  const handle = replHandles.get(replId);
  if (!handle) {
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: `No REPL session for replId: ${replId}`,
      errorType: "StateError"
    });
    return;
  }
  let cCode = null;
  let outResult = null;
  let outError = null;
  try {
    cCode = allocCString(code);
    outResult = allocOutPtr();
    outError = allocOutPtr();
    const tag = wasm2.monty_repl_feed_run(handle, cCode.ptr, outResult.ptr, outError.ptr);
    const resultPtr = outResult.read();
    const errorPtr = outError.read();
    const resultJson = readAndFreeCString(resultPtr);
    const errorMsg = readAndFreeCString(errorPtr);
    if (tag === RESULT_OK && resultJson) {
      const adapted = adaptResultForDart(resultJson, false);
      self.postMessage({ type: "result", id, ...adapted });
    } else if (resultJson) {
      const adapted = adaptResultForDart(resultJson, true);
      self.postMessage({ type: "result", id, ...adapted });
    } else {
      self.postMessage({ type: "result", id, ok: false, error: errorMsg || "repl_feed_run failed", errorType: "MontyException" });
    }
  } finally {
    if (cCode) wasm2.monty_dealloc(cCode.ptr, cCode.size);
    if (outResult) outResult.free();
    if (outError) outError.free();
  }
}
function handleReplFeedStart(id, replId, code) {
  const handle = replHandles.get(replId);
  if (!handle) {
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: `No REPL session for replId: ${replId}`,
      errorType: "StateError"
    });
    return;
  }
  let cCode = null;
  let outError = null;
  try {
    cCode = allocCString(code);
    outError = allocOutPtr();
    const tag = wasm2.monty_repl_feed_start(handle, cCode.ptr, outError.ptr);
    const errPtr = outError.read();
    const errMsg = readAndFreeCString(errPtr);
    self.postMessage(readProgress(id, handle, tag, errMsg, REPL_PROGRESS));
  } finally {
    if (cCode) wasm2.monty_dealloc(cCode.ptr, cCode.size);
    if (outError) outError.free();
  }
}
function handleReplSetExtFns(id, replId, extFns) {
  const handle = replHandles.get(replId);
  if (!handle) {
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: `No REPL session for replId: ${replId}`,
      errorType: "StateError"
    });
    return;
  }
  let cExtFns = null;
  try {
    cExtFns = extFns && extFns.length > 0 ? allocCString(extFns.join(",")) : null;
    wasm2.monty_repl_set_ext_fns(handle, cExtFns ? cExtFns.ptr : 0);
    self.postMessage({ type: "result", id, ok: true });
  } finally {
    if (cExtFns) wasm2.monty_dealloc(cExtFns.ptr, cExtFns.size);
  }
}
function handleReplResume(id, replId, value) {
  const handle = replHandles.get(replId);
  if (!handle) {
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: `No REPL session for replId: ${replId}`,
      errorType: "StateError"
    });
    return;
  }
  let cVal = null;
  let outError = null;
  try {
    cVal = allocCString(JSON.stringify(value));
    outError = allocOutPtr();
    const tag = wasm2.monty_repl_resume(handle, cVal.ptr, outError.ptr);
    const errPtr = outError.read();
    const errMsg = readAndFreeCString(errPtr);
    self.postMessage(readProgress(id, handle, tag, errMsg, REPL_PROGRESS));
  } finally {
    if (cVal) wasm2.monty_dealloc(cVal.ptr, cVal.size);
    if (outError) outError.free();
  }
}
function handleReplResumeWithError(id, replId, errorMessage) {
  const handle = replHandles.get(replId);
  if (!handle) {
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: `No REPL session for replId: ${replId}`,
      errorType: "StateError"
    });
    return;
  }
  let cErr = null;
  let outError = null;
  try {
    cErr = allocCString(errorMessage);
    outError = allocOutPtr();
    const tag = wasm2.monty_repl_resume_with_error(handle, cErr.ptr, outError.ptr);
    const errPtr = outError.read();
    const errMsg = readAndFreeCString(errPtr);
    self.postMessage(readProgress(id, handle, tag, errMsg, REPL_PROGRESS));
  } finally {
    if (cErr) wasm2.monty_dealloc(cErr.ptr, cErr.size);
    if (outError) outError.free();
  }
}
function handleReplResumeNotFound(id, replId, fnName) {
  const handle = replHandles.get(replId);
  if (!handle) {
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: `No REPL session for replId: ${replId}`,
      errorType: "StateError"
    });
    return;
  }
  let cFnName = null;
  let outError = null;
  try {
    cFnName = allocCString(fnName);
    outError = allocOutPtr();
    const tag = wasm2.monty_repl_resume_not_found(handle, cFnName.ptr, outError.ptr);
    const errPtr = outError.read();
    const errMsg = readAndFreeCString(errPtr);
    self.postMessage(readProgress(id, handle, tag, errMsg, REPL_PROGRESS));
  } finally {
    if (cFnName) wasm2.monty_dealloc(cFnName.ptr, cFnName.size);
    if (outError) outError.free();
  }
}
function handleReplDetectContinuation(id, source) {
  let cSource = null;
  try {
    cSource = allocCString(source);
    const mode = wasm2.monty_repl_detect_continuation(cSource.ptr);
    self.postMessage({ type: "result", id, ok: true, value: mode });
  } finally {
    if (cSource) wasm2.monty_dealloc(cSource.ptr, cSource.size);
  }
}
function handleReplDispose(id, replId) {
  const handle = replHandles.get(replId);
  if (!handle) {
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: `No REPL session for replId: ${replId}`,
      errorType: "StateError"
    });
    return;
  }
  wasm2.monty_repl_free(handle);
  replHandles.delete(replId);
  self.postMessage({ type: "result", id, ok: true });
}
function handleReplSnapshot(id, replId) {
  const handle = replHandles.get(replId);
  if (!handle) {
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: `No REPL session for replId: ${replId}`,
      errorType: "StateError"
    });
    return;
  }
  const outLen = allocOutPtr();
  let ptr;
  try {
    ptr = wasm2.monty_repl_snapshot(handle, outLen.ptr);
  } catch (e) {
    outLen.free();
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: e.message || String(e),
      errorType: "Panic"
    });
    return;
  }
  if (ptr === 0) {
    outLen.free();
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: "monty_repl_snapshot returned null \u2014 REPL may be mid-execution",
      errorType: "StateError"
    });
    return;
  }
  const len = outLen.read();
  outLen.free();
  const wasmBytes = new Uint8Array(wasm2.memory.buffer, ptr, len);
  let copy;
  try {
    copy = wasmBytes.slice();
  } finally {
    wasm2.monty_bytes_free(ptr, len);
  }
  self.postMessage(
    { type: "result", id, ok: true, snapshotBuffer: copy.buffer },
    [copy.buffer]
  );
}
function handleReplRestore(id, replId, dataBase64) {
  const existing = replHandles.get(replId);
  if (existing) {
    wasm2.monty_repl_free(existing);
    replHandles.delete(replId);
  }
  const binary = atob(dataBase64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  const outError = allocOutPtr();
  const ptr = wasm2.monty_alloc(bytes.length);
  if (ptr === 0) {
    outError.free();
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: `monty_alloc(${bytes.length}) returned null \u2014 OOM`,
      errorType: "MemoryError"
    });
    return;
  }
  new Uint8Array(wasm2.memory.buffer).set(bytes, ptr);
  let handle;
  try {
    handle = wasm2.monty_repl_restore(ptr, bytes.length, outError.ptr);
  } catch (e) {
    outError.free();
    throw e;
  } finally {
    wasm2.monty_dealloc(ptr, bytes.length);
  }
  if (handle === 0) {
    const errPtr = outError.read();
    const errMsg = readAndFreeCString(errPtr);
    outError.free();
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: errMsg || "monty_repl_restore failed",
      errorType: "RestoreError"
    });
    return;
  }
  outError.free();
  replHandles.set(replId, handle);
  self.postMessage({ type: "result", id, ok: true });
}
self.onmessage = (e) => {
  const {
    type,
    id,
    code,
    extFns,
    value,
    errorMessage,
    excType,
    fnName,
    limits,
    dataBase64,
    scriptName,
    resultsJson,
    errorsJson,
    valueJson,
    source,
    replId
  } = e.data;
  try {
    switch (type) {
      case "run":
        handleRun(id, code, limits, scriptName);
        break;
      case "start":
        handleStart(id, code, extFns, limits, scriptName);
        break;
      case "resume":
        handleResume(id, value);
        break;
      case "resumeWithError":
        handleResumeWithError(id, errorMessage);
        break;
      case "resumeWithException":
        handleResumeWithException(id, excType, errorMessage);
        break;
      case "resumeNotFound":
        handleResumeNotFound(id, fnName);
        break;
      case "resumeAsFuture":
        handleResumeAsFuture(id);
        break;
      case "resolveFutures":
        handleResolveFutures(id, resultsJson, errorsJson);
        break;
      case "snapshot":
        handleSnapshot(id);
        break;
      case "restore":
        handleRestore(id, dataBase64);
        break;
      case "compile":
        handleCompile(id, code, scriptName);
        break;
      case "runPrecompiled":
        handleRunPrecompiled(id, dataBase64, limits, scriptName);
        break;
      case "startPrecompiled":
        handleStartPrecompiled(id, dataBase64, limits, scriptName);
        break;
      case "resumeNameLookupValue":
        handleResumeNameLookupValue(id, valueJson);
        break;
      case "resumeNameLookupUndefined":
        handleResumeNameLookupUndefined(id);
        break;
      case "dispose":
        handleDispose(id);
        break;
      case "replCreate":
        handleReplCreate(id, replId, scriptName);
        break;
      case "replFeedRun":
        handleReplFeedRun(id, replId, code);
        break;
      case "replFeedStart":
        handleReplFeedStart(id, replId, code);
        break;
      case "replSetExtFns":
        handleReplSetExtFns(id, replId, extFns);
        break;
      case "replResume":
        handleReplResume(id, replId, value);
        break;
      case "replResumeWithError":
        handleReplResumeWithError(id, replId, errorMessage);
        break;
      case "replResumeNotFound":
        handleReplResumeNotFound(id, replId, fnName);
        break;
      case "replDetectContinuation":
        handleReplDetectContinuation(id, source);
        break;
      case "replDispose":
        handleReplDispose(id, replId);
        break;
      case "replSnapshot":
        handleReplSnapshot(id, replId);
        break;
      case "replRestore":
        handleReplRestore(id, replId, dataBase64);
        break;
      default:
        self.postMessage({
          type: "result",
          id,
          ok: false,
          error: `Unknown message type: ${type}`,
          errorType: "UnknownType"
        });
    }
  } catch (e2) {
    self.postMessage({
      type: "result",
      id,
      ok: false,
      error: e2.message || String(e2),
      errorType: e2 instanceof WebAssembly.RuntimeError ? "Panic" : "InternalError"
    });
  }
};
initWasm().catch((e) => {
  self.postMessage({
    type: "error",
    message: `WASM init failed: ${e.message}`
  });
});
