/**
 * monty_glue.js — Bridge between @pydantic/monty WASM and Dart JS interop.
 *
 * Exposes window.montyBridge with methods Dart can call via dart:js_interop.
 * This file is bundled by esbuild into monty_bundle.js for browser use.
 */

let MontyModule = null;

/**
 * Initialize the Monty module. Must be called before any other method.
 * Tries to import @pydantic/monty; logs diagnostics on failure.
 *
 * @returns {Promise<boolean>} true if initialized successfully.
 */
async function init() {
  try {
    MontyModule = await import('@pydantic/monty');
    console.log('[monty_glue] @pydantic/monty loaded successfully');
    console.log(
      '[monty_glue] exports:',
      Object.keys(MontyModule).join(', '),
    );
    return true;
  } catch (e) {
    console.error('[monty_glue] Failed to load @pydantic/monty:', e.message);
    console.error('[monty_glue] Stack:', e.stack);
    return false;
  }
}

/**
 * Run Python code to completion and return JSON result.
 *
 * @param {string} code  Python source code.
 * @returns {string} JSON: { "ok": true, "value": ..., "stdout": "..." }
 *                      or { "ok": false, "error": "...", "errorType": "..." }
 */
function run(code) {
  if (!MontyModule) {
    return JSON.stringify({
      ok: false,
      error: 'Monty not initialized. Call init() first.',
      errorType: 'InitError',
    });
  }

  try {
    const { Monty } = MontyModule;
    const m = new Monty(code);
    const result = m.run();
    return JSON.stringify({
      ok: true,
      value: result,
      stdout: '',
    });
  } catch (e) {
    const errorType = e.constructor?.name || 'UnknownError';
    return JSON.stringify({
      ok: false,
      error: e.message || String(e),
      errorType: errorType,
    });
  }
}

/**
 * Start iterative execution (pause at external function calls).
 *
 * @param {string} code           Python source code.
 * @param {string} extFnsJson     JSON array of external function names.
 * @returns {string} JSON result describing MontySnapshot or MontyComplete.
 */
function start(code, extFnsJson) {
  if (!MontyModule) {
    return JSON.stringify({
      ok: false,
      error: 'Monty not initialized.',
      errorType: 'InitError',
    });
  }

  try {
    const { Monty, MontySnapshot, MontyComplete } = MontyModule;
    const extFns = JSON.parse(extFnsJson || '[]');

    const opts = {};
    if (extFns.length > 0) {
      opts.externalFunctions = extFns;
    }

    const m = new Monty(code, opts);
    const progress = m.start();

    if (progress instanceof MontySnapshot) {
      // Store snapshot on window for resume()
      window._montySnapshot = progress;
      return JSON.stringify({
        ok: true,
        state: 'pending',
        functionName: progress.functionName,
        args: progress.args,
      });
    }

    // MontyComplete
    return JSON.stringify({
      ok: true,
      state: 'complete',
      value: progress.output,
    });
  } catch (e) {
    return JSON.stringify({
      ok: false,
      error: e.message || String(e),
      errorType: e.constructor?.name || 'UnknownError',
    });
  }
}

/**
 * Resume a paused execution with a return value.
 *
 * @param {string} valueJson  JSON value to return to Python.
 * @returns {string} JSON result describing next state.
 */
function resume(valueJson) {
  if (!window._montySnapshot) {
    return JSON.stringify({
      ok: false,
      error: 'No active snapshot to resume.',
      errorType: 'StateError',
    });
  }

  try {
    const { MontySnapshot, MontyComplete } = MontyModule;
    const value = JSON.parse(valueJson);
    const progress = window._montySnapshot.resume({ returnValue: value });

    if (progress instanceof MontySnapshot) {
      window._montySnapshot = progress;
      return JSON.stringify({
        ok: true,
        state: 'pending',
        functionName: progress.functionName,
        args: progress.args,
      });
    }

    // MontyComplete
    window._montySnapshot = null;
    return JSON.stringify({
      ok: true,
      state: 'complete',
      value: progress.output,
    });
  } catch (e) {
    window._montySnapshot = null;
    return JSON.stringify({
      ok: false,
      error: e.message || String(e),
      errorType: e.constructor?.name || 'UnknownError',
    });
  }
}

/**
 * Discover and report the available API surface.
 * Useful for diagnostics when the API shape is unknown.
 *
 * @returns {string} JSON describing available exports.
 */
function discover() {
  if (!MontyModule) {
    return JSON.stringify({ loaded: false, exports: [] });
  }

  const exports = {};
  for (const [key, value] of Object.entries(MontyModule)) {
    exports[key] = typeof value;
  }
  return JSON.stringify({ loaded: true, exports });
}

// Expose bridge on window for Dart JS interop
window.montyBridge = {
  init,
  run,
  start,
  resume,
  discover,
};

console.log('[monty_glue] montyBridge registered on window');
