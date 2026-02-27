/**
 * worker_src.js — Runs @pydantic/monty WASM inside a Web Worker.
 *
 * Chrome's 8MB synchronous WASM compile limit does NOT apply in Workers.
 * We directly use the stock NAPI-RS browser loader here.
 *
 * Bundled by esbuild into dart_monty_worker.js for the browser.
 */

import {
  Monty,
  MontySnapshot,
  MontyComplete,
  MontyException,
  MontyTypingError,
} from '@pydantic/monty-wasm32-wasi/monty.wasi-browser.js';

let activeSnapshot = null;
let activeMonty = null;
let callIdCounter = 0;

// Signal ready
self.postMessage({
  type: 'ready',
  exports: ['Monty', 'MontySnapshot', 'MontyComplete'],
});

/**
 * Convert a JS Frame object to the snake_case JSON that Dart expects.
 */
function frameToJson(f) {
  const obj = {
    filename: f.filename,
    start_line: f.line,
    start_column: f.column,
    end_line: f.endLine,
    end_column: f.endColumn,
  };
  if (f.functionName != null) obj.frame_name = f.functionName;
  if (f.sourceLine != null) obj.preview_line = f.sourceLine;
  return obj;
}

function formatError(e) {
  if (e instanceof MontyException) {
    const ex = e.exception || e;
    const result = {
      error: ex.message || String(e),
      errorType: ex.typeName || 'MontyException',
      excType: ex.typeName || null,
    };
    try {
      const frames = e.traceback();
      if (frames && frames.length > 0) {
        result.traceback = frames.map(frameToJson);
      }
    } catch (_) {
      // traceback() may fail for some error types
    }
    return result;
  }
  if (e instanceof MontyTypingError) {
    return { error: e.message || String(e), errorType: 'MontyTypingError' };
  }
  return {
    error: e.message || String(e),
    errorType: e.constructor?.name || 'UnknownError',
  };
}

/**
 * Translate Dart-side limits to Monty NAPI-RS options.
 *
 * Dart sends: { memory_bytes, timeout_ms, stack_depth }
 * Monty expects: { maxMemory, maxDurationSecs, maxRecursionDepth }
 */
function translateLimits(limits) {
  if (!limits) return {};
  const opts = {};
  if (limits.memory_bytes != null) {
    opts.maxMemory = limits.memory_bytes;
  }
  if (limits.timeout_ms != null) {
    opts.maxDurationSecs = limits.timeout_ms / 1000;
  }
  if (limits.stack_depth != null) {
    opts.maxRecursionDepth = limits.stack_depth;
  }
  return opts;
}

/**
 * Recursively convert JS Map objects to plain objects so that
 * JSON.stringify() can serialize them.  Monty's WASM runtime may
 * represent Python dicts as JS Maps which JSON.stringify ignores.
 */
function toSerializable(val) {
  if (val instanceof Map) {
    const obj = {};
    for (const [k, v] of val) {
      obj[String(k)] = toSerializable(v);
    }
    return obj;
  }
  if (Array.isArray(val)) {
    return val.map(toSerializable);
  }
  if (val !== null && typeof val === 'object' && !(val instanceof Date)) {
    const obj = {};
    for (const k of Object.keys(val)) {
      obj[k] = toSerializable(val[k]);
    }
    return obj;
  }
  return val;
}

/**
 * Post a progress result (pending or complete) back to the main thread.
 * Handles MontySnapshot (pending) vs MontyComplete dispatch.
 */
function postProgress(id, progress) {
  if (progress instanceof MontySnapshot) {
    callIdCounter++;
    activeSnapshot = progress;
    self.postMessage({
      type: 'result',
      id,
      ok: true,
      state: 'pending',
      functionName: progress.functionName,
      args: toSerializable(progress.args),
      kwargs: toSerializable(progress.kwargs),
      callId: callIdCounter,
    });
  } else {
    activeSnapshot = null;
    activeMonty = null;
    self.postMessage({
      type: 'result',
      id,
      ok: true,
      state: 'complete',
      value: toSerializable(progress.output),
    });
  }
}

