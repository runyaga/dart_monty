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
  MontyFutureSnapshot,
} from '@pydantic/monty-wasm32-wasi/monty.wasi-browser.js';

let activeProgress = null; // MontySnapshot | MontyFutureSnapshot | null

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

    postProgress(id, progress);
  } catch (e) {
    self.postMessage({ type: 'result', id, ok: false, ...formatError(e) });
  }
}

function postProgress(id, progress) {
  if (progress instanceof MontySnapshot) {
    if (progress.callId === undefined) {
      throw new Error('WASM version mismatch: callId missing on MontySnapshot');
    }
    activeProgress = progress;
    self.postMessage({
      type: 'result',
      id,
      ok: true,
      state: 'pending',
      functionName: progress.functionName,
      args: progress.args,
      kwargs: progress.kwargs,
      callId: progress.callId,
    });
  } else if (progress instanceof MontyFutureSnapshot) {
    activeProgress = progress;
    self.postMessage({
      type: 'result',
      id,
      ok: true,
      state: 'resolve_futures',
      pendingCallIds: Array.from(progress.pendingCallIds),
    });
  } else {
    // MontyComplete
    activeProgress = null;
    self.postMessage({
      type: 'result',
      id,
      ok: true,
      state: 'complete',
      value: progress.output,
    });
  }
}

function postError(id, error) {
  activeProgress = null;
  self.postMessage({ type: 'result', id, ok: false, ...formatError(error) });
}

function handleResume(id, value) {
  if (!(activeProgress instanceof MontySnapshot)) {
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
    const progress = activeProgress.resume({ returnValue: value });
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
  if (!(activeProgress instanceof MontySnapshot)) {
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
    const progress = activeProgress.resume({
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

function handleResumeAsFuture(id) {
  if (!(activeProgress instanceof MontySnapshot)) {
    self.postMessage({
      type: 'result',
      id,
      ok: false,
      error: 'No active snapshot to resume as future.',
      errorType: 'StateError',
    });
    return;
  }
  try {
    const progress = activeProgress.resumeAsFuture();
    if (progress instanceof MontyException) {
      postError(id, progress);
      return;
    }
    postProgress(id, progress);
  } catch (e) {
    postError(id, e);
  }
}

function handleResolveFutures(id, items) {
  if (!(activeProgress instanceof MontyFutureSnapshot)) {
    self.postMessage({
      type: 'result',
      id,
      ok: false,
      error: 'No active future snapshot to resolve.',
      errorType: 'StateError',
    });
    return;
  }
  try {
    const progress = activeProgress.resume(items);
    if (progress instanceof MontyException) {
      postError(id, progress);
      return;
    }
    postProgress(id, progress);
  } catch (e) {
    postError(id, e);
  }
}

self.onmessage = (e) => {
  const { type, id, code, extFns, value, errorMessage, items } = e.data;
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
    case 'resumeAsFuture':
      handleResumeAsFuture(id);
      break;
    case 'resolveFutures':
      handleResolveFutures(id, items);
      break;
    default:
      self.postMessage({ type: 'error', message: `Unknown message type: ${type}` });
  }
};
