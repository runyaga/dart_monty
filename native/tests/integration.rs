use std::ffi::{CStr, CString, c_char};
use std::ptr;

use dart_monty_native::*;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn c(s: &str) -> CString {
    CString::new(s).unwrap()
}

unsafe fn read_c_string(ptr: *mut c_char) -> String {
    assert!(!ptr.is_null(), "unexpected NULL string");
    let s = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_string();
    unsafe { monty_string_free(ptr) };
    s
}

// ---------------------------------------------------------------------------
// 1. Smoke: create -> run -> verify JSON -> free
// ---------------------------------------------------------------------------

#[test]
fn smoke_create_run_free() {
    let code = c("2 + 2");
    let mut result_json: *mut c_char = ptr::null_mut();
    let mut error_msg: *mut c_char = ptr::null_mut();
    let mut create_error: *mut c_char = ptr::null_mut();

    let handle = unsafe { monty_create(code.as_ptr(), ptr::null(), &mut create_error) };
    assert!(!handle.is_null(), "monty_create returned NULL");

    let tag = unsafe { monty_run(handle, &mut result_json, &mut error_msg) };
    assert_eq!(tag, MontyResultTag::Ok);
    assert!(!result_json.is_null());

    let json_str = unsafe { read_c_string(result_json) };
    let parsed: serde_json::Value = serde_json::from_str(&json_str).unwrap();
    assert_eq!(parsed["value"], 4);
    assert!(parsed["usage"].is_object());
    assert!(parsed.get("error").is_none());

    if !error_msg.is_null() {
        unsafe { monty_string_free(error_msg) };
    }
    unsafe { monty_free(handle) };
}

// ---------------------------------------------------------------------------
// 2. Iterative: create with ext fn -> start -> PENDING -> read fn/args -> resume -> COMPLETE
// ---------------------------------------------------------------------------

#[test]
fn iterative_execution() {
    let code = c("result = ext_fn(42)\nresult + 1");
    let ext_fns = c("ext_fn");
    let mut out_error: *mut c_char = ptr::null_mut();

    let handle = unsafe { monty_create(code.as_ptr(), ext_fns.as_ptr(), &mut out_error) };
    assert!(!handle.is_null());

    let tag = unsafe { monty_start(handle, &mut out_error) };
    assert_eq!(tag, MontyProgressTag::Pending);

    // Read function name
    let fn_name_ptr = unsafe { monty_pending_fn_name(handle) };
    let fn_name = unsafe { read_c_string(fn_name_ptr) };
    assert_eq!(fn_name, "ext_fn");

    // Read arguments
    let args_ptr = unsafe { monty_pending_fn_args_json(handle) };
    let args_str = unsafe { read_c_string(args_ptr) };
    let args: serde_json::Value = serde_json::from_str(&args_str).unwrap();
    assert_eq!(args, serde_json::json!([42]));

    // Resume with 100
    let value = c("100");
    let tag = unsafe { monty_resume(handle, value.as_ptr(), &mut out_error) };
    assert_eq!(tag, MontyProgressTag::Complete);

    // Check result
    let result_ptr = unsafe { monty_complete_result_json(handle) };
    let result_str = unsafe { read_c_string(result_ptr) };
    let result: serde_json::Value = serde_json::from_str(&result_str).unwrap();
    assert_eq!(result["value"], 101);

    assert_eq!(unsafe { monty_complete_is_error(handle) }, 0);

    unsafe { monty_free(handle) };
}

// ---------------------------------------------------------------------------
// 3. Resume with error: start -> resume_with_error -> verify
// ---------------------------------------------------------------------------

#[test]
fn resume_with_error_propagation() {
    let code =
        c("try:\n    result = ext_fn(1)\nexcept RuntimeError as e:\n    result = str(e)\nresult");
    let ext_fns = c("ext_fn");
    let mut out_error: *mut c_char = ptr::null_mut();

    let handle = unsafe { monty_create(code.as_ptr(), ext_fns.as_ptr(), &mut out_error) };
    assert!(!handle.is_null());

    let tag = unsafe { monty_start(handle, &mut out_error) };
    assert_eq!(tag, MontyProgressTag::Pending);

    let err_msg = c("something went wrong");
    let tag = unsafe { monty_resume_with_error(handle, err_msg.as_ptr(), &mut out_error) };
    assert_eq!(tag, MontyProgressTag::Complete);
    assert_eq!(unsafe { monty_complete_is_error(handle) }, 0);

    let result_ptr = unsafe { monty_complete_result_json(handle) };
    let result_str = unsafe { read_c_string(result_ptr) };
    assert!(result_str.contains("something went wrong"));

    unsafe { monty_free(handle) };
}