/**
 * Post an error result, clearing active state.
 */
function postError(id, error) {
  activeSnapshot = null;
  activeMonty = null;
  self.postMessage({ type: 'result', id, ok: false, ...formatError(error) });
}

function handleRun(id, code, limits, scriptName) {
  try {
    const opts = translateLimits(limits);
    if (scriptName) opts.scriptName = scriptName;
    const m = Monty.create(code, opts);
    if (m instanceof MontyException || m instanceof MontyTypingError) {
      postError(id, m);
      return;
    }
    const result = m.run();
    if (result instanceof MontyException) {
      postError(id, result);
      return;
    }
    self.postMessage({ type: 'result', id, ok: true, value: toSerializable(result) });
  } catch (e) {
    postError(id, e);
  }
}

function handleStart(id, code, extFns, limits, scriptName) {
  try {
    callIdCounter = 0;
    const opts = translateLimits(limits);
    if (scriptName) opts.scriptName = scriptName;
    if (extFns && extFns.length > 0) {
      opts.externalFunctions = extFns;
    }
    const m = Monty.create(code, opts);
    if (m instanceof MontyException || m instanceof MontyTypingError) {
      postError(id, m);
      return;
    }
    activeMonty = m;
    const progress = m.start();
    if (progress instanceof MontyException) {
      postError(id, progress);
      return;
    }
    postProgress(id, progress);
  } catch (e) {
    postError(id, e);
  }
}

function handleResume(id, value) {
  if (!activeSnapshot) {
    self.postMessage({
      type: 'result',
      id,
      ok: false,
      error: 'No active snapshot to resume.',
      errorType: 'StateError',
    });
    return;
  }
  try {
    const progress = activeSnapshot.resume({ returnValue: value });
    if (progress instanceof MontyException) {
      postError(id, progress);
      return;
    }
    postProgress(id, progress);
  } catch (e) {
    postError(id, e);
  }
}

function handleResumeWithError(id, errorMessage) {
  if (!activeSnapshot) {
    self.postMessage({
      type: 'result',
      id,
      ok: false,
      error: 'No active snapshot to resume.',
      errorType: 'StateError',
    });
    return;
  }
  try {
    const progress = activeSnapshot.resume({
      exception: { type: 'Exception', message: errorMessage },
    });
    if (progress instanceof MontyException) {
      postError(id, progress);
      return;
    }
    postProgress(id, progress);
  } catch (e) {
    postError(id, e);
  }
}

function handleSnapshot(id) {
  if (!activeSnapshot) {
    self.postMessage({
      type: 'result',
      id,
      ok: false,
      error: 'No active snapshot to dump.',
      errorType: 'StateError',
    });
    return;
  }
  try {
    const bytes = activeSnapshot.dump();
    // Convert Uint8Array to base64
    let binary = '';
    for (let i = 0; i < bytes.length; i++) {
      binary += String.fromCharCode(bytes[i]);
    }
    const data = btoa(binary);
    self.postMessage({ type: 'result', id, ok: true, data });
  } catch (e) {
    postError(id, e);
  }
}

function handleRestore(id, dataBase64) {
  try {
    // Decode base64 to Uint8Array
    const binary = atob(dataBase64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    const snapshot = MontySnapshot.load(bytes);
    if (snapshot instanceof MontyException) {
      postError(id, snapshot);
      return;
    }
    activeSnapshot = snapshot;
    self.postMessage({ type: 'result', id, ok: true });
  } catch (e) {
    postError(id, e);
  }
}

function handleDispose(id) {
  activeSnapshot = null;
  activeMonty = null;
  self.postMessage({ type: 'result', id, ok: true });
}

self.onmessage = (e) => {
  const { type, id, code, extFns, value, errorMessage, limits, dataBase64, scriptName } = e.data;
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
        type: 'error',
        id,
        ok: false,
        error: `Unknown message type: ${type}`,
        errorType: 'UnknownType',
      });
  }
};
