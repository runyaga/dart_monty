#![allow(clippy::missing_safety_doc)]

mod convert;
mod error;
mod handle;
mod repl_handle;

pub use handle::{MontyHandle, MontyProgressTag, MontyResultTag};
pub use repl_handle::MontyReplHandle;

use std::ffi::{c_char, c_int};
use std::ptr;

use error::{catch_ffi_panic, parse_c_str, to_c_string};

/// Common FFI wrapper for functions returning `MontyProgressTag`.
/// Handles: handle null check, panic boundary, error out-parameter.
macro_rules! ffi_progress {
    ($handle:expr, $out_error:expr, |$h:ident| $body:expr) => {{
        if $handle.is_null() {
            if !$out_error.is_null() {
                // SAFETY: out_error is non-null (just checked), Dart caller provides a valid writable pointer
                unsafe { *$out_error = to_c_string("handle is NULL") };
            }
            return MontyProgressTag::Error;
        }
        // SAFETY: handle is non-null (just checked) and was created by monty_create via Box::into_raw
        let $h = unsafe { &mut *$handle };
        match catch_ffi_panic(|| $body) {
            Ok((tag, err)) => {
                if !$out_error.is_null() {
                    match err {
                        // SAFETY: out_error is non-null (just checked), writing error message string
                        Some(ref msg) => unsafe { *$out_error = to_c_string(msg) },
                        // SAFETY: out_error is non-null (just checked), clearing error to indicate success
                        None => unsafe { *$out_error = ptr::null_mut() },
                    }
                }
                tag
            }
            Err(panic_msg) => {
                if !$out_error.is_null() {
                    // SAFETY: out_error is non-null (just checked), writing panic message string
                    unsafe { *$out_error = to_c_string(&panic_msg) };
                }
                MontyProgressTag::Error
            }
        }
    }};
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

/// Create a new `MontyHandle` from Python source code.
///
/// - `code`: NUL-terminated UTF-8 Python source.
/// - `ext_fns`: NUL-terminated comma-separated external function names (or NULL).
/// - `script_name`: NUL-terminated UTF-8 script name for tracebacks (or NULL for `"<input>"`).
/// - `out_error`: on failure, receives an error message (caller frees with `monty_string_free`).
///
/// Returns a heap-allocated handle, or NULL on error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_create(
    code: *const c_char,
    ext_fns: *const c_char,
    script_name: *const c_char,
    out_error: *mut *mut c_char,
) -> *mut MontyHandle {
    // SAFETY: code is a NUL-terminated C string from Dart FFI; parse_c_str validates non-null
    let code_str = match unsafe { parse_c_str(code, "code", out_error) } {
        Ok(s) => s.to_string(),
        Err(()) => return ptr::null_mut(),
    };

    let ext_fn_list = if ext_fns.is_null() {
        vec![]
    } else {
        // SAFETY: ext_fns is non-null (just checked), NUL-terminated C string from Dart FFI
        match unsafe { parse_c_str(ext_fns, "ext_fns", out_error) } {
            Ok("") => vec![],
            Ok(s) => s.split(',').map(|f| f.trim().to_string()).collect(),
            Err(()) => return ptr::null_mut(),
        }
    };

    let name = if script_name.is_null() {
        None
    } else {
        // SAFETY: script_name is non-null (just checked), NUL-terminated C string from Dart FFI
        match unsafe { parse_c_str(script_name, "script_name", out_error) } {
            Ok(s) => Some(s.to_string()),
            Err(()) => return ptr::null_mut(),
        }
    };

    match catch_ffi_panic(|| MontyHandle::new(code_str, ext_fn_list, name)) {
        Ok(Ok(handle)) => {
            let ptr = Box::into_raw(Box::new(handle));
            LIVE_HANDLES
                .write()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .insert(ptr as usize);
            ptr
        }
        Ok(Err(exc)) => {
            if !out_error.is_null() {
                // SAFETY: out_error is non-null (just checked), writing compilation error message
                unsafe { *out_error = to_c_string(&exc.summary()) };
            }
            ptr::null_mut()
        }
        Err(panic_msg) => {
            if !out_error.is_null() {
                // SAFETY: out_error is non-null (just checked), writing panic error message
                unsafe { *out_error = to_c_string(&panic_msg) };
            }
            ptr::null_mut()
        }
    }
}

/// Set of live handle pointers for double-free protection.
/// Entries are added by `monty_create`/`monty_restore` and removed by `monty_free`.
static LIVE_HANDLES: std::sync::LazyLock<std::sync::RwLock<std::collections::HashSet<usize>>> =
    std::sync::LazyLock::new(|| std::sync::RwLock::new(std::collections::HashSet::new()));

/// Free a `MontyHandle`. Safe to call with NULL or an already-freed handle.
///
/// Uses `LIVE_HANDLES` to verify the pointer is still live before
/// reclaiming memory. A second call on the same pointer is a no-op.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_free(handle: *mut MontyHandle) {
    if handle.is_null() {
        return;
    }
    let addr = handle as usize;
    let removed = LIVE_HANDLES
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .remove(&addr);
    if !removed {
        return; // already freed or unknown pointer
    }
    // SAFETY: handle was created by Box::into_raw in monty_create/monty_restore, LIVE_HANDLES confirms it is still live
    drop(unsafe { Box::from_raw(handle) });
}

// ---------------------------------------------------------------------------
// Execution: run to completion
// ---------------------------------------------------------------------------

/// Run Python code to completion.
///
/// - `result_json`: receives the result JSON string (caller frees with `monty_string_free`).
/// - `error_msg`: receives an error message on failure (caller frees with `monty_string_free`),
///   or NULL on success.
///
/// Returns `MONTY_RESULT_OK` or `MONTY_RESULT_ERROR`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_run(
    handle: *mut MontyHandle,
    result_json: *mut *mut c_char,
    error_msg: *mut *mut c_char,
) -> MontyResultTag {
    if handle.is_null() {
        if !error_msg.is_null() {
            // SAFETY: error_msg is non-null (just checked), Dart caller provides a valid writable pointer
            unsafe { *error_msg = to_c_string("handle is NULL") };
        }
        return MontyResultTag::Error;
    }

    // SAFETY: handle is non-null (just checked) and was created by monty_create via Box::into_raw
    let h = unsafe { &mut *handle };

    match catch_ffi_panic(|| h.run()) {
        Ok((tag, json, err)) => {
            if !result_json.is_null() {
                // SAFETY: result_json is non-null (just checked), writing result JSON string
                unsafe { *result_json = to_c_string(&json) };
            }
            if !error_msg.is_null() {
                match err {
                    // SAFETY: error_msg is non-null (just checked), writing error message
                    Some(ref msg) => unsafe { *error_msg = to_c_string(msg) },
                    // SAFETY: error_msg is non-null (just checked), clearing error to indicate success
                    None => unsafe { *error_msg = ptr::null_mut() },
                }
            }
            tag
        }
        Err(panic_msg) => {
            if !error_msg.is_null() {
                // SAFETY: error_msg is non-null (just checked), writing panic error message
                unsafe { *error_msg = to_c_string(&panic_msg) };
            }
            MontyResultTag::Error
        }
    }
}

// ---------------------------------------------------------------------------
// Execution: iterative (start / resume)
// ---------------------------------------------------------------------------

/// Start iterative execution (pauses at external function calls).
///
/// - `out_error`: receives an error message on failure (caller frees).
///
/// Returns `MONTY_PROGRESS_COMPLETE`, `MONTY_PROGRESS_PENDING`, or `MONTY_PROGRESS_ERROR`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_start(
    handle: *mut MontyHandle,
    out_error: *mut *mut c_char,
) -> MontyProgressTag {
    ffi_progress!(handle, out_error, |h| h.start())
}

/// Resume execution with a return value (JSON string).
///
/// - `value_json`: NUL-terminated JSON value to return to Python.
/// - `out_error`: receives an error message on failure (caller frees).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_resume(
    handle: *mut MontyHandle,
    value_json: *const c_char,
    out_error: *mut *mut c_char,
) -> MontyProgressTag {
    // SAFETY: value_json is a NUL-terminated C string from Dart FFI; parse_c_str validates non-null
    let Ok(json_str) = (unsafe { parse_c_str(value_json, "value_json", out_error) }) else {
        return MontyProgressTag::Error;
    };
    ffi_progress!(handle, out_error, |h| h.resume(json_str))
}

/// Resume execution with an error (raises RuntimeError in Python).
///
/// - `error_message`: NUL-terminated error message.
/// - `out_error`: receives an error message on FFI failure (caller frees).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_resume_with_error(
    handle: *mut MontyHandle,
    error_message: *const c_char,
    out_error: *mut *mut c_char,
) -> MontyProgressTag {
    // SAFETY: error_message is a NUL-terminated C string from Dart FFI; parse_c_str validates non-null
    let Ok(msg) = (unsafe { parse_c_str(error_message, "error_message", out_error) }) else {
        return MontyProgressTag::Error;
    };
    ffi_progress!(handle, out_error, |h| h.resume_with_error(msg))
}

// ---------------------------------------------------------------------------
// Async / Futures
// ---------------------------------------------------------------------------

/// Resume by creating a future (the VM registers a future for this call_id).
///
/// - `out_error`: receives an error message on failure (caller frees).
///
/// Returns `MONTY_PROGRESS_COMPLETE`, `MONTY_PROGRESS_PENDING`,
/// `MONTY_PROGRESS_RESOLVE_FUTURES`, or `MONTY_PROGRESS_ERROR`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_resume_as_future(
    handle: *mut MontyHandle,
    out_error: *mut *mut c_char,
) -> MontyProgressTag {
    ffi_progress!(handle, out_error, |h| h.resume_as_future())
}

/// Get the pending future call IDs as a JSON array.
/// Only valid when handle is in RESOLVE_FUTURES state.
/// Caller frees with `monty_string_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_pending_future_call_ids(handle: *const MontyHandle) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    // SAFETY: handle is non-null (just checked) and was created by monty_create via Box::into_raw
    // SAFETY: handle is non-null (just checked), created by monty_repl_create via Box::into_raw
    let h = unsafe { &*handle };
    match h.pending_future_call_ids() {
        Some(json) => to_c_string(json),
        None => ptr::null_mut(),
    }
}

