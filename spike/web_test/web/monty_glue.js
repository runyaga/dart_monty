/**
 * monty_glue.js — Bridge between @pydantic/monty WASM Worker and Dart JS interop.
 *
 * Monty WASM runs inside a Web Worker (monty_worker.js) to bypass Chrome's
 * 8MB synchronous WASM compile limit. This glue exposes window.montyBridge
 * with methods Dart can call via dart:js_interop.
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
        new URL('./monty_worker.js', window.location.href),
        { type: 'module' },
      );

      worker.onmessage = (e) => {
        const msg = e.data;

        if (msg.type === 'ready') {
          console.log('[monty_glue] Worker ready, exports:', msg.exports.join(', '));
          resolve(true);
          return;
        }

        if (msg.type === 'error' && !msg.id) {
          console.error('[monty_glue] Worker init error:', msg.message);
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
        console.error('[monty_glue] Worker error:', err.message || err);
        resolve(false);
      };
    } catch (e) {
      console.error('[monty_glue] Failed to create Worker:', e.message);
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
 * @param {string} code  Python source code.
 * @returns {string} JSON result.
 */
async function run(code) {
  if (!worker) {
    return JSON.stringify({ ok: false, error: 'Not initialized', errorType: 'InitError' });
  }
  const result = await callWorker({ type: 'run', code });
  return JSON.stringify(result);
}

/**
 * Start iterative execution.
 *
 * @param {string} code        Python source code.
 * @param {string} extFnsJson  JSON array of external function names.
 * @returns {string} JSON result.
 */
async function start(code, extFnsJson) {
  if (!worker) {
    return JSON.stringify({ ok: false, error: 'Not initialized', errorType: 'InitError' });
  }
  const extFns = JSON.parse(extFnsJson || '[]');
  const result = await callWorker({ type: 'start', code, extFns });
  return JSON.stringify(result);
}

/**
 * Resume a paused execution.
 *
 * @param {string} valueJson  JSON value to return to Python.
 * @returns {string} JSON result.
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
 * Discover available API surface.
 *
 * @returns {string} JSON describing state.
 */
function discover() {
  return JSON.stringify({ loaded: worker !== null, architecture: 'worker' });
}

// Expose bridge on window for Dart JS interop
window.montyBridge = {
  init,
  run,
  start,
  resume,
  discover,
};

console.log('[monty_glue] montyBridge registered on window (Worker architecture)');
