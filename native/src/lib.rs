#![allow(clippy::missing_safety_doc)]

mod convert;
mod error;
mod handle;

pub use handle::{MontyHandle, MontyProgressTag, MontyResultTag};

use std::ffi::{CStr, c_char, c_int};
use std::ptr;

use error::{catch_ffi_panic, to_c_string};

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
    if code.is_null() {
        if !out_error.is_null() {
            unsafe { *out_error = to_c_string("code is NULL") };
        }
        return ptr::null_mut();
    }

    let code_str = match unsafe { CStr::from_ptr(code) }.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => {
            if !out_error.is_null() {
                unsafe { *out_error = to_c_string("code is not valid UTF-8") };
            }
            return ptr::null_mut();
        }
    };

    let ext_fn_list = if ext_fns.is_null() {
        vec![]
    } else {
        match unsafe { CStr::from_ptr(ext_fns) }.to_str() {
            Ok("") => vec![],
            Ok(s) => s.split(',').map(|f| f.trim().to_string()).collect(),
            Err(_) => {
                if !out_error.is_null() {
                    unsafe { *out_error = to_c_string("ext_fns is not valid UTF-8") };
                }
                return ptr::null_mut();
            }
        }
    };

    let name = if script_name.is_null() {
        None
    } else {
        match unsafe { CStr::from_ptr(script_name) }.to_str() {
            Ok(s) => Some(s.to_string()),
            Err(_) => {
                if !out_error.is_null() {
                    unsafe { *out_error = to_c_string("script_name is not valid UTF-8") };
                }
                return ptr::null_mut();
            }
        }
    };

    match catch_ffi_panic(|| MontyHandle::new(code_str, ext_fn_list, name)) {
        Ok(Ok(handle)) => Box::into_raw(Box::new(handle)),
        Ok(Err(exc)) => {
            if !out_error.is_null() {
                unsafe { *out_error = to_c_string(&exc.summary()) };
            }
            ptr::null_mut()
        }
        Err(panic_msg) => {
            if !out_error.is_null() {
                unsafe { *out_error = to_c_string(&panic_msg) };
            }
            ptr::null_mut()
        }
    }
}