/// Resume futures with results and errors.
///
/// - `results_json`: JSON object `{"call_id": value, ...}` (string keys)
/// - `errors_json`: JSON object `{"call_id": "error_msg", ...}` (string keys)
/// - `out_error`: receives an error message on failure (caller frees).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_resume_futures(
    handle: *mut MontyHandle,
    results_json: *const c_char,
    errors_json: *const c_char,
    out_error: *mut *mut c_char,
) -> MontyProgressTag {
    // SAFETY: results_json is a NUL-terminated C string from Dart FFI; parse_c_str validates non-null
    let Ok(results_str) = (unsafe { parse_c_str(results_json, "results_json", out_error) }) else {
        return MontyProgressTag::Error;
    };
    // SAFETY: errors_json is a NUL-terminated C string from Dart FFI; parse_c_str validates non-null
    let Ok(errors_str) = (unsafe { parse_c_str(errors_json, "errors_json", out_error) }) else {
        return MontyProgressTag::Error;
    };
    ffi_progress!(handle, out_error, |h| h
        .resume_futures(results_str, errors_str))
}

// ---------------------------------------------------------------------------
// State accessors
// ---------------------------------------------------------------------------

/// Get the pending function name (only valid after `monty_start`/`monty_resume`
/// returned `MONTY_PROGRESS_PENDING`). Caller frees with `monty_string_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_pending_fn_name(handle: *const MontyHandle) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    // SAFETY: handle is non-null (just checked) and was created by monty_create via Box::into_raw
    // SAFETY: handle is non-null (just checked), created by monty_repl_create via Box::into_raw
    let h = unsafe { &*handle };
    match h.pending_fn_name() {
        Some(name) => to_c_string(name),
        None => ptr::null_mut(),
    }
}

/// Get the pending function arguments as a JSON array string.
/// Caller frees with `monty_string_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_pending_fn_args_json(handle: *const MontyHandle) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    // SAFETY: handle is non-null (just checked) and was created by monty_create via Box::into_raw
    // SAFETY: handle is non-null (just checked), created by monty_repl_create via Box::into_raw
    let h = unsafe { &*handle };
    match h.pending_fn_args_json() {
        Some(json) => to_c_string(json),
        None => ptr::null_mut(),
    }
}

/// Get the pending function keyword arguments as a JSON object string.
/// Returns `"{}"` if no kwargs were passed.
/// Caller frees with `monty_string_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_pending_fn_kwargs_json(handle: *const MontyHandle) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    // SAFETY: handle is non-null (just checked) and was created by monty_create via Box::into_raw
    // SAFETY: handle is non-null (just checked), created by monty_repl_create via Box::into_raw
    let h = unsafe { &*handle };
    match h.pending_fn_kwargs_json() {
        Some(json) => to_c_string(json),
        None => ptr::null_mut(),
    }
}

/// Get the pending call ID (monotonically increasing per-execution).
/// Returns the call ID, or `u32::MAX` if not in Paused state.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_pending_call_id(handle: *const MontyHandle) -> u32 {
    if handle.is_null() {
        return u32::MAX;
    }
    // SAFETY: handle is non-null (just checked) and was created by monty_create via Box::into_raw
    // SAFETY: handle is non-null (just checked), created by monty_repl_create via Box::into_raw
    let h = unsafe { &*handle };
    h.pending_call_id().unwrap_or(u32::MAX)
}

/// Whether the pending call is a method call (`obj.method()` vs `func()`).
/// Returns 1 for method call, 0 for function call, -1 if not in Paused state.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_pending_method_call(handle: *const MontyHandle) -> c_int {
    if handle.is_null() {
        return -1;
    }
    // SAFETY: handle is non-null (just checked) and was created by monty_create via Box::into_raw
    // SAFETY: handle is non-null (just checked), created by monty_repl_create via Box::into_raw
    let h = unsafe { &*handle };
    match h.pending_method_call() {
        Some(true) => 1,
        Some(false) => 0,
        None => -1,
    }
}

// ---------------------------------------------------------------------------
// OsCall accessors
// ---------------------------------------------------------------------------

/// Get the OS function name (only valid when state is `MONTY_PROGRESS_OS_CALL`).
/// Returns e.g. `"Path.read_text"`, `"os.getenv"`.
/// Caller frees with `monty_string_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_os_call_fn_name(handle: *const MontyHandle) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    // SAFETY: handle is non-null (just checked) and was created by monty_create via Box::into_raw
    // SAFETY: handle is non-null (just checked), created by monty_repl_create via Box::into_raw
    let h = unsafe { &*handle };
    match h.os_call_fn_name() {
        Some(name) => to_c_string(name),
        None => ptr::null_mut(),
    }
}

/// Get the OS call positional arguments as a JSON array string.
/// Caller frees with `monty_string_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_os_call_args_json(handle: *const MontyHandle) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    // SAFETY: handle is non-null (just checked) and was created by monty_create via Box::into_raw
    // SAFETY: handle is non-null (just checked), created by monty_repl_create via Box::into_raw
    let h = unsafe { &*handle };
    match h.os_call_args_json() {
        Some(json) => to_c_string(json),
        None => ptr::null_mut(),
    }
}

/// Get the OS call keyword arguments as a JSON object string.
/// Caller frees with `monty_string_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_os_call_kwargs_json(handle: *const MontyHandle) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    // SAFETY: handle is non-null (just checked) and was created by monty_create via Box::into_raw
    // SAFETY: handle is non-null (just checked), created by monty_repl_create via Box::into_raw
    let h = unsafe { &*handle };
    match h.os_call_kwargs_json() {
        Some(json) => to_c_string(json),
        None => ptr::null_mut(),
    }
}

/// Get the OS call ID. Returns `u32::MAX` if not in OsCall state.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_os_call_id(handle: *const MontyHandle) -> u32 {
    if handle.is_null() {
        return u32::MAX;
    }
    // SAFETY: handle is non-null (just checked) and was created by monty_create via Box::into_raw
    // SAFETY: handle is non-null (just checked), created by monty_repl_create via Box::into_raw
    let h = unsafe { &*handle };
    h.os_call_id().unwrap_or(u32::MAX)
}

/// Get the completed result as a JSON string.
/// Caller frees with `monty_string_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_complete_result_json(handle: *const MontyHandle) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    // SAFETY: handle is non-null (just checked) and was created by monty_create via Box::into_raw
    // SAFETY: handle is non-null (just checked), created by monty_repl_create via Box::into_raw
    let h = unsafe { &*handle };
    match h.complete_result_json() {
        Some(json) => to_c_string(json),
        None => ptr::null_mut(),
    }
}

/// Whether the completed result is an error. Returns 1 for error, 0 for success,
/// -1 if not in Complete state.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_complete_is_error(handle: *const MontyHandle) -> c_int {
    if handle.is_null() {
        return -1;
    }
    // SAFETY: handle is non-null (just checked) and was created by monty_create via Box::into_raw
    // SAFETY: handle is non-null (just checked), created by monty_repl_create via Box::into_raw
    let h = unsafe { &*handle };
    match h.complete_is_error() {
        Some(true) => 1,
        Some(false) => 0,
        None => -1,
    }
}

// ---------------------------------------------------------------------------
// Snapshots
// ---------------------------------------------------------------------------

/// Serialize the compiled code to a byte buffer. Caller frees with `monty_bytes_free`.
///
/// - `out_len`: receives the byte count.
///
/// Returns a heap-allocated byte buffer, or NULL on error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_snapshot(
    handle: *const MontyHandle,
    out_len: *mut usize,
) -> *mut u8 {
    if handle.is_null() || out_len.is_null() {
        return ptr::null_mut();
    }
    // SAFETY: handle is non-null (checked above) and was created by monty_create via Box::into_raw
    // SAFETY: handle is non-null (just checked), created by monty_repl_create via Box::into_raw
    let h = unsafe { &*handle };
    match catch_ffi_panic(|| h.snapshot()) {
        Ok(Ok(bytes)) => {
            let len = bytes.len();
            let boxed = bytes.into_boxed_slice();
            let ptr = Box::into_raw(boxed).cast::<u8>();
            // SAFETY: out_len is non-null (checked above), writing the byte count of the snapshot
            unsafe { *out_len = len };
            ptr
        }
        Ok(Err(_)) | Err(_) => ptr::null_mut(),
    }
}

/// Restore a `MontyHandle` from a snapshot byte buffer.
///
/// - `data`: pointer to the byte buffer.
/// - `len`: byte count.
/// - `out_error`: receives an error message on failure (caller frees).
///
/// Returns a new handle, or NULL on error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_restore(
    data: *const u8,
    len: usize,
    out_error: *mut *mut c_char,
) -> *mut MontyHandle {
    if data.is_null() {
        if !out_error.is_null() {
            // SAFETY: out_error is non-null (just checked), writing error message
            unsafe { *out_error = to_c_string("data is NULL") };
        }
        return ptr::null_mut();
    }

    // SAFETY: data is non-null (just checked), len is provided by caller matching the snapshot buffer size
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    match catch_ffi_panic(|| MontyHandle::restore(bytes)) {
        Ok(Ok(handle)) => {
            let ptr = Box::into_raw(Box::new(handle));
            LIVE_HANDLES
                .write()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .insert(ptr as usize);
            ptr
        }
        Ok(Err(msg)) => {
            if !out_error.is_null() {
                // SAFETY: out_error is non-null (just checked), writing restore error message
                unsafe { *out_error = to_c_string(&msg) };
            }
            ptr::null_mut()
        }
        Err(panic_msg) => {
            if !out_error.is_null() {
                // SAFETY: out_error is non-null (just checked), writing panic error message
                unsafe { *out_error = to_c_string(&panic_msg) };
            }
            ptr::null_mut()
        }
    }
}

// ---------------------------------------------------------------------------
// Resource limits
// ---------------------------------------------------------------------------

