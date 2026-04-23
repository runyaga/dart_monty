/**
 * bridge.js — Main-thread bridge between Dart JS interop and Monty WASM Workers.
 *
 * Exposes window.DartMontyBridge with methods Dart calls via dart:js_interop.
 * Each session gets its own Worker hosting a Monty WASM runtime.
 *
 * Architecture: Multi-session Worker pool (Phase 2a).
 * Backward-compatible: init/run/start/resume/etc. without sessionId use
 * a default session, so existing Dart code works without changes.
 */

let nextSessionId = 1;
const sessions = new Map(); // sessionId -> { worker, nextMsgId, pending, timeoutMs }
let defaultSessionId = null;

// ---------------------------------------------------------------------------
// Worker URL — resolved once relative to the bridge script location.
// Falls back to window.location.href if document.currentScript is unavailable
// (e.g. when loaded dynamically).
// ---------------------------------------------------------------------------

const _bridgeBase =
  (typeof document !== 'undefined' && document.currentScript)
    ? new URL('.', document.currentScript.src).href
    : window.location.href;

// ---------------------------------------------------------------------------
// Session lifecycle
// ---------------------------------------------------------------------------

/**
 * Create a new session with its own Worker.
 *
 * @returns {Promise<number>} sessionId.
 */
function createSession() {
  return new Promise((resolve, reject) => {
    const sessionId = nextSessionId++;
    try {
      // Blob URL trampoline: allows Worker creation when bridge.js is
      // served from a different origin (e.g. CDN). Direct cross-origin
      // Worker URLs throw SecurityError; a same-origin Blob proxy avoids it.
      const workerUrl = new URL('./dart_monty_core_worker.js', _bridgeBase).href;
      const blob = new Blob(
        [`import "${workerUrl}";`],
        { type: 'application/javascript' },
      );
      const blobUrl = URL.createObjectURL(blob);
      const worker = new Worker(blobUrl, { type: 'module' });

      worker.onerror = (event) => {
        const session = sessions.get(sessionId);
        if (session) {
          // Worker crashed — reject all pending promises
          for (const req of session.pending.values()) {
            if (req.timer) clearTimeout(req.timer);
            req.reject(new Error(`Panic: Worker crashed: ${event.message || event}`));
          }
          session.pending.clear();
          sessions.delete(sessionId);
          if (defaultSessionId === sessionId) defaultSessionId = null;
        }
        // If we haven't resolved yet (during init), reject the create
        reject(new Error(`Worker failed to start: ${event.message || event}`));
      };

      worker.onmessage = (e) => {
        const msg = e.data;

        if (msg.type === 'ready') {
          URL.revokeObjectURL(blobUrl);
          sessions.set(sessionId, {
            worker,
            nextMsgId: 1,
            pending: new Map(),
            timeoutMs: null,
          });
          console.log(`[DartMontyBridge] Session ${sessionId} ready`);
          resolve(sessionId);
          return;
        }

        if (msg.type === 'error' && !msg.id) {
          console.error(`[DartMontyBridge] Session ${sessionId} init error:`, msg.message);
          reject(new Error(msg.message || 'Worker init failed'));
          return;
        }

        // Route responses to pending promises
        const session = sessions.get(sessionId);
        if (!session) return;
        if (msg.id && session.pending.has(msg.id)) {
          const req = session.pending.get(msg.id);
          if (req.timer) clearTimeout(req.timer);
          session.pending.delete(msg.id);
          req.resolve(msg);
        }
      };
    } catch (e) {
      reject(new Error(`Failed to create Worker: ${e.message}`));
    }
  });
}

/**
 * Dispose a session — clear timers, reject pending, terminate Worker.
 *
 * @param {number} sessionId
 */
function disposeSession(sessionId) {
  const session = sessions.get(sessionId);
  if (!session) return;
  for (const req of session.pending.values()) {
    if (req.timer) clearTimeout(req.timer);
    req.reject(new Error('MontyDisposed: Session disposed'));
  }
  session.pending.clear();
  session.worker.terminate();
  sessions.delete(sessionId);
  if (defaultSessionId === sessionId) defaultSessionId = null;
}

// ---------------------------------------------------------------------------
// Worker communication
// ---------------------------------------------------------------------------