/// Free a `MontyHandle`. Safe to call with NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_free(handle: *mut MontyHandle) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
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
            unsafe { *error_msg = to_c_string("handle is NULL") };
        }
        return MontyResultTag::Error;
    }

    let h = unsafe { &mut *handle };

    match catch_ffi_panic(|| h.run()) {
        Ok((tag, json, err)) => {
            if !result_json.is_null() {
                unsafe { *result_json = to_c_string(&json) };
            }
            if !error_msg.is_null() {
                match err {
                    Some(ref msg) => unsafe { *error_msg = to_c_string(msg) },
                    None => unsafe { *error_msg = ptr::null_mut() },
                }
            }
            tag
        }
        Err(panic_msg) => {
            if !error_msg.is_null() {
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
    if handle.is_null() {
        if !out_error.is_null() {
            unsafe { *out_error = to_c_string("handle is NULL") };
        }
        return MontyProgressTag::Error;
    }

    let h = unsafe { &mut *handle };

    match catch_ffi_panic(|| h.start()) {
        Ok((tag, err)) => {
            if !out_error.is_null() {
                match err {
                    Some(ref msg) => unsafe { *out_error = to_c_string(msg) },
                    None => unsafe { *out_error = ptr::null_mut() },
                }
            }
            tag
        }
        Err(panic_msg) => {
            if !out_error.is_null() {
                unsafe { *out_error = to_c_string(&panic_msg) };
            }
            MontyProgressTag::Error
        }
    }
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
    if handle.is_null() {
        if !out_error.is_null() {
            unsafe { *out_error = to_c_string("handle is NULL") };
        }
        return MontyProgressTag::Error;
    }
    if value_json.is_null() {
        if !out_error.is_null() {
            unsafe { *out_error = to_c_string("value_json is NULL") };
        }
        return MontyProgressTag::Error;
    }

    let h = unsafe { &mut *handle };
    let json_str = match unsafe { CStr::from_ptr(value_json) }.to_str() {
        Ok(s) => s,
        Err(_) => {
            if !out_error.is_null() {
                unsafe { *out_error = to_c_string("value_json is not valid UTF-8") };
            }
            return MontyProgressTag::Error;
        }
    };

    match catch_ffi_panic(|| h.resume(json_str)) {
        Ok((tag, err)) => {
            if !out_error.is_null() {
                match err {
                    Some(ref msg) => unsafe { *out_error = to_c_string(msg) },
                    None => unsafe { *out_error = ptr::null_mut() },
                }
            }
            tag
        }
        Err(panic_msg) => {
            if !out_error.is_null() {
                unsafe { *out_error = to_c_string(&panic_msg) };
            }
            MontyProgressTag::Error
        }
    }
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
    if handle.is_null() {
        if !out_error.is_null() {
            unsafe { *out_error = to_c_string("handle is NULL") };
        }
        return MontyProgressTag::Error;
    }
    if error_message.is_null() {
        if !out_error.is_null() {
            unsafe { *out_error = to_c_string("error_message is NULL") };
        }
        return MontyProgressTag::Error;
    }

    let h = unsafe { &mut *handle };
    let msg = match unsafe { CStr::from_ptr(error_message) }.to_str() {
        Ok(s) => s,
        Err(_) => {
            if !out_error.is_null() {
                unsafe { *out_error = to_c_string("error_message is not valid UTF-8") };
            }
            return MontyProgressTag::Error;
        }
    };

    match catch_ffi_panic(|| h.resume_with_error(msg)) {
        Ok((tag, err)) => {
            if !out_error.is_null() {
                match err {
                    Some(ref msg) => unsafe { *out_error = to_c_string(msg) },
                    None => unsafe { *out_error = ptr::null_mut() },
                }
            }
            tag
        }
        Err(panic_msg) => {
            if !out_error.is_null() {
                unsafe { *out_error = to_c_string(&panic_msg) };
            }
            MontyProgressTag::Error
        }
    }
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
    if handle.is_null() {
        if !out_error.is_null() {
            unsafe { *out_error = to_c_string("handle is NULL") };
        }
        return MontyProgressTag::Error;
    }

    let h = unsafe { &mut *handle };

    match catch_ffi_panic(|| h.resume_as_future()) {
        Ok((tag, err)) => {
            if !out_error.is_null() {
                match err {
                    Some(ref msg) => unsafe { *out_error = to_c_string(msg) },
                    None => unsafe { *out_error = ptr::null_mut() },
                }
            }
            tag
        }
        Err(panic_msg) => {
            if !out_error.is_null() {
                unsafe { *out_error = to_c_string(&panic_msg) };
            }
            MontyProgressTag::Error
        }
    }
}

/// Get the pending future call IDs as a JSON array.
/// Only valid when handle is in RESOLVE_FUTURES state.
/// Caller frees with `monty_string_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_pending_future_call_ids(handle: *const MontyHandle) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
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
    if handle.is_null() {
        if !out_error.is_null() {
            unsafe { *out_error = to_c_string("handle is NULL") };
        }
        return MontyProgressTag::Error;
    }
    if results_json.is_null() {
        if !out_error.is_null() {
            unsafe { *out_error = to_c_string("results_json is NULL") };
        }
        return MontyProgressTag::Error;
    }
    if errors_json.is_null() {
        if !out_error.is_null() {
            unsafe { *out_error = to_c_string("errors_json is NULL") };
        }
        return MontyProgressTag::Error;
    }

    let h = unsafe { &mut *handle };
    let results_str = match unsafe { CStr::from_ptr(results_json) }.to_str() {
        Ok(s) => s,
        Err(_) => {
            if !out_error.is_null() {
                unsafe { *out_error = to_c_string("results_json is not valid UTF-8") };
            }
            return MontyProgressTag::Error;
        }
    };
    let errors_str = match unsafe { CStr::from_ptr(errors_json) }.to_str() {
        Ok(s) => s,
        Err(_) => {
            if !out_error.is_null() {
                unsafe { *out_error = to_c_string("errors_json is not valid UTF-8") };
            }
            return MontyProgressTag::Error;
        }
    };

    match catch_ffi_panic(|| h.resume_futures(results_str, errors_str)) {
        Ok((tag, err)) => {
            if !out_error.is_null() {
                match err {
                    Some(ref msg) => unsafe { *out_error = to_c_string(msg) },
                    None => unsafe { *out_error = ptr::null_mut() },
                }
            }
            tag
        }
        Err(panic_msg) => {
            if !out_error.is_null() {
                unsafe { *out_error = to_c_string(&panic_msg) };
            }
            MontyProgressTag::Error
        }
    }
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
    let h = unsafe { &*handle };
    match h.pending_method_call() {
        Some(true) => 1,
        Some(false) => 0,
        None => -1,
    }
}

/// Get the completed result as a JSON string.
/// Caller frees with `monty_string_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_complete_result_json(handle: *const MontyHandle) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
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
    let h = unsafe { &*handle };
    match h.snapshot() {
        Ok(bytes) => {
            let len = bytes.len();
            let boxed = bytes.into_boxed_slice();
            let ptr = Box::into_raw(boxed) as *mut u8;
            unsafe { *out_len = len };
            ptr
        }
        Err(_) => ptr::null_mut(),
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
            unsafe { *out_error = to_c_string("data is NULL") };
        }
        return ptr::null_mut();
    }

    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    match MontyHandle::restore(bytes) {
        Ok(handle) => Box::into_raw(Box::new(handle)),
        Err(msg) => {
            if !out_error.is_null() {
                unsafe { *out_error = to_c_string(&msg) };
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
        unsafe { &mut *handle }.set_memory_limit(bytes);
    }
}

/// Set the execution time limit in milliseconds.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_set_time_limit_ms(handle: *mut MontyHandle, ms: u64) {
    if !handle.is_null() {
        unsafe { &mut *handle }.set_time_limit_ms(ms);
    }
}

/// Set the stack depth limit.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_set_stack_limit(handle: *mut MontyHandle, depth: usize) {
    if !handle.is_null() {
        unsafe { &mut *handle }.set_stack_limit(depth);
    }
}

// ---------------------------------------------------------------------------
// Memory management
// ---------------------------------------------------------------------------

/// Free a C string returned by any `monty_*` function.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(unsafe { std::ffi::CString::from_raw(ptr) });
    }
}

/// Free a byte buffer returned by `monty_snapshot`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn monty_bytes_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() && len > 0 {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)) });
    }
}