/// Set the memory limit in bytes. Must be called before `monty_run` or `monty_start`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_set_memory_limit(handle: *mut MontyHandle, bytes: usize) {
    if !handle.is_null() {
        // SAFETY: handle is non-null (just checked) and was created by monty_create via Box::into_raw
        unsafe { &mut *handle }.set_memory_limit(bytes);
    }
}

/// Set the execution time limit in milliseconds.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_set_time_limit_ms(handle: *mut MontyHandle, ms: u64) {
    if !handle.is_null() {
        // SAFETY: handle is non-null (just checked) and was created by monty_create via Box::into_raw
        unsafe { &mut *handle }.set_time_limit_ms(ms);
    }
}

/// Set the stack depth limit.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_set_stack_limit(handle: *mut MontyHandle, depth: usize) {
    if !handle.is_null() {
        // SAFETY: handle is non-null (just checked) and was created by monty_create via Box::into_raw
        unsafe { &mut *handle }.set_stack_limit(depth);
    }
}

// ---------------------------------------------------------------------------
// REPL lifecycle
// ---------------------------------------------------------------------------

/// Set of live REPL handle pointers for double-free protection.
///
/// Separate from `LIVE_HANDLES` to prevent type confusion — a `MontyHandle`
/// pointer passed to `monty_repl_free` (or vice versa) will be rejected.
static LIVE_REPL_HANDLES: std::sync::LazyLock<std::sync::RwLock<std::collections::HashSet<usize>>> =
    std::sync::LazyLock::new(|| std::sync::RwLock::new(std::collections::HashSet::new()));

/// Create a new REPL handle with an empty interpreter state.
///
/// - `script_name`: NUL-terminated UTF-8 script name for tracebacks (or NULL for `"repl.py"`).
/// - `out_error`: on failure, receives an error message (caller frees with `monty_string_free`).
///
/// Returns a heap-allocated REPL handle, or NULL on error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_repl_create(
    script_name: *const c_char,
    out_error: *mut *mut c_char,
) -> *mut MontyReplHandle {
    let name = if script_name.is_null() {
        "repl.py".to_string()
    } else {
        // SAFETY: script_name is non-null (just checked), NUL-terminated C string from Dart FFI
        match unsafe { parse_c_str(script_name, "script_name", out_error) } {
            Ok(s) => s.to_string(),
            Err(()) => return ptr::null_mut(),
        }
    };

    match catch_ffi_panic(|| MontyReplHandle::new(&name)) {
        Ok(handle) => {
            let ptr = Box::into_raw(Box::new(handle));
            LIVE_REPL_HANDLES
                .write()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .insert(ptr as usize);
            ptr
        }
        Err(panic_msg) => {
            if !out_error.is_null() {
                // SAFETY: out_error is non-null (just checked), writing panic error message
                unsafe { *out_error = to_c_string(&panic_msg) };
            }
            ptr::null_mut()
        }
    }
}

/// Free a REPL handle. Safe to call with NULL or an already-freed handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_repl_free(handle: *mut MontyReplHandle) {
    if handle.is_null() {
        return;
    }
    let addr = handle as usize;
    let removed = LIVE_REPL_HANDLES
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .remove(&addr);
    if !removed {
        return; // already freed or unknown pointer
    }
    // SAFETY: handle was created by Box::into_raw in monty_repl_create, LIVE_REPL_HANDLES confirms it is still live
    drop(unsafe { Box::from_raw(handle) });
}

/// Feed a Python snippet to the REPL and run to completion.
///
/// The REPL handle survives — state (heap, globals, functions, classes)
/// persists for subsequent calls.
///
/// - `code`: NUL-terminated UTF-8 Python source.
/// - `result_json`: receives the result JSON string (caller frees with `monty_string_free`).
/// - `error_msg`: receives an error message on failure (caller frees with `monty_string_free`).
///
/// Returns `MONTY_RESULT_OK` or `MONTY_RESULT_ERROR`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_repl_feed_run(
    handle: *mut MontyReplHandle,
    code: *const c_char,
    result_json: *mut *mut c_char,
    error_msg: *mut *mut c_char,
) -> MontyResultTag {
    if handle.is_null() {
        if !error_msg.is_null() {
            // SAFETY: error_msg is non-null (just checked), Dart caller provides a valid writable pointer
            unsafe { *error_msg = to_c_string("handle is NULL") };
        }
        return MontyResultTag::Error;
    }

    // SAFETY: code is a NUL-terminated C string from Dart FFI; parse_c_str validates non-null
    let Ok(code_str) = (unsafe { parse_c_str(code, "code", error_msg) }) else {
        return MontyResultTag::Error;
    };

    // SAFETY: handle is non-null (just checked) and was created by monty_repl_create via Box::into_raw
    let h = unsafe { &mut *handle };

    match catch_ffi_panic(|| h.feed_run(code_str)) {
        Ok((tag, json, err)) => {
            if !result_json.is_null() {
                // SAFETY: result_json is non-null (just checked), writing result JSON string
                unsafe { *result_json = to_c_string(&json) };
            }
            if !error_msg.is_null() {
                match err {
                    // SAFETY: error_msg is non-null (just checked), writing error message string
                    Some(ref msg) => unsafe { *error_msg = to_c_string(msg) },
                    // SAFETY: error_msg is non-null (just checked), clearing error to indicate success
                    None => unsafe { *error_msg = ptr::null_mut() },
                }
            }
            tag
        }
        Err(panic_msg) => {
            if !error_msg.is_null() {
                // SAFETY: error_msg is non-null (just checked), writing panic message string
                unsafe { *error_msg = to_c_string(&panic_msg) };
            }
            MontyResultTag::Error
        }
    }
}

/// Detect whether a source fragment is complete or needs more input.
///
/// Returns:
/// - `0` = Complete (ready to execute)
/// - `1` = Incomplete (unclosed brackets/strings)
/// - `2` = Incomplete block (needs trailing blank line)
///
/// This is a stateless function — no REPL handle needed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_repl_detect_continuation(source: *const c_char) -> c_int {
    if source.is_null() {
        return 0; // treat null as complete
    }
    // SAFETY: source is non-null (just checked), NUL-terminated C string
    let Ok(source_str) = unsafe { std::ffi::CStr::from_ptr(source) }.to_str() else {
        return 0; // invalid UTF-8 → treat as complete
    };

    MontyReplHandle::detect_continuation(source_str)
}

// ---------------------------------------------------------------------------
// REPL iterative execution
// ---------------------------------------------------------------------------

/// Common FFI wrapper for REPL functions returning `MontyProgressTag`.
macro_rules! ffi_repl_progress {
    ($handle:expr, $out_error:expr, |$h:ident| $body:expr) => {{
        if $handle.is_null() {
            if !$out_error.is_null() {
                // SAFETY: out_error is non-null (just checked), Dart caller provides a valid writable pointer
                unsafe { *$out_error = to_c_string("handle is NULL") };
            }
            return MontyProgressTag::Error;
        }
        // SAFETY: handle is non-null (just checked) and was created by monty_repl_create via Box::into_raw
        let $h = unsafe { &mut *$handle };
        match catch_ffi_panic(|| $body) {
            Ok((tag, err)) => {
                if !$out_error.is_null() {
                    match err {
                        // SAFETY: out_error is non-null (just checked), writing error message string
                        Some(ref msg) => unsafe { *$out_error = to_c_string(msg) },
                        // SAFETY: out_error is non-null (just checked), clearing error to indicate success
                        None => unsafe { *$out_error = ptr::null_mut() },
                    }
                }
                tag
            }
            Err(panic_msg) => {
                if !$out_error.is_null() {
                    // SAFETY: out_error is non-null (just checked), writing panic message string
                    unsafe { *$out_error = to_c_string(&panic_msg) };
                }
                MontyProgressTag::Error
            }
        }
    }};
}

/// Register external function names for REPL name resolution.
///
/// - `ext_fns`: NUL-terminated comma-separated function names (or NULL to clear).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_repl_set_ext_fns(
    handle: *mut MontyReplHandle,
    ext_fns: *const c_char,
) {
    if handle.is_null() {
        return;
    }
    // SAFETY: handle is non-null (just checked), created by monty_repl_create
    let h = unsafe { &mut *handle };
    if ext_fns.is_null() {
        h.set_ext_fns(vec![]);
    } else {
        // SAFETY: ext_fns is non-null (just checked), NUL-terminated C string
        if let Ok(s) = unsafe { std::ffi::CStr::from_ptr(ext_fns) }.to_str() {
            let names: Vec<String> = if s.is_empty() {
                vec![]
            } else {
                s.split(',').map(|f| f.trim().to_string()).collect()
            };
            h.set_ext_fns(names);
        }
    }
}

/// Start iterative REPL execution. Pauses at external function calls.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_repl_feed_start(
    handle: *mut MontyReplHandle,
    code: *const c_char,
    out_error: *mut *mut c_char,
) -> MontyProgressTag {
    if handle.is_null() {
        if !out_error.is_null() {
            // SAFETY: out_error is non-null (just checked), Dart caller provides a valid writable pointer
            unsafe { *out_error = to_c_string("handle is NULL") };
        }
        return MontyProgressTag::Error;
    }
    // SAFETY: code is a NUL-terminated C string from Dart FFI; parse_c_str validates non-null
    let Ok(code_str) = (unsafe { parse_c_str(code, "code", out_error) }) else {
        return MontyProgressTag::Error;
    };
    // SAFETY: handle is non-null (just checked), created by monty_repl_create via Box::into_raw
    let h = unsafe { &mut *handle };
    match catch_ffi_panic(|| h.feed_start(code_str)) {
        Ok((tag, err)) => {
            if !out_error.is_null() {
                match err {
                    // SAFETY: out_error is non-null (just checked), writing error message string
                    Some(ref msg) => unsafe { *out_error = to_c_string(msg) },
                    // SAFETY: out_error is non-null (just checked), clearing error to indicate success
                    None => unsafe { *out_error = ptr::null_mut() },
                }
            }
            tag
        }
        Err(panic_msg) => {
            if !out_error.is_null() {
                // SAFETY: out_error is non-null (just checked), writing panic message string
                unsafe { *out_error = to_c_string(&panic_msg) };
            }
            MontyProgressTag::Error
        }
    }
}

