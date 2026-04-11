/**
 * dart_monty.h — C API for the Monty sandboxed Python interpreter.
 *
 * This header is designed for use with Dart's ffigen tool.
 * All strings are NUL-terminated UTF-8. Callers must free returned
 * strings with monty_string_free() and byte buffers with monty_bytes_free().
 */

#ifndef DART_MONTY_H
#define DART_MONTY_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------ */
/* Opaque handle                                                      */
/* ------------------------------------------------------------------ */

/** Opaque handle to a compiled Python program. */
typedef struct MontyHandle MontyHandle;

/* ------------------------------------------------------------------ */
/* Enums                                                              */
/* ------------------------------------------------------------------ */

/** Result tag for monty_run(). */
typedef enum {
    MONTY_RESULT_OK    = 0,
    MONTY_RESULT_ERROR = 1,
} MontyResultTag;

/** Progress tag for monty_start() / monty_resume(). */
typedef enum {
    MONTY_PROGRESS_COMPLETE        = 0,
    MONTY_PROGRESS_PENDING         = 1,
    MONTY_PROGRESS_ERROR           = 2,
    MONTY_PROGRESS_RESOLVE_FUTURES = 3,
    MONTY_PROGRESS_OS_CALL         = 4,
} MontyProgressTag;

/* ------------------------------------------------------------------ */
/* Lifecycle                                                          */
/* ------------------------------------------------------------------ */

/**
 * Create a new handle from Python source code.
 *
 * @param code         NUL-terminated UTF-8 Python source.
 * @param ext_fns      Comma-separated external function names, or NULL.
 * @param script_name  NUL-terminated script name for tracebacks, or NULL
 *                     for the default ("<input>").
 * @param out_error    On failure, receives a heap-allocated error message.
 *                     Caller frees with monty_string_free(). May be NULL.
 * @return             Heap-allocated handle, or NULL on error.
 */
MontyHandle *monty_create(const char *code,
                           const char *ext_fns,
                           const char *script_name,
                           char **out_error);

/**
 * Free a handle. Safe to call with NULL.
 */
void monty_free(MontyHandle *handle);

/* ------------------------------------------------------------------ */
/* Run to completion                                                  */
/* ------------------------------------------------------------------ */

/**
 * Run Python code to completion.
 *
 * @param handle       Valid handle from monty_create().
 * @param result_json  Receives heap-allocated JSON result string.
 *                     Caller frees with monty_string_free(). May be NULL.
 * @param error_msg    Receives heap-allocated error message on failure,
 *                     or NULL on success. Caller frees with monty_string_free().
 * @return             MONTY_RESULT_OK or MONTY_RESULT_ERROR.
 */
MontyResultTag monty_run(MontyHandle *handle,
                          char **result_json,
                          char **error_msg);

/* ------------------------------------------------------------------ */
/* Iterative execution                                                */
/* ------------------------------------------------------------------ */

/**
 * Start iterative execution. Pauses at external function calls.
 *
 * @param handle     Valid handle from monty_create().
 * @param out_error  Receives error message on failure. Caller frees.
 * @return           MONTY_PROGRESS_COMPLETE, _PENDING, or _ERROR.
 */
MontyProgressTag monty_start(MontyHandle *handle,
                              char **out_error);

/**
 * Resume execution with a return value.
 *
 * @param handle      Handle in PENDING state.
 * @param value_json  NUL-terminated JSON value to return to Python.
 * @param out_error   Receives error message on failure. Caller frees.
 * @return            MONTY_PROGRESS_COMPLETE, _PENDING, or _ERROR.
 */
MontyProgressTag monty_resume(MontyHandle *handle,
                               const char *value_json,
                               char **out_error);

/**
 * Resume execution with an error (raises RuntimeError in Python).
 *
 * @param handle         Handle in PENDING state.
 * @param error_message  NUL-terminated error message string.
 * @param out_error      Receives FFI error message on failure. Caller frees.
 * @return               MONTY_PROGRESS_COMPLETE, _PENDING, or _ERROR.
 */
MontyProgressTag monty_resume_with_error(MontyHandle *handle,
                                          const char *error_message,
                                          char **out_error);

/* ------------------------------------------------------------------ */
/* Async / Futures                                                    */
/* ------------------------------------------------------------------ */

/**
 * Resume by creating a future (tells the VM this call returns a future).
 * Only valid when handle is in PENDING state.
 *
 * @param handle     Handle in PENDING state.
 * @param out_error  Receives error message on failure. Caller frees.
 * @return           MONTY_PROGRESS_COMPLETE, _PENDING, _RESOLVE_FUTURES,
 *                   or _ERROR.
 */
MontyProgressTag monty_resume_as_future(MontyHandle *handle,
                                         char **out_error);

/**
 * Get the pending future call IDs as a JSON array.
 * Only valid after progress returned MONTY_PROGRESS_RESOLVE_FUTURES.
 *
 * @return  Heap-allocated JSON array string (e.g. "[0,1,2]"), or NULL.
 *          Caller frees with monty_string_free().
 */
