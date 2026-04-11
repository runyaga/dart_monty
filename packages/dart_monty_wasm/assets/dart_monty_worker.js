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
var RESULT_OK = 0;

// src/worker_src.js
var wasm2 = null;
async function initWasm() {
  const wasmUrl = new URL("./dart_monty_native.wasm", import.meta.url);
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
function readProgress(id, handle, tag, errMsg) {
  switch (tag) {
    case PROGRESS_COMPLETE: {
      const isErr = wasm2.monty_complete_is_error(handle);
      const ptr = wasm2.monty_complete_result_json(handle);
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
      const fnName = readAndFreeCString(wasm2.monty_pending_fn_name(handle));
      const argsJson = readAndFreeCString(wasm2.monty_pending_fn_args_json(handle));
      const kwargsJson = readAndFreeCString(wasm2.monty_pending_fn_kwargs_json(handle));
      const callId = wasm2.monty_pending_call_id(handle);
      const methodCall = wasm2.monty_pending_method_call(handle);
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
    case PROGRESS_OS_CALL: {
      const fnName = readAndFreeCString(wasm2.monty_os_call_fn_name(handle));
      const argsJson = readAndFreeCString(wasm2.monty_os_call_args_json(handle));
      const kwargsJson = readAndFreeCString(wasm2.monty_os_call_kwargs_json(handle));
      const callId = wasm2.monty_os_call_id(handle);
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
    case PROGRESS_RESOLVE_FUTURES: {
      const idsPtr = wasm2.monty_pending_future_call_ids(handle);
      const idsJson = readAndFreeCString(idsPtr);
      return {
        type: "result",
        id,
        ok: true,
        state: "resolve_futures",
        pendingCallIds: idsJson ? JSON.parse(idsJson) : []
      };
    }
    case PROGRESS_ERROR:
      return {
        type: "result",
        id,
        ok: false,
        error: errMsg || "Unknown error",
        errorType: "MontyException"
      };
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
      errorType: "CompileError"
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
      errorType: "CompileError"
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
    msg = readProgress(id, handle, tag, errMsg);
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
    msg = readProgress(id, activeHandle, tag, errMsg);
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
    msg = readProgress(id, activeHandle, tag, errMsg);
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
    msg = readProgress(id, activeHandle, tag, errMsg);
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
    msg = readProgress(id, activeHandle, tag, errMsg);
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
function handleDispose(id) {
  if (activeHandle) {
    wasm2.monty_free(activeHandle);
    activeHandle = null;
  }
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
    limits,
    dataBase64,
    scriptName,
    resultsJson,
    errorsJson
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
      case "dispose":
        handleDispose(id);
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