/// Resume REPL execution with a JSON-encoded return value.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_repl_resume(
    handle: *mut MontyReplHandle,
    value_json: *const c_char,
    out_error: *mut *mut c_char,
) -> MontyProgressTag {
    if handle.is_null() {
        if !out_error.is_null() {
            // SAFETY: out_error is non-null (just checked), Dart caller provides a valid writable pointer
            unsafe { *out_error = to_c_string("handle is NULL") };
        }
        return MontyProgressTag::Error;
    }
    // SAFETY: value_json is a NUL-terminated C string from Dart FFI; parse_c_str validates non-null
    let Ok(val_str) = (unsafe { parse_c_str(value_json, "value_json", out_error) }) else {
        return MontyProgressTag::Error;
    };
    // SAFETY: handle is non-null (just checked), created by monty_repl_create via Box::into_raw
    let h = unsafe { &mut *handle };
    match catch_ffi_panic(|| h.resume(val_str)) {
        Ok((tag, err)) => {
            if !out_error.is_null() {
                match err {
                    // SAFETY: out_error is non-null (just checked), writing error message string
                    Some(ref msg) => unsafe { *out_error = to_c_string(msg) },
                    // SAFETY: out_error is non-null (just checked), clearing error to indicate success
                    None => unsafe { *out_error = ptr::null_mut() },
                }
            }
            tag
        }
        Err(panic_msg) => {
            if !out_error.is_null() {
                // SAFETY: out_error is non-null (just checked), writing panic message string
                unsafe { *out_error = to_c_string(&panic_msg) };
            }
            MontyProgressTag::Error
        }
    }
}

/// Resume REPL execution with an error (raises RuntimeError in Python).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_repl_resume_with_error(
    handle: *mut MontyReplHandle,
    error_message: *const c_char,
    out_error: *mut *mut c_char,
) -> MontyProgressTag {
    if handle.is_null() {
        if !out_error.is_null() {
            // SAFETY: out_error is non-null (just checked), Dart caller provides a valid writable pointer
            unsafe { *out_error = to_c_string("handle is NULL") };
        }
        return MontyProgressTag::Error;
    }
    // SAFETY: error_message is a NUL-terminated C string from Dart FFI; parse_c_str validates non-null
    let Ok(msg_str) = (unsafe { parse_c_str(error_message, "error_message", out_error) }) else {
        return MontyProgressTag::Error;
    };
    // SAFETY: handle is non-null (just checked), created by monty_repl_create via Box::into_raw
    let h = unsafe { &mut *handle };
    match catch_ffi_panic(|| h.resume_with_error(msg_str)) {
        Ok((tag, err)) => {
            if !out_error.is_null() {
                match err {
                    // SAFETY: out_error is non-null (just checked), writing error message string
                    Some(ref msg) => unsafe { *out_error = to_c_string(msg) },
                    // SAFETY: out_error is non-null (just checked), clearing error to indicate success
                    None => unsafe { *out_error = ptr::null_mut() },
                }
            }
            tag
        }
        Err(panic_msg) => {
            if !out_error.is_null() {
                // SAFETY: out_error is non-null (just checked), writing panic message string
                unsafe { *out_error = to_c_string(&panic_msg) };
            }
            MontyProgressTag::Error
        }
    }
}

/// Resume REPL by creating a future for the pending call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_repl_resume_as_future(
    handle: *mut MontyReplHandle,
    out_error: *mut *mut c_char,
) -> MontyProgressTag {
    ffi_repl_progress!(handle, out_error, |h| h.resume_as_future())
}

/// Resolve pending REPL futures with results and errors.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_repl_resume_futures(
    handle: *mut MontyReplHandle,
    results_json: *const c_char,
    errors_json: *const c_char,
    out_error: *mut *mut c_char,
) -> MontyProgressTag {
    if handle.is_null() {
        if !out_error.is_null() {
            // SAFETY: out_error is non-null (just checked), Dart caller provides a valid writable pointer
            unsafe { *out_error = to_c_string("handle is NULL") };
        }
        return MontyProgressTag::Error;
    }
    // SAFETY: results_json is a NUL-terminated C string from Dart FFI; parse_c_str validates non-null
    let Ok(results_str) = (unsafe { parse_c_str(results_json, "results_json", out_error) }) else {
        return MontyProgressTag::Error;
    };
    // SAFETY: errors_json is a NUL-terminated C string from Dart FFI; parse_c_str validates non-null
    let Ok(errors_str) = (unsafe { parse_c_str(errors_json, "errors_json", out_error) }) else {
        return MontyProgressTag::Error;
    };
    // SAFETY: handle is non-null (just checked), created by monty_repl_create via Box::into_raw
    let h = unsafe { &mut *handle };
    match catch_ffi_panic(|| h.resume_futures(results_str, errors_str)) {
        Ok((tag, err)) => {
            if !out_error.is_null() {
                match err {
                    // SAFETY: out_error is non-null (just checked), writing error message string
                    Some(ref msg) => unsafe { *out_error = to_c_string(msg) },
                    // SAFETY: out_error is non-null (just checked), clearing error to indicate success
                    None => unsafe { *out_error = ptr::null_mut() },
                }
            }
            tag
        }
        Err(panic_msg) => {
            if !out_error.is_null() {
                // SAFETY: out_error is non-null (just checked), writing panic message string
                unsafe { *out_error = to_c_string(&panic_msg) };
            }
            MontyProgressTag::Error
        }
    }
}

// ---------------------------------------------------------------------------
// REPL state accessors
// ---------------------------------------------------------------------------

/// Get the REPL pending external function name.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_repl_pending_fn_name(handle: *const MontyReplHandle) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    // SAFETY: handle is non-null (just checked), created by monty_repl_create via Box::into_raw
    let h = unsafe { &*handle };
    h.pending_fn_name().map_or(ptr::null_mut(), to_c_string)
}

/// Get the REPL pending function arguments as a JSON array.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_repl_pending_fn_args_json(
    handle: *const MontyReplHandle,
) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    // SAFETY: handle is non-null (just checked), created by monty_repl_create via Box::into_raw
    let h = unsafe { &*handle };
    h.pending_fn_args_json()
        .map_or(ptr::null_mut(), to_c_string)
}

/// Get the REPL pending keyword arguments as a JSON object.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_repl_pending_fn_kwargs_json(
    handle: *const MontyReplHandle,
) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    // SAFETY: handle is non-null (just checked), created by monty_repl_create via Box::into_raw
    let h = unsafe { &*handle };
    h.pending_fn_kwargs_json()
        .map_or(ptr::null_mut(), to_c_string)
}

/// Get the REPL pending call ID.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_repl_pending_call_id(handle: *const MontyReplHandle) -> u32 {
    if handle.is_null() {
        return u32::MAX;
    }
    // SAFETY: handle is non-null (just checked), created by monty_repl_create via Box::into_raw
    let h = unsafe { &*handle };
    h.pending_call_id().unwrap_or(u32::MAX)
}

/// Whether the REPL pending call is a method call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_repl_pending_method_call(handle: *const MontyReplHandle) -> c_int {
    if handle.is_null() {
        return -1;
    }
    // SAFETY: handle is non-null (just checked), created by monty_repl_create via Box::into_raw
    let h = unsafe { &*handle };
    match h.pending_method_call() {
        Some(true) => 1,
        Some(false) => 0,
        None => -1,
    }
}

/// Get the REPL OS call function name.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_repl_os_call_fn_name(handle: *const MontyReplHandle) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    // SAFETY: handle is non-null (just checked), created by monty_repl_create via Box::into_raw
    let h = unsafe { &*handle };
    h.os_call_fn_name().map_or(ptr::null_mut(), to_c_string)
}

/// Get the REPL OS call arguments as a JSON array.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_repl_os_call_args_json(
    handle: *const MontyReplHandle,
) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    // SAFETY: handle is non-null (just checked), created by monty_repl_create via Box::into_raw
    let h = unsafe { &*handle };
    h.os_call_args_json().map_or(ptr::null_mut(), to_c_string)
}

/// Get the REPL OS call keyword arguments as a JSON object.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_repl_os_call_kwargs_json(
    handle: *const MontyReplHandle,
) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    // SAFETY: handle is non-null (just checked), created by monty_repl_create via Box::into_raw
    let h = unsafe { &*handle };
    h.os_call_kwargs_json().map_or(ptr::null_mut(), to_c_string)
}

/// Get the REPL OS call ID.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_repl_os_call_id(handle: *const MontyReplHandle) -> u32 {
    if handle.is_null() {
        return u32::MAX;
    }
    // SAFETY: handle is non-null (just checked), created by monty_repl_create via Box::into_raw
    let h = unsafe { &*handle };
    h.os_call_id().unwrap_or(u32::MAX)
}

/// Get the REPL completed result as a JSON string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_repl_complete_result_json(
    handle: *const MontyReplHandle,
) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    // SAFETY: handle is non-null (just checked), created by monty_repl_create via Box::into_raw
    let h = unsafe { &*handle };
    h.complete_result_json()
        .map_or(ptr::null_mut(), to_c_string)
}

/// Check whether the REPL completed result is an error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_repl_complete_is_error(handle: *const MontyReplHandle) -> c_int {
    if handle.is_null() {
        return -1;
    }
    // SAFETY: handle is non-null (just checked), created by monty_repl_create via Box::into_raw
    let h = unsafe { &*handle };
    match h.complete_is_error() {
        Some(true) => 1,
        Some(false) => 0,
        None => -1,
    }
}

/// Get the REPL pending future call IDs as a JSON array.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_repl_pending_future_call_ids(
    handle: *const MontyReplHandle,
) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    // SAFETY: handle is non-null (just checked), created by monty_repl_create via Box::into_raw
    let h = unsafe { &*handle };
    h.pending_future_call_ids()
        .map_or(ptr::null_mut(), to_c_string)
}

// ---------------------------------------------------------------------------
// Memory management
// ---------------------------------------------------------------------------

/// Free a C string returned by any `monty_*` function.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        // SAFETY: ptr was allocated by CString::into_raw in to_c_string, reclaiming ownership for deallocation
        drop(unsafe { std::ffi::CString::from_raw(ptr) });
    }
}