/**
 * Send a message to a session's Worker and wait for a response.
 *
 * @param {number} sessionId
 * @param {Object} msg
 * @param {number|null} timeoutMs — hard timeout (null = no timeout).
 * @returns {Promise<Object>}
 */
function callWorker(sessionId, msg, timeoutMs) {
  return new Promise((resolve, reject) => {
    const session = sessions.get(sessionId);
    if (!session) {
      reject(new Error(`Session ${sessionId} not found`));
      return;
    }
    const msgId = session.nextMsgId++;

    let timer = null;
    if (timeoutMs != null && timeoutMs > 0) {
      timer = setTimeout(() => {
        // Timeout — reject ALL pending promises for this session
        for (const req of session.pending.values()) {
          if (req.timer) clearTimeout(req.timer);
          req.reject(new Error('MontyWorkerError: Execution timed out'));
        }
        session.pending.clear();
        session.worker.terminate();
        sessions.delete(sessionId);
        if (defaultSessionId === sessionId) defaultSessionId = null;
      }, timeoutMs);
    }

    session.pending.set(msgId, { resolve, reject, timer });
    session.worker.postMessage({ ...msg, id: msgId });
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Get the session, returning an error JSON string if not found.
 */
function getSessionOrError(sessionId) {
  if (sessionId != null && sessions.has(sessionId)) {
    return sessions.get(sessionId);
  }
  return null;
}

function notInitializedError() {
  return JSON.stringify({ ok: false, error: 'Not initialized', errorType: 'InitError' });
}

/**
 * Resolve the effective session ID — use explicit or default.
 */
function resolveSessionId(sessionId) {
  if (sessionId != null) return sessionId;
  return defaultSessionId;
}

/**
 * Compute a hard timeout from limitsJson.
 * Returns null if no timeout specified.
 */
function parseHardTimeout(limitsJson) {
  if (!limitsJson) return null;
  const limits = typeof limitsJson === 'string' ? JSON.parse(limitsJson) : limitsJson;
  if (limits.timeout_ms != null) {
    // Hard backstop = soft timeout + 1 second buffer
    return limits.timeout_ms + 1000;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Public API — backward-compatible (sessionId is optional)
// ---------------------------------------------------------------------------

/**
 * Initialize the bridge.
 *
 * For backward compatibility, creates a default session if none exists.
 *
 * @returns {Promise<boolean>} true if Worker loaded WASM successfully.
 */
async function init() {
  if (defaultSessionId != null && sessions.has(defaultSessionId)) return true;
  try {
    defaultSessionId = await createSession();
    return true;
  } catch (e) {
    console.error('[DartMontyBridge] Init failed:', e.message);
    return false;
  }
}

/**
 * Run Python code to completion.
 *
 * @param {string} code       Python source code.
 * @param {string} limitsJson JSON-encoded limits map (optional).
 * @param {string} scriptName Script name for tracebacks (optional).
 * @returns {Promise<string>} JSON result.
 */
async function run(code, limitsJson, scriptName) {
  const sid = resolveSessionId(null);
  if (sid == null || !sessions.has(sid)) return notInitializedError();

  const session = sessions.get(sid);
  const hardTimeout = parseHardTimeout(limitsJson);
  if (hardTimeout != null) session.timeoutMs = hardTimeout;

  const limits = limitsJson ? JSON.parse(limitsJson) : null;
  const msg = { type: 'run', code, limits };
  if (scriptName) msg.scriptName = scriptName;
  const result = await callWorker(sid, msg, session.timeoutMs);
  return JSON.stringify(result);
}

/**
 * Start iterative execution.
 *
 * @param {string} code       Python source code.
 * @param {string} extFnsJson JSON array of external function names (optional).
 * @param {string} limitsJson JSON-encoded limits map (optional).
 * @param {string} scriptName Script name for tracebacks (optional).
 * @returns {Promise<string>} JSON result.
 */
async function start(code, extFnsJson, limitsJson, scriptName) {
  const sid = resolveSessionId(null);
  if (sid == null || !sessions.has(sid)) return notInitializedError();

  const session = sessions.get(sid);
  const hardTimeout = parseHardTimeout(limitsJson);
  if (hardTimeout != null) session.timeoutMs = hardTimeout;

  const extFns = extFnsJson ? JSON.parse(extFnsJson) : [];
  const limits = limitsJson ? JSON.parse(limitsJson) : null;
  const msg = { type: 'start', code, extFns, limits };
  if (scriptName) msg.scriptName = scriptName;
  const result = await callWorker(sid, msg, session.timeoutMs);
  return JSON.stringify(result);
}

/**
 * Resume a paused execution with a return value.
 *
 * @param {string} valueJson JSON-encoded value to return to Python.
 * @returns {Promise<string>} JSON result.
 */
async function resume(valueJson) {
  const sid = resolveSessionId(null);
  if (sid == null || !sessions.has(sid)) return notInitializedError();

  const session = sessions.get(sid);
  const value = JSON.parse(valueJson);
  const result = await callWorker(sid, { type: 'resume', value }, session.timeoutMs);
  return JSON.stringify(result);
}

/**
 * Resume a paused execution with an error.
 *
 * @param {string} errorJson JSON-encoded error message string.
 * @returns {Promise<string>} JSON result.
 */
async function resumeWithError(errorJson) {
  const sid = resolveSessionId(null);
  if (sid == null || !sessions.has(sid)) return notInitializedError();

  const session = sessions.get(sid);
  const errorMessage = JSON.parse(errorJson);
  const result = await callWorker(sid, { type: 'resumeWithError', errorMessage }, session.timeoutMs);
  return JSON.stringify(result);
}

/**
 * Resume a paused execution with a typed Python exception.
 *
 * @param {string} excTypeJson JSON-encoded exception class name (e.g. "FileNotFoundError").
 * @param {string} errorJson   JSON-encoded error message string.
 * @returns {Promise<string>} JSON result.
 */
async function resumeWithException(excTypeJson, errorJson) {
  const sid = resolveSessionId(null);
  if (sid == null || !sessions.has(sid)) return notInitializedError();

  const session = sessions.get(sid);
  const excType = JSON.parse(excTypeJson);
  const errorMessage = JSON.parse(errorJson);
  const result = await callWorker(
    sid,
    { type: 'resumeWithException', excType, errorMessage },
    session.timeoutMs,
  );
  return JSON.stringify(result);
}

/**
 * Resume a paused OS call by signalling "function not found" — raises
 * Python `NameError: name '<fnName>' is not defined`.
 *
 * @param {string} fnNameJson JSON-encoded function name.
 * @returns {Promise<string>} JSON result.
 */
async function resumeNotFound(fnNameJson) {
  const sid = resolveSessionId(null);
  if (sid == null || !sessions.has(sid)) return notInitializedError();

  const session = sessions.get(sid);
  const fnName = JSON.parse(fnNameJson);
  const result = await callWorker(
    sid,
    { type: 'resumeNotFound', fnName },
    session.timeoutMs,
  );
  return JSON.stringify(result);
}

/**
 * Resume by creating a future for the pending external function call.
 *
 * @returns {Promise<string>} JSON result with state: pending, resolve_futures, or complete.
 */
async function resumeAsFuture() {
  const sid = resolveSessionId(null);
  if (sid == null || !sessions.has(sid)) return notInitializedError();

  const session = sessions.get(sid);
  const result = await callWorker(sid, { type: 'resumeAsFuture' }, session.timeoutMs);
  return JSON.stringify(result);
}

/**
 * Resolve pending futures with results and errors.
 *
 * @param {string} resultsJson JSON object {"callId": value, ...}.
 * @param {string} errorsJson  JSON object {"callId": "errorMsg", ...}.
 * @returns {Promise<string>} JSON result.
 */
async function resolveFutures(resultsJson, errorsJson) {
  const sid = resolveSessionId(null);
  if (sid == null || !sessions.has(sid)) return notInitializedError();

  const session = sessions.get(sid);
  const result = await callWorker(
    sid, { type: 'resolveFutures', resultsJson, errorsJson }, session.timeoutMs,
  );
  return JSON.stringify(result);
}

/**
 * Capture the current interpreter state as a snapshot.
 *
 * @returns {Promise<string>} JSON result with base64-encoded data.
 */
async function snapshot() {
  const sid = resolveSessionId(null);
  if (sid == null || !sessions.has(sid)) {
    // Return a raw JS object (not JSON string) — Dart casts to _SnapshotResult.
    return { ok: false, error: 'Not initialized' };
  }

  const session = sessions.get(sid);
  const result = await callWorker(sid, { type: 'snapshot' }, session.timeoutMs);
  // Return raw JS object — snapshotBuffer is an ArrayBuffer, not JSON-safe.
  return result;
}

/**
 * Restore interpreter state from a base64-encoded snapshot.
 *
 * @param {string} dataBase64 Base64-encoded snapshot data.
 * @returns {Promise<string>} JSON result.
 */
async function restore(dataBase64) {
  const sid = resolveSessionId(null);
  if (sid == null || !sessions.has(sid)) return notInitializedError();

  const session = sessions.get(sid);
  const result = await callWorker(sid, { type: 'restore', dataBase64 }, session.timeoutMs);
  return JSON.stringify(result);
}

/**
 * Compile Python code and return the bytecode as a snapshot buffer.
 *
 * Creates a temporary handle, snapshots compiled bytecode, and frees
 * the handle. Returns a raw JS object (ArrayBuffer is not JSON-safe).
 *
 * @param {string} code       Python source code.
 * @param {string} scriptName Script name for tracebacks (optional).
 * @returns {Promise<Object>} Raw JS object with snapshotBuffer ArrayBuffer.
 */
async function compile(code, scriptName) {
  const sid = resolveSessionId(null);
  if (sid == null || !sessions.has(sid)) {
    return { ok: false, error: 'Not initialized' };
  }

  const session = sessions.get(sid);
  const msg = { type: 'compile', code };
  if (scriptName) msg.scriptName = scriptName;
  const result = await callWorker(sid, msg, session.timeoutMs);
  // Return raw JS object — snapshotBuffer is an ArrayBuffer, not JSON-safe.
  return result;
}

/**
 * Run precompiled bytecode to completion.
 *
 * @param {string} dataBase64 Base64-encoded compiled snapshot bytes.
 * @param {string} limitsJson JSON-encoded limits map (optional).
 * @param {string} scriptName Script name for tracebacks (optional).
 * @returns {Promise<string>} JSON result.
 */
async function runPrecompiled(dataBase64, limitsJson, scriptName) {
  const sid = resolveSessionId(null);
  if (sid == null || !sessions.has(sid)) return notInitializedError();

  const session = sessions.get(sid);
  const hardTimeout = parseHardTimeout(limitsJson);
  if (hardTimeout != null) session.timeoutMs = hardTimeout;

  const limits = limitsJson ? JSON.parse(limitsJson) : null;
  const msg = { type: 'runPrecompiled', dataBase64, limits };
  if (scriptName) msg.scriptName = scriptName;
  const result = await callWorker(sid, msg, session.timeoutMs);
  return JSON.stringify(result);
}

/**
 * Start iterative execution from precompiled bytecode.
 *
 * @param {string} dataBase64 Base64-encoded compiled snapshot bytes.
 * @param {string} limitsJson JSON-encoded limits map (optional).
 * @param {string} scriptName Script name for tracebacks (optional).
 * @returns {Promise<string>} JSON result.
 */
async function startPrecompiled(dataBase64, limitsJson, scriptName) {
  const sid = resolveSessionId(null);
  if (sid == null || !sessions.has(sid)) return notInitializedError();

  const session = sessions.get(sid);
  const hardTimeout = parseHardTimeout(limitsJson);
  if (hardTimeout != null) session.timeoutMs = hardTimeout;

  const limits = limitsJson ? JSON.parse(limitsJson) : null;
  const msg = { type: 'startPrecompiled', dataBase64, limits };
  if (scriptName) msg.scriptName = scriptName;
  const result = await callWorker(sid, msg, session.timeoutMs);
  return JSON.stringify(result);
}

/**
 * Resume a name lookup by providing a value for the looked-up name.
 *
 * @param {string} valueJson JSON-encoded value.
 * @returns {Promise<string>} JSON result.
 */
async function resumeNameLookupValue(valueJson) {
  const sid = resolveSessionId(null);
  if (sid == null || !sessions.has(sid)) return notInitializedError();

  const session = sessions.get(sid);
  const result = await callWorker(
    sid, { type: 'resumeNameLookupValue', valueJson }, session.timeoutMs,
  );
  return JSON.stringify(result);
}

/**
 * Resume a name lookup indicating the name is undefined (raises NameError).
 *
 * @returns {Promise<string>} JSON result.
 */
async function resumeNameLookupUndefined() {
  const sid = resolveSessionId(null);
  if (sid == null || !sessions.has(sid)) return notInitializedError();

  const session = sessions.get(sid);
  const result = await callWorker(
    sid, { type: 'resumeNameLookupUndefined' }, session.timeoutMs,
  );
  return JSON.stringify(result);
}

/**
 * Discover available API surface.
 *
 * @returns {string} JSON describing bridge state.
 */
function discover() {
  return JSON.stringify({
    loaded: sessions.size > 0,
    sessionCount: sessions.size,
    architecture: 'worker-pool',
  });
}

/**
 * Cancel the current execution by terminating the Worker.
 *
 * Terminates the Worker immediately (preemptive kill), rejects all
 * pending promises with 'MontyCancelled:' prefix so Dart maps them
 * to [MontyCancelledError], and removes the session.
 *
 * Idempotent — safe to call if no session exists.
 *
 * @returns {Promise<string>} JSON result.
 */
async function cancel() {
  const sid = resolveSessionId(null);
  if (sid == null || !sessions.has(sid)) {
    return JSON.stringify({ ok: true });
  }
  const session = sessions.get(sid);
  // Reject all pending promises with cancel prefix
  for (const req of session.pending.values()) {
    if (req.timer) clearTimeout(req.timer);
    req.reject(new Error('MontyCancelled: execution cancelled'));
  }
  session.pending.clear();
  session.worker.terminate();
  sessions.delete(sid);
  if (defaultSessionId === sid) defaultSessionId = null;
  return JSON.stringify({ ok: true });
}

/**
 * Dispose the default Worker session.
 *
 * @returns {Promise<string>} JSON result.
 */
async function dispose() {
  const sid = resolveSessionId(null);
  if (sid == null || !sessions.has(sid)) {
    return JSON.stringify({ ok: true });
  }
  // Send dispose to worker so it can clean up internal state
  try {
    await callWorker(sid, { type: 'dispose' }, 5000);
  } catch (_) {
    // Worker may already be dead — that's fine
  }
  disposeSession(sid);
  return JSON.stringify({ ok: true });
}

// ---------------------------------------------------------------------------
// REPL API
// ---------------------------------------------------------------------------

/**
 * Create a new REPL session.
 * @param {string} replId Unique identifier for this REPL handle.
 * @param {string} [scriptName] Optional script name for tracebacks.
 * @returns {Promise<string>} JSON result.
 */
async function replCreate(replId, scriptName) {
  const sid = resolveSessionId(null);
  if (sid == null || !sessions.has(sid)) return notInitializedError();
  const session = sessions.get(sid);
  const result = await callWorker(sid, { type: 'replCreate', replId, scriptName }, session.timeoutMs);
  return JSON.stringify(result);
}

/**
 * Feed code to the REPL and run to completion.
 * @param {string} replId Unique identifier for this REPL handle.
 */
async function replFeedRun(replId, code) {
  const sid = resolveSessionId(null);
  if (sid == null || !sessions.has(sid)) return notInitializedError();
  const session = sessions.get(sid);
  const result = await callWorker(sid, { type: 'replFeedRun', replId, code }, session.timeoutMs);
  return JSON.stringify(result);
}

async function replFeedStart(replId, code) {
  const sid = resolveSessionId(null);
  if (sid == null || !sessions.has(sid)) return notInitializedError();
  const session = sessions.get(sid);
  const result = await callWorker(sid, { type: 'replFeedStart', replId, code }, session.timeoutMs);
  return JSON.stringify(result);
}

async function replSetExtFns(replId, extFnsCsv) {
  const sid = resolveSessionId(null);
  if (sid == null || !sessions.has(sid)) return notInitializedError();
  const session = sessions.get(sid);
  const extFns = extFnsCsv ? extFnsCsv.split(',') : [];
  const result = await callWorker(sid, { type: 'replSetExtFns', replId, extFns }, session.timeoutMs);
  return JSON.stringify(result);
}

async function replResume(replId, valueJson) {
  const sid = resolveSessionId(null);
  if (sid == null || !sessions.has(sid)) return notInitializedError();
  const session = sessions.get(sid);
  const value = JSON.parse(valueJson);
  const result = await callWorker(sid, { type: 'replResume', replId, value }, session.timeoutMs);
  return JSON.stringify(result);
}

async function replResumeWithError(replId, errorJson) {
  const sid = resolveSessionId(null);
  if (sid == null || !sessions.has(sid)) return notInitializedError();
  const session = sessions.get(sid);
  const errorMessage = JSON.parse(errorJson);
  const result = await callWorker(sid, { type: 'replResumeWithError', replId, errorMessage }, session.timeoutMs);
  return JSON.stringify(result);
}

async function replResumeNotFound(replId, fnNameJson) {
  const sid = resolveSessionId(null);
  if (sid == null || !sessions.has(sid)) return notInitializedError();
  const session = sessions.get(sid);
  const fnName = JSON.parse(fnNameJson);
  const result = await callWorker(
    sid,
    { type: 'replResumeNotFound', replId, fnName },
    session.timeoutMs,
  );
  return JSON.stringify(result);
}

async function replDetectContinuation(source) {
  const sid = resolveSessionId(null);
  if (sid == null || !sessions.has(sid)) return notInitializedError();
  const session = sessions.get(sid);
  const result = await callWorker(sid, { type: 'replDetectContinuation', source }, session.timeoutMs);
  return JSON.stringify(result);
}

async function replDispose(replId) {
  const sid = resolveSessionId(null);
  if (sid == null || !sessions.has(sid)) return notInitializedError();
  const session = sessions.get(sid);
  const result = await callWorker(sid, { type: 'replDispose', replId }, session.timeoutMs);
  return JSON.stringify(result);
}

/**
 * Snapshot a REPL handle's heap to postcard bytes.
 *
 * @param {string} replId Unique identifier for the REPL handle.
 * @returns {Promise<Object>} Raw JS object with snapshotBuffer ArrayBuffer.
 */
async function replSnapshot(replId) {
  const sid = resolveSessionId(null);
  if (sid == null || !sessions.has(sid)) {
    return { ok: false, error: 'Not initialized' };
  }
  const session = sessions.get(sid);
  const result = await callWorker(sid, { type: 'replSnapshot', replId }, session.timeoutMs);
  // Return raw JS object — snapshotBuffer is an ArrayBuffer, not JSON-safe.
  return result;
}

/**
 * Restore a REPL handle from base64-encoded postcard bytes.
 *
 * @param {string} replId   Unique identifier for the REPL handle.
 * @param {string} dataBase64 Base64-encoded snapshot data.
 * @returns {Promise<string>} JSON result.
 */
async function replRestore(replId, dataBase64) {
  const sid = resolveSessionId(null);
  if (sid == null || !sessions.has(sid)) return notInitializedError();
  const session = sessions.get(sid);
  const result = await callWorker(
    sid, { type: 'replRestore', replId, dataBase64 }, session.timeoutMs,
  );
  return JSON.stringify(result);
}

// Expose bridge on window for Dart JS interop
window.DartMontyBridge = {
  init,
  run,
  start,
  resume,
  resumeWithError,
  resumeWithException,
  resumeNotFound,
  resumeAsFuture,
  resolveFutures,
  resumeNameLookupValue,
  resumeNameLookupUndefined,
  snapshot,
  restore,
  compile,
  runPrecompiled,
  startPrecompiled,
  discover,
  cancel,
  dispose,
  // Phase 2 multi-session API
  createSession,
  disposeSession,
  getDefaultSessionId: () => defaultSessionId,
  // REPL API
  replCreate,
  replFeedRun,
  replFeedStart,
  replSetExtFns,
  replResume,
  replResumeWithError,
  replResumeNotFound,
  replDetectContinuation,
  replDispose,
  replSnapshot,
  replRestore,
};

console.log('[DartMontyBridge] Registered on window (Worker pool architecture)');