// ---------------------------------------------------------------------------
// 4. Snapshot round-trip: create -> snapshot -> free -> restore -> run
// ---------------------------------------------------------------------------

#[test]
fn snapshot_round_trip() {
    let code = c("2 + 2");
    let mut create_error: *mut c_char = ptr::null_mut();

    let handle = unsafe { monty_create(code.as_ptr(), ptr::null(), &mut create_error) };
    assert!(!handle.is_null());

    // Snapshot
    let mut snap_len: usize = 0;
    let snap_ptr = unsafe { monty_snapshot(handle, &mut snap_len) };
    assert!(!snap_ptr.is_null());
    assert!(snap_len > 0);

    // Free original
    unsafe { monty_free(handle) };

    // Restore
    let mut restore_error: *mut c_char = ptr::null_mut();
    let restored = unsafe { monty_restore(snap_ptr, snap_len, &mut restore_error) };
    assert!(!restored.is_null());

    // Free snapshot bytes
    unsafe { monty_bytes_free(snap_ptr, snap_len) };

    // Run restored
    let mut result_json: *mut c_char = ptr::null_mut();
    let mut error_msg: *mut c_char = ptr::null_mut();
    let tag = unsafe { monty_run(restored, &mut result_json, &mut error_msg) };
    assert_eq!(tag, MontyResultTag::Ok);

    let json_str = unsafe { read_c_string(result_json) };
    let parsed: serde_json::Value = serde_json::from_str(&json_str).unwrap();
    assert_eq!(parsed["value"], 4);

    if !error_msg.is_null() {
        unsafe { monty_string_free(error_msg) };
    }
    unsafe { monty_free(restored) };
}

// ---------------------------------------------------------------------------
// 5. Panic safety: NULL pointers to every function -> no crash
// ---------------------------------------------------------------------------

#[test]
fn null_safety() {
    let mut out: *mut c_char = ptr::null_mut();

    // monty_create with NULL code
    let h = unsafe { monty_create(ptr::null(), ptr::null(), &mut out) };
    assert!(h.is_null());
    if !out.is_null() {
        unsafe { monty_string_free(out) };
    }

    // monty_free with NULL
    unsafe { monty_free(ptr::null_mut()) };

    // monty_run with NULL handle
    let mut result: *mut c_char = ptr::null_mut();
    let mut err: *mut c_char = ptr::null_mut();
    let tag = unsafe { monty_run(ptr::null_mut(), &mut result, &mut err) };
    assert_eq!(tag, MontyResultTag::Error);
    if !err.is_null() {
        unsafe { monty_string_free(err) };
    }

    // monty_start with NULL handle
    let mut err2: *mut c_char = ptr::null_mut();
    let tag = unsafe { monty_start(ptr::null_mut(), &mut err2) };
    assert_eq!(tag, MontyProgressTag::Error);
    if !err2.is_null() {
        unsafe { monty_string_free(err2) };
    }

    // monty_resume with NULL handle
    let mut err3: *mut c_char = ptr::null_mut();
    let v = CString::new("42").unwrap();
    let tag = unsafe { monty_resume(ptr::null_mut(), v.as_ptr(), &mut err3) };
    assert_eq!(tag, MontyProgressTag::Error);
    if !err3.is_null() {
        unsafe { monty_string_free(err3) };
    }

    // monty_resume with NULL value_json
    let code = CString::new("2+2").unwrap();
    let mut ce: *mut c_char = ptr::null_mut();
    let h = unsafe { monty_create(code.as_ptr(), ptr::null(), &mut ce) };
    if !h.is_null() {
        let mut err4: *mut c_char = ptr::null_mut();
        let tag = unsafe { monty_resume(h, ptr::null(), &mut err4) };
        assert_eq!(tag, MontyProgressTag::Error);
        if !err4.is_null() {
            unsafe { monty_string_free(err4) };
        }
        unsafe { monty_free(h) };
    }

    // monty_resume_with_error with NULL handle
    let mut err5: *mut c_char = ptr::null_mut();
    let msg = CString::new("err").unwrap();
    let tag = unsafe { monty_resume_with_error(ptr::null_mut(), msg.as_ptr(), &mut err5) };
    assert_eq!(tag, MontyProgressTag::Error);
    if !err5.is_null() {
        unsafe { monty_string_free(err5) };
    }

    // monty_pending_fn_name with NULL
    let p = unsafe { monty_pending_fn_name(ptr::null()) };
    assert!(p.is_null());

    // monty_pending_fn_args_json with NULL
    let p = unsafe { monty_pending_fn_args_json(ptr::null()) };
    assert!(p.is_null());

    // monty_complete_result_json with NULL
    let p = unsafe { monty_complete_result_json(ptr::null()) };
    assert!(p.is_null());

    // monty_complete_is_error with NULL
    assert_eq!(unsafe { monty_complete_is_error(ptr::null()) }, -1);

    // monty_snapshot with NULL
    let mut len: usize = 0;
    let p = unsafe { monty_snapshot(ptr::null(), &mut len) };
    assert!(p.is_null());

    // monty_snapshot with NULL out_len
    let code2 = CString::new("1+1").unwrap();
    let mut ce2: *mut c_char = ptr::null_mut();
    let h2 = unsafe { monty_create(code2.as_ptr(), ptr::null(), &mut ce2) };
    if !h2.is_null() {
        let p = unsafe { monty_snapshot(h2, ptr::null_mut()) };
        assert!(p.is_null());
        unsafe { monty_free(h2) };
    }

    // monty_restore with NULL data
    let mut re: *mut c_char = ptr::null_mut();
    let h3 = unsafe { monty_restore(ptr::null(), 0, &mut re) };
    assert!(h3.is_null());
    if !re.is_null() {
        unsafe { monty_string_free(re) };
    }

    // monty_set_* with NULL handle
    unsafe { monty_set_memory_limit(ptr::null_mut(), 1024) };
    unsafe { monty_set_time_limit_ms(ptr::null_mut(), 1000) };
    unsafe { monty_set_stack_limit(ptr::null_mut(), 100) };

    // monty_string_free with NULL
    unsafe { monty_string_free(ptr::null_mut()) };

    // monty_bytes_free with NULL
    unsafe { monty_bytes_free(ptr::null_mut(), 0) };
}