/// Free a byte buffer returned by `monty_snapshot`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_bytes_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() && len > 0 {
        // SAFETY: ptr+len were returned by monty_snapshot via Box::into_raw, reclaiming the boxed slice
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)) });
    }
}

// ---------------------------------------------------------------------------
// WASM allocator exports (needed for wasm32-wasip1 — no default malloc/free)
// ---------------------------------------------------------------------------

/// Allocate `size` bytes of zeroed memory. Returns null on failure or size==0.
/// Caller must pair with `monty_dealloc(ptr, size)`.
#[unsafe(no_mangle)]
pub extern "C" fn monty_alloc(size: usize) -> *mut u8 {
    if size == 0 {
        return ptr::null_mut();
    }
    let Ok(layout) = std::alloc::Layout::from_size_align(size, 1) else {
        return ptr::null_mut();
    };
    // SAFETY: layout has valid non-zero size and alignment of 1, which is always valid
    let ptr = unsafe { std::alloc::alloc(layout) };
    if ptr.is_null() {
        return ptr::null_mut();
    }
    // SAFETY: ptr is non-null (just checked) and points to `size` bytes of allocated memory
    unsafe { std::ptr::write_bytes(ptr, 0, size) };
    ptr
}

/// Free memory previously allocated by `monty_alloc`. No-op if ptr is null or size is 0.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_dealloc(ptr: *mut u8, size: usize) {
    if ptr.is_null() || size == 0 {
        return;
    }
    let Ok(layout) = std::alloc::Layout::from_size_align(size, 1) else {
        return;
    };
    // SAFETY: ptr was allocated by monty_alloc with the same layout (size, align=1)
    unsafe { std::alloc::dealloc(ptr, layout) };
}

