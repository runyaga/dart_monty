(() => {
  // src/bridge.js
  var nextSessionId = 1;
  var sessions = /* @__PURE__ */ new Map();
  var defaultSessionId = null;
  var _bridgeBase = typeof document !== "undefined" && document.currentScript ? new URL(".", document.currentScript.src).href : window.location.href;
  function createSession() {
    return new Promise((resolve, reject) => {
      const sessionId = nextSessionId++;
      try {
        const workerUrl = new URL("./dart_monty_worker.js", _bridgeBase).href;
        const blob = new Blob(
          [`import "${workerUrl}";`],
          { type: "application/javascript" }
        );
        const blobUrl = URL.createObjectURL(blob);
        const worker = new Worker(blobUrl, { type: "module" });
        worker.onerror = (event) => {
          const session = sessions.get(sessionId);
          if (session) {
            for (const req of session.pending.values()) {
              if (req.timer) clearTimeout(req.timer);
              req.reject(new Error(`Panic: Worker crashed: ${event.message || event}`));
            }
            session.pending.clear();
            sessions.delete(sessionId);
            if (defaultSessionId === sessionId) defaultSessionId = null;
          }
          reject(new Error(`Worker failed to start: ${event.message || event}`));
        };
        worker.onmessage = (e) => {
          const msg = e.data;
          if (msg.type === "ready") {
            URL.revokeObjectURL(blobUrl);
            sessions.set(sessionId, {
              worker,
              nextMsgId: 1,
              pending: /* @__PURE__ */ new Map(),
              timeoutMs: null
            });
            console.log(`[DartMontyBridge] Session ${sessionId} ready`);
            resolve(sessionId);
            return;
          }
          if (msg.type === "error" && !msg.id) {
            console.error(`[DartMontyBridge] Session ${sessionId} init error:`, msg.message);
            reject(new Error(msg.message || "Worker init failed"));
            return;
          }
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
  function disposeSession(sessionId) {
    const session = sessions.get(sessionId);
    if (!session) return;
    for (const req of session.pending.values()) {
      if (req.timer) clearTimeout(req.timer);
      req.reject(new Error("MontyDisposed: Session disposed"));
    }
    session.pending.clear();
    session.worker.terminate();
    sessions.delete(sessionId);
    if (defaultSessionId === sessionId) defaultSessionId = null;
  }
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
          for (const req of session.pending.values()) {
            if (req.timer) clearTimeout(req.timer);
            req.reject(new Error("MontyWorkerError: Execution timed out"));
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
  function notInitializedError() {
    return JSON.stringify({ ok: false, error: "Not initialized", errorType: "InitError" });
  }
  function resolveSessionId(sessionId) {
    if (sessionId != null) return sessionId;
    return defaultSessionId;
  }
  function parseHardTimeout(limitsJson) {
    if (!limitsJson) return null;
    const limits = typeof limitsJson === "string" ? JSON.parse(limitsJson) : limitsJson;
    if (limits.timeout_ms != null) {
      return limits.timeout_ms + 1e3;
    }
    return null;
  }
  async function init() {
    if (defaultSessionId != null && sessions.has(defaultSessionId)) return true;
    try {
      defaultSessionId = await createSession();
      return true;
    } catch (e) {
      console.error("[DartMontyBridge] Init failed:", e.message);
      return false;
    }
  }
  async function run(code, limitsJson, scriptName) {
    const sid = resolveSessionId(null);
    if (sid == null || !sessions.has(sid)) return notInitializedError();
    const session = sessions.get(sid);
    const hardTimeout = parseHardTimeout(limitsJson);
    if (hardTimeout != null) session.timeoutMs = hardTimeout;
    const limits = limitsJson ? JSON.parse(limitsJson) : null;
    const msg = { type: "run", code, limits };
    if (scriptName) msg.scriptName = scriptName;
    const result = await callWorker(sid, msg, session.timeoutMs);
    return JSON.stringify(result);
  }
  async function start(code, extFnsJson, limitsJson, scriptName) {
    const sid = resolveSessionId(null);
    if (sid == null || !sessions.has(sid)) return notInitializedError();
    const session = sessions.get(sid);
    const hardTimeout = parseHardTimeout(limitsJson);
    if (hardTimeout != null) session.timeoutMs = hardTimeout;
    const extFns = extFnsJson ? JSON.parse(extFnsJson) : [];
    const limits = limitsJson ? JSON.parse(limitsJson) : null;
    const msg = { type: "start", code, extFns, limits };
    if (scriptName) msg.scriptName = scriptName;
    const result = await callWorker(sid, msg, session.timeoutMs);
    return JSON.stringify(result);
  }
  async function resume(valueJson) {
    const sid = resolveSessionId(null);
    if (sid == null || !sessions.has(sid)) return notInitializedError();
    const session = sessions.get(sid);
    const value = JSON.parse(valueJson);
    const result = await callWorker(sid, { type: "resume", value }, session.timeoutMs);
    return JSON.stringify(result);
  }
  async function resumeWithError(errorJson) {
    const sid = resolveSessionId(null);
    if (sid == null || !sessions.has(sid)) return notInitializedError();
    const session = sessions.get(sid);
    const errorMessage = JSON.parse(errorJson);
    const result = await callWorker(sid, { type: "resumeWithError", errorMessage }, session.timeoutMs);
    return JSON.stringify(result);
  }
  async function resumeAsFuture() {
    const sid = resolveSessionId(null);
    if (sid == null || !sessions.has(sid)) return notInitializedError();
    const session = sessions.get(sid);
    const result = await callWorker(sid, { type: "resumeAsFuture" }, session.timeoutMs);
    return JSON.stringify(result);
  }
  async function resolveFutures(resultsJson, errorsJson) {
    const sid = resolveSessionId(null);
    if (sid == null || !sessions.has(sid)) return notInitializedError();
    const session = sessions.get(sid);
    const result = await callWorker(
      sid,
      { type: "resolveFutures", resultsJson, errorsJson },
      session.timeoutMs
    );
    return JSON.stringify(result);
  }
  async function snapshot() {
    const sid = resolveSessionId(null);
    if (sid == null || !sessions.has(sid)) {
      return { ok: false, error: "Not initialized" };
    }
    const session = sessions.get(sid);
    const result = await callWorker(sid, { type: "snapshot" }, session.timeoutMs);
    return result;
  }
  async function restore(dataBase64) {
    const sid = resolveSessionId(null);
    if (sid == null || !sessions.has(sid)) return notInitializedError();
    const session = sessions.get(sid);
    const result = await callWorker(sid, { type: "restore", dataBase64 }, session.timeoutMs);
    return JSON.stringify(result);
  }
  function discover() {
    return JSON.stringify({
      loaded: sessions.size > 0,
      sessionCount: sessions.size,
      architecture: "worker-pool"
    });
  }
  async function dispose() {
    const sid = resolveSessionId(null);
    if (sid == null || !sessions.has(sid)) {
      return JSON.stringify({ ok: true });
    }
    try {
      await callWorker(sid, { type: "dispose" }, 5e3);
    } catch (_) {
    }
    disposeSession(sid);
    return JSON.stringify({ ok: true });
  }
  window.DartMontyBridge = {
    init,
    run,
    start,
    resume,
    resumeWithError,
    resumeAsFuture,
    resolveFutures,
    snapshot,
    restore,
    discover,
    dispose,
    // Phase 2 multi-session API
    createSession,
    disposeSession,
    getDefaultSessionId: () => defaultSessionId
  };
  console.log("[DartMontyBridge] Registered on window (Worker pool architecture)");
})();
