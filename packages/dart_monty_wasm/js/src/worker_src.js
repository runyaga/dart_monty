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

// Signal ready
self.postMessage({
  type: 'ready',
  exports: ['Monty', 'MontySnapshot', 'MontyComplete'],
});

function formatError(e) {
  if (e instanceof MontyException) {
    const ex = e.exception || e;
    return {
      error: ex.message || String(e),
      errorType: ex.typeName || 'MontyException',
    };
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

function handleRun(id, code, limits) {
  try {
    const opts = translateLimits(limits);
    const m = Monty.create(code, opts);
    if (m instanceof MontyException || m instanceof MontyTypingError) {
      self.postMessage({ type: 'result', id, ok: false, ...formatError(m) });
      return;
    }
    const result = m.run();
    if (result instanceof MontyException) {
      self.postMessage({ type: 'result', id, ok: false, ...formatError(result) });
      return;
    }
    self.postMessage({ type: 'result', id, ok: true, value: result });
  } catch (e) {
    self.postMessage({ type: 'result', id, ok: false, ...formatError(e) });
  }
}

function handleStart(id, code, extFns, limits) {
  try {
    const opts = translateLimits(limits);
    if (extFns && extFns.length > 0) {
      opts.externalFunctions = extFns;
    }
    const m = Monty.create(code, opts);
    if (m instanceof MontyException || m instanceof MontyTypingError) {
      self.postMessage({ type: 'result', id, ok: false, ...formatError(m) });
      return;
    }
    activeMonty = m;
    const progress = m.start();
    if (progress instanceof MontyException) {
      activeMonty = null;
      self.postMessage({ type: 'result', id, ok: false, ...formatError(progress) });
      return;
    }

    if (progress instanceof MontySnapshot) {
      activeSnapshot = progress;
      self.postMessage({
        type: 'result',
        id,
        ok: true,
        state: 'pending',
        functionName: progress.functionName,
        args: progress.args,
      });
    } else {
      activeSnapshot = null;
      activeMonty = null;
      self.postMessage({
        type: 'result',
        id,
        ok: true,
        state: 'complete',
        value: progress.output,
      });
    }
  } catch (e) {
    activeSnapshot = null;
    activeMonty = null;
    self.postMessage({ type: 'result', id, ok: false, ...formatError(e) });
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
      activeSnapshot = null;
      activeMonty = null;
      self.postMessage({ type: 'result', id, ok: false, ...formatError(progress) });
      return;
    }

    if (progress instanceof MontySnapshot) {
      activeSnapshot = progress;
      self.postMessage({
        type: 'result',
        id,
        ok: true,
        state: 'pending',
        functionName: progress.functionName,
        args: progress.args,
      });
    } else {
      activeSnapshot = null;
      activeMonty = null;
      self.postMessage({
        type: 'result',
        id,
        ok: true,
        state: 'complete',
        value: progress.output,
      });
    }
  } catch (e) {
    activeSnapshot = null;
    activeMonty = null;
    self.postMessage({ type: 'result', id, ok: false, ...formatError(e) });
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
      activeSnapshot = null;
      activeMonty = null;
      self.postMessage({ type: 'result', id, ok: false, ...formatError(progress) });
      return;
    }

    if (progress instanceof MontySnapshot) {
      activeSnapshot = progress;
      self.postMessage({
        type: 'result',
        id,
        ok: true,
        state: 'pending',
        functionName: progress.functionName,
        args: progress.args,
      });
    } else {
      activeSnapshot = null;
      activeMonty = null;
      self.postMessage({
        type: 'result',
        id,
        ok: true,
        state: 'complete',
        value: progress.output,
      });
    }
  } catch (e) {
    activeSnapshot = null;
    activeMonty = null;
    self.postMessage({ type: 'result', id, ok: false, ...formatError(e) });
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
    self.postMessage({ type: 'result', id, ok: false, ...formatError(e) });
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
      self.postMessage({ type: 'result', id, ok: false, ...formatError(snapshot) });
      return;
    }
    activeSnapshot = snapshot;
    self.postMessage({ type: 'result', id, ok: true });
  } catch (e) {
    self.postMessage({ type: 'result', id, ok: false, ...formatError(e) });
  }
}

function handleDispose(id) {
  activeSnapshot = null;
  activeMonty = null;
  self.postMessage({ type: 'result', id, ok: true });
}

self.onmessage = (e) => {
  const { type, id, code, extFns, value, errorMessage, limits, dataBase64 } = e.data;
  switch (type) {
    case 'run':
      handleRun(id, code, limits);
      break;
    case 'start':
      handleStart(id, code, extFns, limits);
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