char *monty_pending_future_call_ids(const MontyHandle *handle);

/**
 * Resume futures with results and errors.
 * Only valid when handle is in RESOLVE_FUTURES state.
 *
 * @param handle        Handle in RESOLVE_FUTURES state.
 * @param results_json  JSON object mapping call_id (string) to value,
 *                      e.g. {"0": "value0", "1": 42}.
 * @param errors_json   JSON object mapping call_id (string) to error message,
 *                      e.g. {"2": "timeout"}. Use "{}" for no errors.
 * @param out_error     Receives error message on failure. Caller frees.
 * @return              MONTY_PROGRESS_COMPLETE, _RESOLVE_FUTURES, _PENDING,
 *                      or _ERROR.
 */
MontyProgressTag monty_resume_futures(MontyHandle *handle,
                                       const char *results_json,
                                       const char *errors_json,
                                       char **out_error);

/* ------------------------------------------------------------------ */
/* State accessors                                                    */
/* ------------------------------------------------------------------ */

/**
 * Get the pending external function name.
 * Only valid after monty_start/monty_resume returned MONTY_PROGRESS_PENDING.
 *
 * @return  Heap-allocated string, or NULL. Caller frees with monty_string_free().
 */
char *monty_pending_fn_name(const MontyHandle *handle);

/**
 * Get the pending function arguments as a JSON array.
 * Only valid after monty_start/monty_resume returned MONTY_PROGRESS_PENDING.
 *
 * @return  Heap-allocated JSON string, or NULL. Caller frees with monty_string_free().
 */
char *monty_pending_fn_args_json(const MontyHandle *handle);

/**
 * Get the pending function keyword arguments as a JSON object.
 * Only valid after monty_start/monty_resume returned MONTY_PROGRESS_PENDING.
 *
 * @return  Heap-allocated JSON string (e.g. "{}"), or NULL.
 *          Caller frees with monty_string_free().
 */
char *monty_pending_fn_kwargs_json(const MontyHandle *handle);

/**
 * Get the pending call ID (monotonically increasing per execution).
 * Only valid after monty_start/monty_resume returned MONTY_PROGRESS_PENDING.
 *
 * @return  Call ID, or UINT32_MAX if not in Paused state.
 */
uint32_t monty_pending_call_id(const MontyHandle *handle);

/**
 * Whether the pending call is a method call (obj.method() vs func()).
 * Only valid after monty_start/monty_resume returned MONTY_PROGRESS_PENDING.
 *
 * @return  1 for method call, 0 for function call, -1 if not in Paused state.
 */
int monty_pending_method_call(const MontyHandle *handle);

/* ------------------------------------------------------------------ */
/* OsCall accessors (valid after MONTY_PROGRESS_OS_CALL)              */
/* ------------------------------------------------------------------ */

/**
 * Get the OS function name, e.g. "Path.read_text", "os.getenv".
 * @return  Heap-allocated string, or NULL. Caller frees with monty_string_free().
 */
char *monty_os_call_fn_name(const MontyHandle *handle);

/**
 * Get the OS call positional arguments as a JSON array string.
 * @return  Heap-allocated JSON string, or NULL. Caller frees with monty_string_free().
 */
char *monty_os_call_args_json(const MontyHandle *handle);

/**
 * Get the OS call keyword arguments as a JSON object string.
 * @return  Heap-allocated JSON string, or NULL. Caller frees with monty_string_free().
 */
char *monty_os_call_kwargs_json(const MontyHandle *handle);

/**
 * Get the OS call ID.
 * @return  The call ID, or UINT32_MAX if not in OsCall state.
 */
uint32_t monty_os_call_id(const MontyHandle *handle);

/**
 * Get the completed result as a JSON string.
 * Only valid after execution reached COMPLETE state.
 *
 * @return  Heap-allocated JSON string, or NULL. Caller frees with monty_string_free().
 */
char *monty_complete_result_json(const MontyHandle *handle);

/**
 * Check whether the completed result is an error.
 *
 * @return  1 = error, 0 = success, -1 = not in Complete state.
 */
int monty_complete_is_error(const MontyHandle *handle);

/* ------------------------------------------------------------------ */
/* Snapshots                                                          */
/* ------------------------------------------------------------------ */

/**
 * Serialize compiled code to a byte buffer (snapshot).
 * Only valid in Ready state.
 *
 * @param handle   Valid handle.
 * @param out_len  Receives byte count.
 * @return         Heap-allocated byte buffer, or NULL. Caller frees with monty_bytes_free().
 */
uint8_t *monty_snapshot(const MontyHandle *handle,
                         size_t *out_len);

/**
 * Restore a handle from a snapshot byte buffer.
 *
 * @param data       Pointer to snapshot bytes.
 * @param len        Byte count.
 * @param out_error  Receives error message on failure. Caller frees.
 * @return           New heap-allocated handle, or NULL on error.
 */
MontyHandle *monty_restore(const uint8_t *data,
                            size_t len,
                            char **out_error);

/* ------------------------------------------------------------------ */
/* Resource limits                                                    */
/* ------------------------------------------------------------------ */

