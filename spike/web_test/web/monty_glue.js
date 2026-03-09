/**
 * monty_glue.js — Bridge between @pydantic/monty WASM Worker and Dart JS interop.
 *
 * Monty WASM runs inside a Web Worker (monty_worker.js) to bypass Chrome's
 * 8MB synchronous WASM compile limit. Each DartMontyBridge instance manages
 * its own Worker — instance fields (not static) prevent cross-session
 * promise routing bugs when multiple WASM sessions exist concurrently.
 */

class DartMontyBridge {
  constructor() {
    this._worker = null;
    this._nextId = 1;
    this._pending = new Map(); // id -> { resolve, reject }
  }

  /**
   * Reject all pending promises. Shared by cancel(), dispose(), and onerror.
   * Idempotent — safe to call multiple times.
   *
   * @param {string} reason  Error message forwarded to Dart as the rejection value.
   */
  _rejectPending(reason) {
    const error = new Error(reason);
    for (const [, { reject }] of this._pending) {
      reject(error);
    }
    this._pending.clear();
  }

  /**
   * Initialize the Monty Worker.
   *
   * @returns {Promise<boolean>} true if Worker loaded WASM successfully.
   */
  async init() {
    if (this._worker) return true;
    return new Promise((resolve) => {
      try {
        this._worker = new Worker(
          new URL('./monty_worker.js', window.location.href),
          { type: 'module' },
        );

        this._worker.onmessage = (e) => {
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
          if (msg.id && this._pending.has(msg.id)) {
            const { resolve: res } = this._pending.get(msg.id);
            this._pending.delete(msg.id);
            res(msg);
          }
        };

        this._worker.onerror = (event) => {
          this._rejectPending(`MontyWorkerError: ${event.message}`);
          this._worker = null; // Dead after trap
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
  _callWorker(msg) {
    return new Promise((resolve, reject) => {
      const id = this._nextId++;
      this._pending.set(id, { resolve, reject });
      this._worker.postMessage({ ...msg, id });
    });
  }

  /**
   * Run Python code to completion.
   *
   * @param {string} code  Python source code.
   * @returns {string} JSON result.
   */
  async run(code) {
    if (!this._worker) {
      return JSON.stringify({ ok: false, error: 'Not initialized', errorType: 'InitError' });
    }
    const result = await this._callWorker({ type: 'run', code });
    return JSON.stringify(result);
  }

  /**
   * Start iterative execution.
   *
   * @param {string} code        Python source code.
   * @param {string} extFnsJson  JSON array of external function names.
   * @returns {string} JSON result.
   */
  async start(code, extFnsJson) {
    if (!this._worker) {
      return JSON.stringify({ ok: false, error: 'Not initialized', errorType: 'InitError' });
    }
    const extFns = JSON.parse(extFnsJson || '[]');
    const result = await this._callWorker({ type: 'start', code, extFns });
    return JSON.stringify(result);
  }

  /**
   * Resume a paused execution.
   *
   * @param {string} valueJson  JSON value to return to Python.
   * @returns {string} JSON result.
   */
  async resume(valueJson) {
    if (!this._worker) {
      return JSON.stringify({ ok: false, error: 'Not initialized', errorType: 'InitError' });
    }
    const value = JSON.parse(valueJson);
    const result = await this._callWorker({ type: 'resume', value });
    return JSON.stringify(result);
  }

  /**
   * Resume a paused execution with an error.
   *
   * @param {string} errorJson  JSON error message to propagate to Python.
   * @returns {string} JSON result.
   */
  async resumeWithError(errorJson) {
    if (!this._worker) {
      return JSON.stringify({ ok: false, error: 'Not initialized', errorType: 'InitError' });
    }
    const errorMessage = JSON.parse(errorJson);
    const result = await this._callWorker({ type: 'resumeWithError', errorMessage });
    return JSON.stringify(result);
  }

  /**
   * Discover available API surface.
   *
   * @returns {string} JSON describing state.
   */
  discover() {
    return JSON.stringify({ loaded: this._worker !== null, architecture: 'worker' });
  }

  /**
   * Hard-kill the Worker. Idempotent — safe to call multiple times.
   * Rejects any pending execution promise so Dart's blocked Future completes.
   *
   * @returns {string} JSON { ok: true } — always succeeds (matches native semantics).
   */
  async cancel() {
    this._rejectPending('MontyCancelled: Worker terminated via cancel()');

    if (this._worker) {
      this._worker.terminate();
      this._worker = null;
    }

    return JSON.stringify({ ok: true });
  }

  /**
   * Dispose the worker. Also rejects pending promises so Dart Futures
   * don't hang if dispose() is called before cancel().
   *
   * @returns {string} JSON { ok: true }.
   */
  async dispose() {
    this._rejectPending('MontyDisposed: Worker disposed before completion');

    if (this._worker) {
      this._worker.terminate();
      this._worker = null;
    }

    return JSON.stringify({ ok: true });
  }
}

// Expose the class on window for Dart @JS('DartMontyBridge') interop.
// Dart calls `new DartMontyBridge()` to create per-session instances.
window.DartMontyBridge = DartMontyBridge;

console.log('[monty_glue] DartMontyBridge class registered on window (Worker architecture)');
