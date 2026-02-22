/**
 * monty_worker_src.js — Runs @pydantic/monty WASM inside a Web Worker.
 *
 * Chrome's 8MB synchronous WASM compile limit does NOT apply in Workers.
 * We directly use the stock NAPI-RS browser loader here.
 *
 * Bundled by esbuild into monty_worker.js for the browser.
 */

// Import the stock browser entry — this does sync WASM compilation
// which is fine inside a Worker (no 8MB limit).
//
// These are the raw NAPI-RS classes (NativeMonty, etc.). Key difference
// from the wrapper.js API: use Monty.create(code, opts) not new Monty().
// Error results are returned as instanceof checks, not thrown.
import {
  Monty,
  MontySnapshot,
  MontyComplete,
  MontyException,
  MontyTypingError,
} from '@pydantic/monty-wasm32-wasi/monty.wasi-browser.js';

let activeSnapshot = null;

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

function handleRun(id, code) {
  try {
    const m = Monty.create(code);
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

function handleStart(id, code, extFns) {
  try {
    const opts = {};
    if (extFns && extFns.length > 0) {
      opts.externalFunctions = extFns;
    }
    const m = Monty.create(code, opts);
    if (m instanceof MontyException || m instanceof MontyTypingError) {
      self.postMessage({ type: 'result', id, ok: false, ...formatError(m) });
      return;
    }
    const progress = m.start();
    if (progress instanceof MontyException) {
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
      self.postMessage({
        type: 'result',
        id,
        ok: true,
        state: 'complete',
        value: progress.output,
      });
    }
  } catch (e) {
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
    self.postMessage({ type: 'result', id, ok: false, ...formatError(e) });
  }
}

self.onmessage = (e) => {
  const { type, id, code, extFns, value, errorMessage } = e.data;
  switch (type) {
    case 'run':
      handleRun(id, code);
      break;
    case 'start':
      handleStart(id, code, extFns);
      break;
    case 'resume':
      handleResume(id, value);
      break;
    case 'resumeWithError':
      handleResumeWithError(id, errorMessage);
      break;
    default:
      self.postMessage({ type: 'error', message: `Unknown message type: ${type}` });
  }
};