/** Set memory limit in bytes. Call before monty_run/monty_start. */
void monty_set_memory_limit(MontyHandle *handle, size_t bytes);

/** Set execution time limit in milliseconds. */
void monty_set_time_limit_ms(MontyHandle *handle, uint64_t ms);

/** Set stack depth limit. */
void monty_set_stack_limit(MontyHandle *handle, size_t depth);

/* ------------------------------------------------------------------ */
/* REPL (stateful session)                                            */
/* ------------------------------------------------------------------ */

/** Opaque handle to a persistent REPL session. */
typedef struct MontyReplHandle MontyReplHandle;

/**
 * Create a new REPL handle with empty interpreter state.
 *
 * @param script_name  NUL-terminated script name for tracebacks, or NULL
 *                     for the default ("repl.py").
 * @param out_error    On failure, receives a heap-allocated error message.
 *                     Caller frees with monty_string_free(). May be NULL.
 * @return             Heap-allocated REPL handle, or NULL on error.
 */
MontyReplHandle *monty_repl_create(const char *script_name,
                                    char **out_error);

/**
 * Free a REPL handle. Safe to call with NULL or an already-freed handle.
 */
void monty_repl_free(MontyReplHandle *handle);

/**
 * Feed a Python snippet to the REPL and run to completion.
 *
 * The REPL handle survives — heap, globals, functions, and classes
 * persist for subsequent calls.
 *
 * @param handle       Valid REPL handle from monty_repl_create().
 * @param code         NUL-terminated UTF-8 Python source.
 * @param result_json  Receives heap-allocated JSON result string.
 *                     Caller frees with monty_string_free(). May be NULL.
 * @param error_msg    Receives heap-allocated error message on failure,
 *                     or NULL on success. Caller frees with monty_string_free().
 * @return             MONTY_RESULT_OK or MONTY_RESULT_ERROR.
 */
MontyResultTag monty_repl_feed_run(MontyReplHandle *handle,
                                    const char *code,
                                    char **result_json,
                                    char **error_msg);

/**
 * Detect whether a source fragment is complete or needs more input.
 *
 * This is a stateless function — no REPL handle is needed.
 *
 * @param source  NUL-terminated UTF-8 Python source fragment.
 * @return        0 = complete, 1 = incomplete (unclosed brackets/strings),
 *                2 = incomplete block (needs trailing blank line).
 */
int monty_repl_detect_continuation(const char *source);

/* ------------------------------------------------------------------ */
/* REPL iterative execution                                           */
/* ------------------------------------------------------------------ */

/** Register external function names for REPL name resolution. */
void monty_repl_set_ext_fns(MontyReplHandle *handle, const char *ext_fns);

/** Start iterative REPL execution. Pauses at external function calls. */
MontyProgressTag monty_repl_feed_start(MontyReplHandle *handle,
                                        const char *code,
                                        char **out_error);

/** Resume REPL execution with a JSON-encoded return value. */
MontyProgressTag monty_repl_resume(MontyReplHandle *handle,
                                    const char *value_json,
                                    char **out_error);

/** Resume REPL execution with an error (raises RuntimeError in Python). */
MontyProgressTag monty_repl_resume_with_error(MontyReplHandle *handle,
                                               const char *error_message,
                                               char **out_error);

/** Resume REPL by creating a future for the pending call. */
MontyProgressTag monty_repl_resume_as_future(MontyReplHandle *handle,
                                              char **out_error);

/** Resolve pending REPL futures with results and errors. */
MontyProgressTag monty_repl_resume_futures(MontyReplHandle *handle,
                                            const char *results_json,
                                            const char *errors_json,
                                            char **out_error);

/* ------------------------------------------------------------------ */
/* REPL state accessors                                               */
/* ------------------------------------------------------------------ */

char *monty_repl_pending_fn_name(const MontyReplHandle *handle);
char *monty_repl_pending_fn_args_json(const MontyReplHandle *handle);
char *monty_repl_pending_fn_kwargs_json(const MontyReplHandle *handle);
uint32_t monty_repl_pending_call_id(const MontyReplHandle *handle);
int monty_repl_pending_method_call(const MontyReplHandle *handle);
char *monty_repl_os_call_fn_name(const MontyReplHandle *handle);
char *monty_repl_os_call_args_json(const MontyReplHandle *handle);
char *monty_repl_os_call_kwargs_json(const MontyReplHandle *handle);
uint32_t monty_repl_os_call_id(const MontyReplHandle *handle);
char *monty_repl_complete_result_json(const MontyReplHandle *handle);
int monty_repl_complete_is_error(const MontyReplHandle *handle);
char *monty_repl_pending_future_call_ids(const MontyReplHandle *handle);

/* ------------------------------------------------------------------ */
/* Memory management                                                  */
/* ------------------------------------------------------------------ */

/** Free a string returned by any monty_* function. Safe with NULL. */
void monty_string_free(char *ptr);

/** Free a byte buffer returned by monty_snapshot(). Safe with NULL. */
void monty_bytes_free(uint8_t *ptr, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* DART_MONTY_H */