// ---------------------------------------------------------------------------
// 6. Invalid code: syntax error -> verify error result
// ---------------------------------------------------------------------------

#[test]
fn invalid_code_syntax_error() {
    let code = c("def");
    let mut create_error: *mut c_char = ptr::null_mut();

    let handle = unsafe { monty_create(code.as_ptr(), ptr::null(), &mut create_error) };
    assert!(handle.is_null(), "expected NULL handle for syntax error");
    assert!(!create_error.is_null());

    let err = unsafe { read_c_string(create_error) };
    assert!(!err.is_empty());
}

// ---------------------------------------------------------------------------
// 7. Resource limits: memory limit + allocating code -> error
// ---------------------------------------------------------------------------

#[test]
fn memory_limit_exceeded() {
    // Create a large list to exceed a small memory limit
    let code = c("x = [0] * 100000\nlen(x)");
    let mut create_error: *mut c_char = ptr::null_mut();

    let handle = unsafe { monty_create(code.as_ptr(), ptr::null(), &mut create_error) };
    assert!(!handle.is_null());

    // Set very small memory limit
    unsafe { monty_set_memory_limit(handle, 1024) };

    let mut result_json: *mut c_char = ptr::null_mut();
    let mut error_msg: *mut c_char = ptr::null_mut();
    let tag = unsafe { monty_run(handle, &mut result_json, &mut error_msg) };
    assert_eq!(tag, MontyResultTag::Error);

    if !result_json.is_null() {
        unsafe { monty_string_free(result_json) };
    }
    if !error_msg.is_null() {
        unsafe { monty_string_free(error_msg) };
    }
    unsafe { monty_free(handle) };
}

// ---------------------------------------------------------------------------
// 8. Time limit: short timeout + long computation -> timeout error
// ---------------------------------------------------------------------------

#[test]
fn time_limit_exceeded() {
    let code = c("i = 0\nwhile True:\n    i += 1\ni");
    let mut create_error: *mut c_char = ptr::null_mut();

    let handle = unsafe { monty_create(code.as_ptr(), ptr::null(), &mut create_error) };
    assert!(!handle.is_null());

    // Set very short time limit (1 ms)
    unsafe { monty_set_time_limit_ms(handle, 1) };

    let mut result_json: *mut c_char = ptr::null_mut();
    let mut error_msg: *mut c_char = ptr::null_mut();
    let tag = unsafe { monty_run(handle, &mut result_json, &mut error_msg) };
    assert_eq!(tag, MontyResultTag::Error);

    if !result_json.is_null() {
        unsafe { monty_string_free(result_json) };
    }
    if !error_msg.is_null() {
        unsafe { monty_string_free(error_msg) };
    }
    unsafe { monty_free(handle) };
}
