/**
 * wasm_glue.js — WASI shim + C-ABI helpers for dart_monty_core_native.wasm.
 *
 * Replaces the entire NAPI-RS runtime + @pydantic/monty npm stack.
 * Only 6 WASI imports needed: random_get, clock_time_get, fd_write,
 * environ_get, environ_sizes_get, proc_exit.
 */

// ---------------------------------------------------------------------------
// WASI shim
// ---------------------------------------------------------------------------

/**
 * Create WASI import namespace for the given WASM memory.
 *
 * @param {function} getMemory — returns the WebAssembly.Memory instance.
 * @returns {Object} wasi_snapshot_preview1 import namespace.
 */
function createWasiImports(getMemory) {
  return {
    random_get(buf, bufLen) {
      const mem = new Uint8Array(getMemory().buffer);
      // Web Crypto throws QuotaExceededError for buffers > 65536 bytes.
      for (let i = 0; i < bufLen; i += 65536) {
        const chunk = Math.min(65536, bufLen - i);
        crypto.getRandomValues(mem.subarray(buf + i, buf + i + chunk));
      }
      return 0;
    },

    // CLOCK_REALTIME = 0, CLOCK_MONOTONIC = 1
    clock_time_get(id, _precision, out) {
      const mem = new DataView(getMemory().buffer);
      let nowNs;
      if (id === 0) {
        // CLOCK_REALTIME — Unix epoch nanoseconds (for Python time.time())
        nowNs = BigInt(Date.now()) * 1000000n;
      } else {
        // CLOCK_MONOTONIC — page-relative nanoseconds
        nowNs = BigInt(Math.round(performance.now() * 1e6));
      }
      mem.setBigUint64(out, nowNs, true);
      return 0;
    },

    fd_write(fd, iovs, iovsLen, nwritten) {
      const mem = new DataView(getMemory().buffer);
      const bytes = new Uint8Array(getMemory().buffer);
      let totalWritten = 0;
      const parts = [];

      for (let i = 0; i < iovsLen; i++) {
        const ptr = mem.getUint32(iovs + i * 8, true);
        const len = mem.getUint32(iovs + i * 8 + 4, true);
        parts.push(new TextDecoder().decode(bytes.subarray(ptr, ptr + len)));
        totalWritten += len;
      }

      const text = parts.join('');
      if (fd === 1) console.log('[monty]', text);
      else if (fd === 2) console.warn('[monty]', text);

      mem.setUint32(nwritten, totalWritten, true);
      return 0;
    },

    environ_get() { return 0; },

    environ_sizes_get(countOut, bufsizeOut) {
      const mem = new DataView(getMemory().buffer);
      mem.setUint32(countOut, 0, true);
      mem.setUint32(bufsizeOut, 0, true);
      return 0;
    },

    proc_exit(code) {
      throw new Error(`WASI proc_exit called with code ${code}`);
    },
  };
}

// ---------------------------------------------------------------------------
// WASM loader
// ---------------------------------------------------------------------------

let wasm = null;

/**
 * Instantiate dart_monty_core_native.wasm.
 *
 * Uses compileStreaming with ArrayBuffer fallback for servers that
 * don't set the correct application/wasm Content-Type.
 *
 * @param {string|URL} wasmUrl
 * @returns {Promise<WebAssembly.Exports>}
 */
export async function instantiateMonty(wasmUrl) {
  let memory;
  const wasiImports = createWasiImports(() => memory);
  const imports = { wasi_snapshot_preview1: wasiImports };

  let instance;
  try {
    const result = await WebAssembly.instantiateStreaming(
      fetch(wasmUrl),
      imports,
    );
    instance = result.instance;
  } catch (e) {
    // Fallback: fetch as ArrayBuffer (Content-Type mismatch)
    if (e instanceof TypeError || (e.message && e.message.includes('Mime'))) {
      const resp = await fetch(wasmUrl);
      const bytes = await resp.arrayBuffer();
      const result = await WebAssembly.instantiate(bytes, imports);
      instance = result.instance;
    } else {
      throw e;
    }
  }

  wasm = instance.exports;
  memory = wasm.memory;
  return wasm;
}

/** Get the current WASM exports. Throws if not yet instantiated. */
export function getExports() {
  if (!wasm) throw new Error('WASM not instantiated — call instantiateMonty first');
  return wasm;
}

// ---------------------------------------------------------------------------
// String marshalling
// ---------------------------------------------------------------------------

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/**
 * Write a JS string into WASM memory via monty_alloc.
 * Returns { ptr, size } — caller must free with monty_dealloc(ptr, size).
 * Throws on OOM.
 */
export function allocCString(str) {
  const encoded = encoder.encode(str);
  const size = encoded.length + 1;
  const ptr = wasm.monty_alloc(size);
  if (ptr === 0) throw new Error(`monty_alloc(${size}) returned null — OOM`);
  const mem = new Uint8Array(wasm.memory.buffer);
  mem.set(encoded, ptr);
  mem[ptr + encoded.length] = 0;
  return { ptr, size };
}

/**
 * Read a NUL-terminated C string from WASM memory.
 * Returns null if ptr is 0.
 */
export function readCString(ptr) {
  if (ptr === 0) return null;
  const mem = new Uint8Array(wasm.memory.buffer);
  let end = ptr;
  while (end < mem.length && mem[end] !== 0) end++;
  return decoder.decode(mem.subarray(ptr, end));
}

/**
 * Read a C string and free it with monty_string_free.
 * Returns null if ptr is 0.
 */
export function readAndFreeCString(ptr) {
  if (ptr === 0) return null;
  const str = readCString(ptr);
  wasm.monty_string_free(ptr);
  return str;
}

/**
 * Allocate a 4-byte out-pointer slot for wasm32 pointer-out parameters.
 */
export function allocOutPtr() {
  const ptr = wasm.monty_alloc(4);
  if (ptr === 0) throw new Error('monty_alloc(4) returned null — OOM');
  return {
    ptr,
    read() {
      return new DataView(wasm.memory.buffer).getUint32(ptr, true);
    },
    free() {
      wasm.monty_dealloc(ptr, 4);
    },
  };
}

// ProgressTag enum (matches native/src/handle.rs)
export const PROGRESS_COMPLETE = 0;
export const PROGRESS_PENDING = 1;
export const PROGRESS_ERROR = 2;
export const PROGRESS_RESOLVE_FUTURES = 3;
export const PROGRESS_OS_CALL = 4;
export const PROGRESS_NAME_LOOKUP = 5;

// ResultTag enum
export const RESULT_OK = 0;
export const RESULT_ERROR = 1;
