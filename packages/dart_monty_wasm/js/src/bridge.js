/**
 * bridge.js — Main-thread bridge between Dart JS interop and Monty WASM Worker.
 *
 * Exposes window.DartMontyBridge with methods Dart calls via dart:js_interop.
 * The Worker (dart_monty_worker.js) hosts the actual Monty WASM runtime.
 */

let worker = null;
let nextId = 1;
const pending = new Map(); // id -> { resolve, reject }

/**
 * Initialize the Monty Worker.
 *
 * @returns {Promise<boolean>} true if Worker loaded WASM successfully.
 */
async function init() {
  if (worker) return true;
  return new Promise((resolve) => {
    try {
      worker = new Worker(
        new URL('./dart_monty_worker.js', window.location.href),
        { type: 'module' },
      );

      worker.onmessage = (e) => {
        const msg = e.data;

        if (msg.type === 'ready') {
          console.log('[DartMontyBridge] Worker ready');
          resolve(true);
          return;
        }

        if (msg.type === 'error' && !msg.id) {
          console.error('[DartMontyBridge] Worker init error:', msg.message);
          resolve(false);
          return;
        }

        // Route responses to pending promises
        if (msg.id && pending.has(msg.id)) {
          const { resolve: res } = pending.get(msg.id);
          pending.delete(msg.id);
          res(msg);
        }
      };

      worker.onerror = (err) => {
        console.error('[DartMontyBridge] Worker error:', err.message || err);
        resolve(false);
      };
    } catch (e) {
      console.error('[DartMontyBridge] Failed to create Worker:', e.message);
      resolve(false);
    }
  });
}

/**
 * Send a message to the Worker and wait for a response.
 */
function callWorker(msg) {
  return new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    worker.postMessage({ ...msg, id });
  });
}

/**
 * Run Python code to completion.
 *
 * @param {string} code       Python source code.
 * @param {string} limitsJson JSON-encoded limits map (optional).
 * @returns {Promise<string>} JSON result.
 */
async function run(code, limitsJson) {
  if (!worker) {
    return JSON.stringify({ ok: false, error: 'Not initialized', errorType: 'InitError' });
  }
  const limits = limitsJson ? JSON.parse(limitsJson) : null;
  const result = await callWorker({ type: 'run', code, limits });
  return JSON.stringify(result);
}

/**
 * Start iterative execution.
 *
 * @param {string} code       Python source code.
 * @param {string} extFnsJson JSON array of external function names (optional).
 * @param {string} limitsJson JSON-encoded limits map (optional).
 * @returns {Promise<string>} JSON result.
 */
async function start(code, extFnsJson, limitsJson) {
  if (!worker) {
    return JSON.stringify({ ok: false, error: 'Not initialized', errorType: 'InitError' });
  }
  const extFns = extFnsJson ? JSON.parse(extFnsJson) : [];
  const limits = limitsJson ? JSON.parse(limitsJson) : null;
  const result = await callWorker({ type: 'start', code, extFns, limits });
  return JSON.stringify(result);
}

/**
 * Resume a paused execution with a return value.
 *
 * @param {string} valueJson JSON-encoded value to return to Python.
 * @returns {Promise<string>} JSON result.
 */
async function resume(valueJson) {
  if (!worker) {
    return JSON.stringify({ ok: false, error: 'Not initialized', errorType: 'InitError' });
  }
  const value = JSON.parse(valueJson);
  const result = await callWorker({ type: 'resume', value });
  return JSON.stringify(result);
}

/**
 * Resume a paused execution with an error.
 *
 * @param {string} errorJson JSON-encoded error message string.
 * @returns {Promise<string>} JSON result.
 */
async function resumeWithError(errorJson) {
  if (!worker) {
    return JSON.stringify({ ok: false, error: 'Not initialized', errorType: 'InitError' });
  }
  const errorMessage = JSON.parse(errorJson);
  const result = await callWorker({ type: 'resumeWithError', errorMessage });
  return JSON.stringify(result);
}

/**
 * Capture the current interpreter state as a snapshot.
 *
 * @returns {Promise<string>} JSON result with base64-encoded data.
 */
async function snapshot() {
  if (!worker) {
    return JSON.stringify({ ok: false, error: 'Not initialized', errorType: 'InitError' });
  }
  const result = await callWorker({ type: 'snapshot' });
  return JSON.stringify(result);
}

/**
 * Restore interpreter state from a base64-encoded snapshot.
 *
 * @param {string} dataBase64 Base64-encoded snapshot data.
 * @returns {Promise<string>} JSON result.
 */
async function restore(dataBase64) {
  if (!worker) {
    return JSON.stringify({ ok: false, error: 'Not initialized', errorType: 'InitError' });
  }
  const result = await callWorker({ type: 'restore', dataBase64 });
  return JSON.stringify(result);
}

/**
 * Discover available API surface.
 *
 * @returns {string} JSON describing bridge state.
 */
function discover() {
  return JSON.stringify({ loaded: worker !== null, architecture: 'worker' });
}

/**
 * Dispose the current Worker session.
 *
 * @returns {Promise<string>} JSON result.
 */
async function dispose() {
  if (!worker) {
    return JSON.stringify({ ok: true });
  }
  const result = await callWorker({ type: 'dispose' });
  return JSON.stringify(result);
}

// Expose bridge on window for Dart JS interop
window.DartMontyBridge = {
  init,
  run,
  start,
  resume,
  resumeWithError,
  snapshot,
  restore,
  discover,
  dispose,
};

console.log('[DartMontyBridge] Registered on window (Worker architecture)');