// ---------------------------------------------------------------------------
// FFI unit tests
//
// These tests call the `#[no_mangle]` entry points directly using raw
// pointers, mirroring what a Dart/C caller does. Each test frees every
// heap allocation it receives so that address-sanitiser or Miri runs stay
// clean. String inputs are created with `CString::new(...).unwrap().into_raw()`
// and reclaimed after the FFI call; string outputs are freed with
// `monty_string_free`; byte buffers with `monty_bytes_free`.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod ffi_tests {
    use super::*;
    use std::ffi::{CStr, CString};
    use std::ptr;

    // --- Helpers -----------------------------------------------------------

    fn c(s: &str) -> *mut std::ffi::c_char {
        CString::new(s).unwrap().into_raw()
    }

    unsafe fn free_c(p: *mut std::ffi::c_char) {
        if !p.is_null() {
            // SAFETY: p was produced by CString::into_raw
            drop(unsafe { CString::from_raw(p) });
        }
    }

    unsafe fn c_str(p: *const std::ffi::c_char) -> &'static str {
        // SAFETY: p is a valid NUL-terminated C string from our FFI
        unsafe { CStr::from_ptr(p) }.to_str().unwrap()
    }

    // -----------------------------------------------------------------------
    // monty_create
    // -----------------------------------------------------------------------

    #[test]
    fn ffi_create_null_code() {
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: passing null code — must return NULL and set error message
        let h = unsafe { monty_create(ptr::null(), ptr::null(), ptr::null(), &mut err) };
        assert!(h.is_null());
        assert!(!err.is_null());
        // SAFETY: err is a valid NUL-terminated C string set by monty_create
        let msg = unsafe { c_str(err) };
        assert!(
            msg.contains("NULL"),
            "error should mention NULL, got: {msg}"
        );
        // SAFETY: monty_string_free reclaims the C string allocated by to_c_string
        unsafe { monty_string_free(err) };
    }

    #[test]
    fn ffi_create_null_code_null_out_error() {
        // null code + null out_error: must return NULL without crashing
        // SAFETY: both pointers are null; monty_create must guard both writes
        let h = unsafe { monty_create(ptr::null(), ptr::null(), ptr::null(), ptr::null_mut()) };
        assert!(h.is_null());
    }

    #[test]
    fn ffi_create_syntax_error() {
        let code = c("def");
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: code is a valid NUL-terminated C string
        let h = unsafe { monty_create(code, ptr::null(), ptr::null(), &mut err) };
        assert!(h.is_null());
        assert!(!err.is_null());
        // SAFETY: monty_string_free reclaims the allocation
        unsafe {
            monty_string_free(err);
            free_c(code);
        }
    }

    #[test]
    fn ffi_create_simple() {
        let code = c("2 + 2");
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: code is a valid NUL-terminated C string
        let h = unsafe { monty_create(code, ptr::null(), ptr::null(), &mut err) };
        assert!(!h.is_null());
        assert!(err.is_null());
        // SAFETY: h was created by monty_create; monty_free reclaims it
        unsafe {
            monty_free(h);
            free_c(code);
        }
    }

    #[test]
    fn ffi_create_with_ext_fns() {
        let code = c("result = my_fn(1)\nresult");
        let ext = c("my_fn");
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: both C strings are valid
        let h = unsafe { monty_create(code, ext, ptr::null(), &mut err) };
        assert!(!h.is_null());
        // SAFETY: h was created by monty_create
        unsafe {
            monty_free(h);
            free_c(code);
            free_c(ext);
        }
    }

    #[test]
    fn ffi_create_with_empty_ext_fns() {
        let code = c("2 + 2");
        let ext = c("");
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: both C strings are valid
        let h = unsafe { monty_create(code, ext, ptr::null(), &mut err) };
        assert!(!h.is_null());
        // SAFETY: h was created by monty_create
        unsafe {
            monty_free(h);
            free_c(code);
            free_c(ext);
        }
    }

    #[test]
    fn ffi_create_with_script_name() {
        let code = c("1/0");
        let name = c("test_script.py");
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: both C strings are valid
        let h = unsafe { monty_create(code, ptr::null(), name, &mut err) };
        assert!(!h.is_null());
        // SAFETY: h was created by monty_create
        unsafe {
            monty_free(h);
            free_c(code);
            free_c(name);
        }
    }

    // -----------------------------------------------------------------------
    // monty_free
    // -----------------------------------------------------------------------

    #[test]
    fn ffi_free_null() {
        // SAFETY: passing null to monty_free must be a no-op
        unsafe { monty_free(ptr::null_mut()) };
    }

    #[test]
    fn ffi_free_double_free() {
        let code = c("2 + 2");
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: code is a valid C string
        let h = unsafe { monty_create(code, ptr::null(), ptr::null(), &mut err) };
        assert!(!h.is_null());
        // SAFETY: first free is legitimate
        unsafe { monty_free(h) };
        // SAFETY: second free must be a safe no-op (pointer no longer in LIVE_HANDLES)
        unsafe { monty_free(h) };
        unsafe { free_c(code) };
    }

    // -----------------------------------------------------------------------
    // monty_run
    // -----------------------------------------------------------------------

    #[test]
    fn ffi_run_null_handle() {
        let mut result: *mut std::ffi::c_char = ptr::null_mut();
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: null handle — must return Error and set error message
        let tag = unsafe { monty_run(ptr::null_mut(), &mut result, &mut err) };
        assert_eq!(tag, MontyResultTag::Error);
        assert!(!err.is_null());
        // SAFETY: err was allocated by to_c_string
        unsafe { monty_string_free(err) };
    }

    #[test]
    fn ffi_run_null_handle_null_out_error() {
        let mut result: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: null handle + null error_msg — must return Error without crashing
        let tag = unsafe { monty_run(ptr::null_mut(), &mut result, ptr::null_mut()) };
        assert_eq!(tag, MontyResultTag::Error);
    }

    #[test]
    fn ffi_run_success() {
        let code = c("2 + 2");
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: code is valid
        let h = unsafe { monty_create(code, ptr::null(), ptr::null(), &mut err) };
        assert!(!h.is_null());

        let mut result: *mut std::ffi::c_char = ptr::null_mut();
        let mut run_err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: h is a valid live handle
        let tag = unsafe { monty_run(h, &mut result, &mut run_err) };
        assert_eq!(tag, MontyResultTag::Ok);
        assert!(!result.is_null());
        assert!(run_err.is_null());

        // SAFETY: result is a valid JSON C string from monty_run
        let json_str = unsafe { c_str(result) };
        let parsed: serde_json::Value = serde_json::from_str(json_str).unwrap();
        assert_eq!(parsed["value"], serde_json::json!(4));

        // SAFETY: free allocations
        unsafe {
            monty_string_free(result);
            monty_free(h);
            free_c(code);
        }
    }

    #[test]
    fn ffi_run_null_out_params() {
        let code = c("2 + 2");
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: code is valid
        let h = unsafe { monty_create(code, ptr::null(), ptr::null(), &mut err) };
        assert!(!h.is_null());

        // SAFETY: both out-params are null — should not crash
        let tag = unsafe { monty_run(h, ptr::null_mut(), ptr::null_mut()) };
        assert_eq!(tag, MontyResultTag::Ok);

        // SAFETY: free
        unsafe {
            monty_free(h);
            free_c(code);
        }
    }

    #[test]
    fn ffi_run_error() {
        let code = c("1/0");
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: code is valid
        let h = unsafe { monty_create(code, ptr::null(), ptr::null(), &mut err) };
        assert!(!h.is_null());

        let mut result: *mut std::ffi::c_char = ptr::null_mut();
        let mut run_err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: h is valid
        let tag = unsafe { monty_run(h, &mut result, &mut run_err) };
        assert_eq!(tag, MontyResultTag::Error);
        assert!(!run_err.is_null());

        // SAFETY: free
        unsafe {
            monty_string_free(result);
            monty_string_free(run_err);
            monty_free(h);
            free_c(code);
        }
    }

    // -----------------------------------------------------------------------
    // monty_start / monty_resume / monty_resume_with_error
    // -----------------------------------------------------------------------

    #[test]
    fn ffi_start_null_handle() {
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: null handle
        let tag = unsafe { monty_start(ptr::null_mut(), &mut err) };
        assert_eq!(tag, MontyProgressTag::Error);
        assert!(!err.is_null());
        // SAFETY: err is a valid C string
        unsafe { monty_string_free(err) };
    }

    #[test]
    fn ffi_start_success() {
        let code = c("2 + 2");
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: code is valid
        let h = unsafe { monty_create(code, ptr::null(), ptr::null(), &mut err) };
        assert!(!h.is_null());

        let mut start_err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: h is valid
        let tag = unsafe { monty_start(h, &mut start_err) };
        assert_eq!(tag, MontyProgressTag::Complete);
        assert!(start_err.is_null());

        // SAFETY: free
        unsafe {
            monty_free(h);
            free_c(code);
        }
    }

    #[test]
    fn ffi_resume_null_handle() {
        let val = c("42");
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: null handle
        let tag = unsafe { monty_resume(ptr::null_mut(), val, &mut err) };
        assert_eq!(tag, MontyProgressTag::Error);
        // SAFETY: free
        unsafe {
            monty_string_free(err);
            free_c(val);
        }
    }

    #[test]
    fn ffi_resume_null_value_json() {
        let code = c("result = my_fn(1)\nresult");
        let ext = c("my_fn");
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: code and ext are valid
        let h = unsafe { monty_create(code, ext, ptr::null(), &mut err) };
        assert!(!h.is_null());

        let mut start_err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: h is valid
        let tag = unsafe { monty_start(h, &mut start_err) };
        assert_eq!(tag, MontyProgressTag::Pending);

        let mut resume_err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: null value_json — should return Error
        let tag = unsafe { monty_resume(h, ptr::null(), &mut resume_err) };
        assert_eq!(tag, MontyProgressTag::Error);
        assert!(!resume_err.is_null());

        // SAFETY: free
        unsafe {
            monty_string_free(resume_err);
            monty_free(h);
            free_c(code);
            free_c(ext);
        }
    }

    #[test]
    fn ffi_start_resume_cycle() {
        let code = c("result = my_fn(1)\nresult");
        let ext = c("my_fn");
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: both are valid C strings
        let h = unsafe { monty_create(code, ext, ptr::null(), &mut err) };
        assert!(!h.is_null());

        let mut start_err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: h is valid
        let tag = unsafe { monty_start(h, &mut start_err) };
        assert_eq!(tag, MontyProgressTag::Pending);
        assert!(start_err.is_null());

        // Read pending state via FFI accessors
        // SAFETY: h is in Paused state
        let fn_name_ptr = unsafe { monty_pending_fn_name(h) };
        assert!(!fn_name_ptr.is_null());
        let fn_name = unsafe { c_str(fn_name_ptr) };
        assert_eq!(fn_name, "my_fn");
        // SAFETY: fn_name_ptr was allocated by to_c_string
        unsafe { monty_string_free(fn_name_ptr) };

        let val = c("99");
        let mut resume_err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: h is in Paused state, val is valid JSON
        let tag = unsafe { monty_resume(h, val, &mut resume_err) };
        assert_eq!(tag, MontyProgressTag::Complete);
        assert!(resume_err.is_null());

        // SAFETY: h is in Complete state
        let result_ptr = unsafe { monty_complete_result_json(h) };
        assert!(!result_ptr.is_null());
        let result_str = unsafe { c_str(result_ptr) };
        let parsed: serde_json::Value = serde_json::from_str(result_str).unwrap();
        assert_eq!(parsed["value"], serde_json::json!(99));
        // SAFETY: result_ptr was allocated by to_c_string
        unsafe { monty_string_free(result_ptr) };

        // SAFETY: free
        unsafe {
            monty_free(h);
            free_c(code);
            free_c(ext);
            free_c(val);
        }
    }

    #[test]
    fn ffi_resume_with_error_null_handle() {
        let msg = c("boom");
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: null handle
        let tag = unsafe { monty_resume_with_error(ptr::null_mut(), msg, &mut err) };
        assert_eq!(tag, MontyProgressTag::Error);
        // SAFETY: free
        unsafe {
            monty_string_free(err);
            free_c(msg);
        }
    }

    // -----------------------------------------------------------------------
    // Pending accessor FFI functions — null handle returns NULL / MAX / -1
    // -----------------------------------------------------------------------

    #[test]
    fn ffi_pending_accessors_null_handle() {
        // SAFETY: null handles — all must return safe sentinel values
        let fn_name = unsafe { monty_pending_fn_name(ptr::null()) };
        assert!(fn_name.is_null());

        let args = unsafe { monty_pending_fn_args_json(ptr::null()) };
        assert!(args.is_null());

        let kwargs = unsafe { monty_pending_fn_kwargs_json(ptr::null()) };
        assert!(kwargs.is_null());

        let call_id = unsafe { monty_pending_call_id(ptr::null()) };
        assert_eq!(call_id, u32::MAX);

        let method = unsafe { monty_pending_method_call(ptr::null()) };
        assert_eq!(method, -1);
    }

    #[test]
    fn ffi_os_call_accessors_null_handle() {
        // SAFETY: null handles — all must return safe sentinel values
        let name = unsafe { monty_os_call_fn_name(ptr::null()) };
        assert!(name.is_null());

        let args = unsafe { monty_os_call_args_json(ptr::null()) };
        assert!(args.is_null());

        let kwargs = unsafe { monty_os_call_kwargs_json(ptr::null()) };
        assert!(kwargs.is_null());

        let id = unsafe { monty_os_call_id(ptr::null()) };
        assert_eq!(id, u32::MAX);
    }

    #[test]
    fn ffi_complete_accessors_null_handle() {
        // SAFETY: null handles — sentinels
        let result = unsafe { monty_complete_result_json(ptr::null()) };
        assert!(result.is_null());

        let is_err = unsafe { monty_complete_is_error(ptr::null()) };
        assert_eq!(is_err, -1);
    }

    #[test]
    fn ffi_pending_future_call_ids_null_handle() {
        // SAFETY: null handle — must return null
        let ptr = unsafe { monty_pending_future_call_ids(ptr::null()) };
        assert!(ptr.is_null());
    }

    #[test]
    fn ffi_pending_accessors_in_wrong_state() {
        // In Ready (not Paused) state, all accessors return NULL/MAX/-1
        let code = c("2 + 2");
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: code is valid
        let h = unsafe { monty_create(code, ptr::null(), ptr::null(), &mut err) };
        assert!(!h.is_null());

        // SAFETY: h is in Ready state
        let fn_name = unsafe { monty_pending_fn_name(h) };
        assert!(fn_name.is_null());

        let args = unsafe { monty_pending_fn_args_json(h) };
        assert!(args.is_null());

        let call_id = unsafe { monty_pending_call_id(h) };
        assert_eq!(call_id, u32::MAX);

        let method = unsafe { monty_pending_method_call(h) };
        assert_eq!(method, -1);

        // SAFETY: free
        unsafe {
            monty_free(h);
            free_c(code);
        }
    }

    #[test]
    fn ffi_complete_is_error_false() {
        let code = c("2 + 2");
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: code is valid
        let h = unsafe { monty_create(code, ptr::null(), ptr::null(), &mut err) };
        assert!(!h.is_null());

        let mut start_err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: h is valid
        let tag = unsafe { monty_start(h, &mut start_err) };
        assert_eq!(tag, MontyProgressTag::Complete);

        // SAFETY: h is in Complete state (not error)
        let is_err = unsafe { monty_complete_is_error(h) };
        assert_eq!(is_err, 0); // 0 = success

        // SAFETY: free
        unsafe {
            monty_free(h);
            free_c(code);
        }
    }

    #[test]
    fn ffi_complete_is_error_true() {
        let code = c("1/0");
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: code is valid
        let h = unsafe { monty_create(code, ptr::null(), ptr::null(), &mut err) };
        assert!(!h.is_null());

        let mut start_err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: h is valid
        let tag = unsafe { monty_start(h, &mut start_err) };
        assert_eq!(tag, MontyProgressTag::Error);
        // SAFETY: start_err contains the error message
        unsafe { monty_string_free(start_err) };

        // SAFETY: h is in Complete state (with error)
        let is_err = unsafe { monty_complete_is_error(h) };
        assert_eq!(is_err, 1); // 1 = error

        // SAFETY: free
        unsafe {
            monty_free(h);
            free_c(code);
        }
    }

    // -----------------------------------------------------------------------
    // monty_snapshot / monty_restore
    // -----------------------------------------------------------------------

    #[test]
    fn ffi_snapshot_null_handle() {
        let mut out_len: usize = 0;
        // SAFETY: null handle — must return null
        let ptr = unsafe { monty_snapshot(ptr::null(), &mut out_len) };
        assert!(ptr.is_null());
    }

    #[test]
    fn ffi_snapshot_null_out_len() {
        let code = c("2 + 2");
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: code is valid
        let h = unsafe { monty_create(code, ptr::null(), ptr::null(), &mut err) };
        assert!(!h.is_null());

        // SAFETY: null out_len — monty_snapshot must guard this
        let ptr = unsafe { monty_snapshot(h, ptr::null_mut()) };
        assert!(ptr.is_null(), "null out_len should cause null return");

        // SAFETY: free
        unsafe {
            monty_free(h);
            free_c(code);
        }
    }

    #[test]
    fn ffi_snapshot_and_restore() {
        let code = c("2 + 2");
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: code is valid
        let h = unsafe { monty_create(code, ptr::null(), ptr::null(), &mut err) };
        assert!(!h.is_null());

        let mut out_len: usize = 0;
        // SAFETY: h is valid, out_len is a writable usize
        let snap_ptr = unsafe { monty_snapshot(h, &mut out_len) };
        assert!(!snap_ptr.is_null());
        assert!(out_len > 0);

        let mut restore_err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: snap_ptr points to out_len bytes of valid snapshot data
        let h2 = unsafe { monty_restore(snap_ptr, out_len, &mut restore_err) };
        assert!(!h2.is_null());
        assert!(restore_err.is_null());

        // Run the restored handle
        let mut run_result: *mut std::ffi::c_char = ptr::null_mut();
        let mut run_err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: h2 is valid
        let tag = unsafe { monty_run(h2, &mut run_result, &mut run_err) };
        assert_eq!(tag, MontyResultTag::Ok);
        // SAFETY: run_result is a valid JSON C string
        let result_str = unsafe { c_str(run_result) };
        let parsed: serde_json::Value = serde_json::from_str(result_str).unwrap();
        assert_eq!(parsed["value"], serde_json::json!(4));

        // SAFETY: free all allocations
        unsafe {
            monty_string_free(run_result);
            monty_bytes_free(snap_ptr, out_len);
            monty_free(h2);
            monty_free(h);
            free_c(code);
        }
    }

    #[test]
    fn ffi_restore_null_data() {
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: null data — must return null and set error
        let h = unsafe { monty_restore(ptr::null(), 0, &mut err) };
        assert!(h.is_null());
        assert!(!err.is_null());
        // SAFETY: err is a valid C string
        unsafe { monty_string_free(err) };
    }

    #[test]
    fn ffi_restore_invalid_bytes() {
        let bad: &[u8] = &[0, 1, 2, 3, 4];
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: bad.as_ptr() points to len=5 bytes of invalid snapshot data
        let h = unsafe { monty_restore(bad.as_ptr(), bad.len(), &mut err) };
        assert!(h.is_null());
        assert!(!err.is_null());
        // SAFETY: err is a valid C string
        unsafe { monty_string_free(err) };
    }

    // -----------------------------------------------------------------------
    // Resource limit setters — null handle is a no-op
    // -----------------------------------------------------------------------

    #[test]
    fn ffi_set_limits_null_handle() {
        // SAFETY: null handles — must be no-ops
        unsafe {
            monty_set_memory_limit(ptr::null_mut(), 1024 * 1024);
            monty_set_time_limit_ms(ptr::null_mut(), 5000);
            monty_set_stack_limit(ptr::null_mut(), 100);
        }
    }

    #[test]
    fn ffi_set_limits_then_run() {
        let code = c("2 + 2");
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: code is valid
        let h = unsafe { monty_create(code, ptr::null(), ptr::null(), &mut err) };
        assert!(!h.is_null());

        // SAFETY: h is valid
        unsafe {
            monty_set_memory_limit(h, 10 * 1024 * 1024);
            monty_set_time_limit_ms(h, 5000);
            monty_set_stack_limit(h, 200);
        }

        let mut result: *mut std::ffi::c_char = ptr::null_mut();
        let mut run_err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: h is valid with limits configured
        let tag = unsafe { monty_run(h, &mut result, &mut run_err) };
        assert_eq!(tag, MontyResultTag::Ok);

        // SAFETY: free
        unsafe {
            monty_string_free(result);
            monty_free(h);
            free_c(code);
        }
    }

    // -----------------------------------------------------------------------
    // REPL FFI lifecycle
    // -----------------------------------------------------------------------

    #[test]
    fn ffi_repl_create_null_script_name() {
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: null script_name → defaults to "repl.py"
        let h = unsafe { monty_repl_create(ptr::null(), &mut err) };
        assert!(!h.is_null());
        // SAFETY: h was created by monty_repl_create
        unsafe { monty_repl_free(h) };
    }

    #[test]
    fn ffi_repl_create_with_name() {
        let name = c("my_repl.py");
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: name is a valid C string
        let h = unsafe { monty_repl_create(name, &mut err) };
        assert!(!h.is_null());
        // SAFETY: h was created by monty_repl_create
        unsafe {
            monty_repl_free(h);
            free_c(name);
        }
    }

    #[test]
    fn ffi_repl_free_null() {
        // SAFETY: null pointer — must be a no-op
        unsafe { monty_repl_free(ptr::null_mut()) };
    }

    #[test]
    fn ffi_repl_free_double() {
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: null script_name is fine
        let h = unsafe { monty_repl_create(ptr::null(), &mut err) };
        assert!(!h.is_null());
        // SAFETY: first free is legitimate
        unsafe { monty_repl_free(h) };
        // SAFETY: second free on a pointer not in LIVE_REPL_HANDLES — must be no-op
        unsafe { monty_repl_free(h) };
    }

    #[test]
    fn ffi_repl_feed_run_null_handle() {
        let code = c("2 + 2");
        let mut result: *mut std::ffi::c_char = ptr::null_mut();
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: null handle — must return Error
        let tag = unsafe { monty_repl_feed_run(ptr::null_mut(), code, &mut result, &mut err) };
        assert_eq!(tag, MontyResultTag::Error);
        assert!(!err.is_null());
        // SAFETY: free
        unsafe {
            monty_string_free(err);
            free_c(code);
        }
    }

    #[test]
    fn ffi_repl_feed_run_null_code() {
        let mut repl_err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: null script_name is fine
        let h = unsafe { monty_repl_create(ptr::null(), &mut repl_err) };
        assert!(!h.is_null());

        let mut result: *mut std::ffi::c_char = ptr::null_mut();
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: null code — should return Error
        let tag = unsafe { monty_repl_feed_run(h, ptr::null(), &mut result, &mut err) };
        assert_eq!(tag, MontyResultTag::Error);
        assert!(!err.is_null());

        // SAFETY: free
        unsafe {
            monty_string_free(err);
            monty_repl_free(h);
        }
    }

    #[test]
    fn ffi_repl_feed_run_success() {
        let mut repl_err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: null script_name is fine
        let h = unsafe { monty_repl_create(ptr::null(), &mut repl_err) };
        assert!(!h.is_null());

        let code = c("2 + 2");
        let mut result: *mut std::ffi::c_char = ptr::null_mut();
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: h and code are valid
        let tag = unsafe { monty_repl_feed_run(h, code, &mut result, &mut err) };
        assert_eq!(tag, MontyResultTag::Ok);
        assert!(!result.is_null());
        assert!(err.is_null());

        // SAFETY: result is a valid JSON C string
        let result_str = unsafe { c_str(result) };
        let parsed: serde_json::Value = serde_json::from_str(result_str).unwrap();
        assert_eq!(parsed["value"], serde_json::json!(4));

        // SAFETY: free
        unsafe {
            monty_string_free(result);
            monty_repl_free(h);
            free_c(code);
        }
    }

    // -----------------------------------------------------------------------
    // monty_repl_detect_continuation
    // -----------------------------------------------------------------------

    #[test]
    fn ffi_detect_continuation_null() {
        // SAFETY: null source — must return 0 (complete) without crashing
        let result = unsafe { monty_repl_detect_continuation(ptr::null()) };
        assert_eq!(result, 0);
    }

    #[test]
    fn ffi_detect_continuation_complete() {
        let src = c("x = 1");
        // SAFETY: src is a valid C string
        let result = unsafe { monty_repl_detect_continuation(src) };
        assert_eq!(result, 0, "complete statement should return 0");
        // SAFETY: free
        unsafe { free_c(src) };
    }

    #[test]
    fn ffi_detect_continuation_incomplete_block() {
        let src = c("def f():");
        // SAFETY: src is a valid C string
        let result = unsafe { monty_repl_detect_continuation(src) };
        assert_eq!(result, 2, "incomplete block should return 2");
        // SAFETY: free
        unsafe { free_c(src) };
    }

    #[test]
    fn ffi_detect_continuation_incomplete_implicit() {
        let src = c("x = (1 +");
        // SAFETY: src is a valid C string
        let result = unsafe { monty_repl_detect_continuation(src) };
        assert_eq!(result, 1, "unclosed parens should return 1");
        // SAFETY: free
        unsafe { free_c(src) };
    }

    // -----------------------------------------------------------------------
    // REPL iterative FFI
    // -----------------------------------------------------------------------

    #[test]
    fn ffi_repl_set_ext_fns_null_handle() {
        // SAFETY: null handle — must be a no-op
        unsafe { monty_repl_set_ext_fns(ptr::null_mut(), ptr::null()) };
    }

    #[test]
    fn ffi_repl_set_ext_fns_null_fns() {
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: null script_name is fine
        let h = unsafe { monty_repl_create(ptr::null(), &mut err) };
        assert!(!h.is_null());

        // SAFETY: h is valid, null ext_fns clears the set
        unsafe { monty_repl_set_ext_fns(h, ptr::null()) };

        // SAFETY: free
        unsafe { monty_repl_free(h) };
    }

    #[test]
    fn ffi_repl_set_ext_fns_with_names() {
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: null script_name is fine
        let h = unsafe { monty_repl_create(ptr::null(), &mut err) };
        assert!(!h.is_null());

        let fns = c("fn_a,fn_b");
        // SAFETY: h and fns are valid
        unsafe { monty_repl_set_ext_fns(h, fns) };

        // SAFETY: free
        unsafe {
            monty_repl_free(h);
            free_c(fns);
        }
    }

    #[test]
    fn ffi_repl_feed_start_null_handle() {
        let code = c("2 + 2");
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: null handle
        let tag = unsafe { monty_repl_feed_start(ptr::null_mut(), code, &mut err) };
        assert_eq!(tag, MontyProgressTag::Error);
        // SAFETY: free
        unsafe {
            monty_string_free(err);
            free_c(code);
        }
    }

    #[test]
    fn ffi_repl_feed_start_null_code() {
        let mut create_err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: null script_name is fine
        let h = unsafe { monty_repl_create(ptr::null(), &mut create_err) };
        assert!(!h.is_null());

        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: null code — should return Error
        let tag = unsafe { monty_repl_feed_start(h, ptr::null(), &mut err) };
        assert_eq!(tag, MontyProgressTag::Error);

        // SAFETY: free
        unsafe {
            monty_string_free(err);
            monty_repl_free(h);
        }
    }

    #[test]
    fn ffi_repl_feed_start_and_resume_cycle() {
        let mut create_err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: null script_name is fine
        let h = unsafe { monty_repl_create(ptr::null(), &mut create_err) };
        assert!(!h.is_null());

        let fns = c("get_val");
        // SAFETY: h and fns are valid
        unsafe { monty_repl_set_ext_fns(h, fns) };

        let code = c("result = get_val()\nresult");
        let mut start_err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: h and code are valid
        let tag = unsafe { monty_repl_feed_start(h, code, &mut start_err) };
        assert_eq!(tag, MontyProgressTag::Pending);
        assert!(start_err.is_null());

        // Read pending fn name
        // SAFETY: h is in Paused state
        let fn_name_ptr = unsafe { monty_repl_pending_fn_name(h) };
        assert!(!fn_name_ptr.is_null());
        let fn_name = unsafe { c_str(fn_name_ptr) };
        assert_eq!(fn_name, "get_val");
        // SAFETY: fn_name_ptr was allocated by to_c_string
        unsafe { monty_string_free(fn_name_ptr) };

        let val = c("77");
        let mut resume_err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: h is in Paused state, val is valid JSON
        let tag = unsafe { monty_repl_resume(h, val, &mut resume_err) };
        assert_eq!(tag, MontyProgressTag::Complete);

        // SAFETY: h is in Complete state
        let result_ptr = unsafe { monty_repl_complete_result_json(h) };
        assert!(!result_ptr.is_null());
        let result_str = unsafe { c_str(result_ptr) };
        let parsed: serde_json::Value = serde_json::from_str(result_str).unwrap();
        assert_eq!(parsed["value"], serde_json::json!(77));
        // SAFETY: result_ptr was allocated by to_c_string
        unsafe { monty_string_free(result_ptr) };

        // SAFETY: free
        unsafe {
            monty_repl_free(h);
            free_c(code);
            free_c(fns);
            free_c(val);
        }
    }

    #[test]
    fn ffi_repl_resume_null_handle() {
        let val = c("42");
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: null handle
        let tag = unsafe { monty_repl_resume(ptr::null_mut(), val, &mut err) };
        assert_eq!(tag, MontyProgressTag::Error);
        // SAFETY: free
        unsafe {
            monty_string_free(err);
            free_c(val);
        }
    }

    #[test]
    fn ffi_repl_resume_null_value_json() {
        let mut create_err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: null script_name is fine
        let h = unsafe { monty_repl_create(ptr::null(), &mut create_err) };
        assert!(!h.is_null());

        let fns = c("fn1");
        // SAFETY: h and fns are valid
        unsafe { monty_repl_set_ext_fns(h, fns) };

        let code = c("fn1()");
        let mut start_err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: h and code are valid
        unsafe { monty_repl_feed_start(h, code, &mut start_err) };
        // SAFETY: start_err may be null on success
        unsafe { monty_string_free(start_err) };

        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: null value_json — should return Error
        let tag = unsafe { monty_repl_resume(h, ptr::null(), &mut err) };
        assert_eq!(tag, MontyProgressTag::Error);
        assert!(!err.is_null());

        // SAFETY: free
        unsafe {
            monty_string_free(err);
            monty_repl_free(h);
            free_c(code);
            free_c(fns);
        }
    }

    #[test]
    fn ffi_repl_resume_with_error_null_handle() {
        let msg = c("boom");
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: null handle
        let tag = unsafe { monty_repl_resume_with_error(ptr::null_mut(), msg, &mut err) };
        assert_eq!(tag, MontyProgressTag::Error);
        // SAFETY: free
        unsafe {
            monty_string_free(err);
            free_c(msg);
        }
    }

    #[test]
    fn ffi_repl_resume_with_error_null_message() {
        let mut create_err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: null script_name is fine
        let h = unsafe { monty_repl_create(ptr::null(), &mut create_err) };
        assert!(!h.is_null());

        let fns = c("fn1");
        // SAFETY: h and fns are valid
        unsafe { monty_repl_set_ext_fns(h, fns) };

        let code = c("fn1()");
        let mut start_err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: h and code are valid
        unsafe { monty_repl_feed_start(h, code, &mut start_err) };
        unsafe { monty_string_free(start_err) };

        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: null error_message — should return Error
        let tag = unsafe { monty_repl_resume_with_error(h, ptr::null(), &mut err) };
        assert_eq!(tag, MontyProgressTag::Error);

        // SAFETY: free
        unsafe {
            monty_string_free(err);
            monty_repl_free(h);
            free_c(code);
            free_c(fns);
        }
    }

    // -----------------------------------------------------------------------
    // REPL accessor FFI — null handle returns NULL / MAX / -1
    // -----------------------------------------------------------------------

    #[test]
    fn ffi_repl_accessors_null_handle() {
        // SAFETY: all null-handle accessors must return sentinel values
        let fn_name = unsafe { monty_repl_pending_fn_name(ptr::null()) };
        assert!(fn_name.is_null());

        let args = unsafe { monty_repl_pending_fn_args_json(ptr::null()) };
        assert!(args.is_null());

        let kwargs = unsafe { monty_repl_pending_fn_kwargs_json(ptr::null()) };
        assert!(kwargs.is_null());

        let call_id = unsafe { monty_repl_pending_call_id(ptr::null()) };
        assert_eq!(call_id, u32::MAX);

        let method = unsafe { monty_repl_pending_method_call(ptr::null()) };
        assert_eq!(method, -1);

        let os_name = unsafe { monty_repl_os_call_fn_name(ptr::null()) };
        assert!(os_name.is_null());

        let os_args = unsafe { monty_repl_os_call_args_json(ptr::null()) };
        assert!(os_args.is_null());

        let os_kwargs = unsafe { monty_repl_os_call_kwargs_json(ptr::null()) };
        assert!(os_kwargs.is_null());

        let os_id = unsafe { monty_repl_os_call_id(ptr::null()) };
        assert_eq!(os_id, u32::MAX);

        let result = unsafe { monty_repl_complete_result_json(ptr::null()) };
        assert!(result.is_null());

        let is_err = unsafe { monty_repl_complete_is_error(ptr::null()) };
        assert_eq!(is_err, -1);

        let future_ids = unsafe { monty_repl_pending_future_call_ids(ptr::null()) };
        assert!(future_ids.is_null());
    }

    // -----------------------------------------------------------------------
    // monty_repl_resume_as_future / monty_repl_resume_futures
    // -----------------------------------------------------------------------

    #[test]
    fn ffi_repl_resume_as_future_null_handle() {
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: null handle
        let tag = unsafe { monty_repl_resume_as_future(ptr::null_mut(), &mut err) };
        assert_eq!(tag, MontyProgressTag::Error);
        // SAFETY: free
        unsafe { monty_string_free(err) };
    }

    #[test]
    fn ffi_repl_resume_futures_null_handle() {
        let results = c("{}");
        let errors = c("{}");
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: null handle
        let tag = unsafe { monty_repl_resume_futures(ptr::null_mut(), results, errors, &mut err) };
        assert_eq!(tag, MontyProgressTag::Error);
        // SAFETY: free
        unsafe {
            monty_string_free(err);
            free_c(results);
            free_c(errors);
        }
    }

    #[test]
    fn ffi_repl_resume_futures_null_results_json() {
        let mut create_err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: null script_name is fine
        let h = unsafe { monty_repl_create(ptr::null(), &mut create_err) };
        assert!(!h.is_null());

        let errors = c("{}");
        let mut err: *mut std::ffi::c_char = ptr::null_mut();
        // SAFETY: null results_json — should return Error
        let tag = unsafe { monty_repl_resume_futures(h, ptr::null(), errors, &mut err) };
        assert_eq!(tag, MontyProgressTag::Error);

        // SAFETY: free
        unsafe {
            monty_string_free(err);
            monty_repl_free(h);
            free_c(errors);
        }
    }

    // -----------------------------------------------------------------------
    // monty_string_free / monty_bytes_free
    // -----------------------------------------------------------------------

    #[test]
    fn ffi_string_free_null() {
        // SAFETY: null pointer — must be a no-op
        unsafe { monty_string_free(ptr::null_mut()) };
    }

    #[test]
    fn ffi_string_free_valid() {
        // to_c_string allocates via CString::into_raw
        let ptr = to_c_string("hello ffi");
        assert!(!ptr.is_null());
        // SAFETY: ptr was allocated by to_c_string (CString::into_raw)
        unsafe { monty_string_free(ptr) };
    }

    #[test]
    fn ffi_bytes_free_null() {
        // SAFETY: null pointer — must be a no-op
        unsafe { monty_bytes_free(ptr::null_mut(), 0) };
    }

    #[test]
    fn ffi_bytes_free_zero_len() {
        // SAFETY: non-null pointer but zero len — must be a no-op
        let mut buf = [0u8; 4];
        unsafe { monty_bytes_free(buf.as_mut_ptr(), 0) };
    }

    #[test]
    fn ffi_bytes_free_valid() {
        // Allocate via monty_alloc, free via monty_bytes_free
        let size = 64usize;
        let ptr = monty_alloc(size);
        assert!(!ptr.is_null());
        // SAFETY: ptr was allocated by monty_alloc with size bytes
        unsafe { monty_bytes_free(ptr, size) };
    }

    // -----------------------------------------------------------------------
    // monty_alloc / monty_dealloc
    // -----------------------------------------------------------------------

    #[test]
    fn ffi_alloc_zero_returns_null() {
        let ptr = monty_alloc(0);
        assert!(ptr.is_null());
    }

    #[test]
    fn ffi_alloc_and_dealloc() {
        let size = 128usize;
        let ptr = monty_alloc(size);
        assert!(!ptr.is_null());
        // Allocated memory should be zero-initialised
        // SAFETY: ptr points to `size` bytes of zeroed memory
        let slice = unsafe { std::slice::from_raw_parts(ptr, size) };
        assert!(
            slice.iter().all(|&b| b == 0),
            "alloc'd memory should be zero"
        );
        // SAFETY: ptr was allocated by monty_alloc with size and align=1
        unsafe { monty_dealloc(ptr, size) };
    }

    #[test]
    fn ffi_dealloc_null() {
        // SAFETY: null pointer — must be a no-op
        unsafe { monty_dealloc(ptr::null_mut(), 64) };
    }

    #[test]
    fn ffi_dealloc_zero_size() {
        let size = 64usize;
        let ptr = monty_alloc(size);
        assert!(!ptr.is_null());
        // SAFETY: zero size — must be a no-op (ptr stays live)
        unsafe { monty_dealloc(ptr, 0) };
        // Now properly free to avoid leak
        unsafe { monty_dealloc(ptr, size) };
    }
}
