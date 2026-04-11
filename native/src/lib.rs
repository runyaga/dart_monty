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
