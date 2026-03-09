/**
 * wasi_shim.js — Minimal WASI shim for dart_monty_native.wasm.
 *
 * Provides only the 6 WASI imports the module actually needs:
 *   random_get, clock_time_get, fd_write, environ_get,
 *   environ_sizes_get, proc_exit
 *
 * This replaces the entire NAPI-RS runtime + @pydantic/monty npm stack.
 */

/**
 * Create a WASI import object for the given WASM memory.
 *
 * @param {function} getMemory — returns the WebAssembly.Memory instance.
 * @returns {Object} wasi_snapshot_preview1 import namespace.
 */
export function createWasiImports(getMemory) {
  return {
    // Fill buffer with cryptographic random bytes.
    // (buf: i32, buf_len: i32) -> errno: i32
    random_get(buf, bufLen) {
      const mem = new Uint8Array(getMemory().buffer);
      crypto.getRandomValues(mem.subarray(buf, buf + bufLen));
      return 0; // ESUCCESS
    },

    // Get clock time (CLOCK_MONOTONIC = 1, CLOCK_REALTIME = 0).
    // (id: i32, precision: i64, out: i32) -> errno: i32
    clock_time_get(id, _precision, out) {
      const mem = new DataView(getMemory().buffer);
      const nowNs = BigInt(Math.round(performance.now() * 1e6));
      mem.setBigUint64(out, nowNs, true); // little-endian
      return 0;
    },

    // Write to file descriptor (only fd=1 stdout and fd=2 stderr matter).
    // (fd: i32, iovs: i32, iovsLen: i32, nwritten: i32) -> errno: i32
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
      if (fd === 1) {
        console.log('[monty stdout]', text);
      } else if (fd === 2) {
        console.warn('[monty stderr]', text);
      }

      mem.setUint32(nwritten, totalWritten, true);
      return 0;
    },

    // Get environment variables — we provide none.
    // (environ: i32, environ_buf: i32) -> errno: i32
    environ_get(_environ, _environBuf) {
      return 0;
    },

    // Get environment variable sizes — zero.
    // (count_out: i32, bufsize_out: i32) -> errno: i32
    environ_sizes_get(countOut, bufsizeOut) {
      const mem = new DataView(getMemory().buffer);
      mem.setUint32(countOut, 0, true);
      mem.setUint32(bufsizeOut, 0, true);
      return 0;
    },

    // Process exit — should never be called in reactor mode.
    // (code: i32) -> noreturn
    proc_exit(code) {
      throw new Error(`WASI proc_exit called with code ${code}`);
    },
  };
}
