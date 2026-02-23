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

    let handle =
        unsafe { monty_create(code.as_ptr(), ptr::null(), ptr::null(), &mut create_error) };
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

    let handle =
        unsafe { monty_create(code.as_ptr(), ext_fns.as_ptr(), ptr::null(), &mut out_error) };
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

    let handle =
        unsafe { monty_create(code.as_ptr(), ext_fns.as_ptr(), ptr::null(), &mut out_error) };
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

    let handle =
        unsafe { monty_create(code.as_ptr(), ptr::null(), ptr::null(), &mut create_error) };
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
    let h = unsafe { monty_create(ptr::null(), ptr::null(), ptr::null(), &mut out) };
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
    let h = unsafe { monty_create(code.as_ptr(), ptr::null(), ptr::null(), &mut ce) };
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
    let h2 = unsafe { monty_create(code2.as_ptr(), ptr::null(), ptr::null(), &mut ce2) };
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

    let handle =
        unsafe { monty_create(code.as_ptr(), ptr::null(), ptr::null(), &mut create_error) };
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

    let handle =
        unsafe { monty_create(code.as_ptr(), ptr::null(), ptr::null(), &mut create_error) };
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

    let handle =
        unsafe { monty_create(code.as_ptr(), ptr::null(), ptr::null(), &mut create_error) };
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

// ---------------------------------------------------------------------------
// 9. monty_run with NULL output params — covers the is_null guard branches
// ---------------------------------------------------------------------------

#[test]
fn run_with_null_output_params() {
    let code = c("2 + 2");
    let mut create_error: *mut c_char = ptr::null_mut();

    let handle =
        unsafe { monty_create(code.as_ptr(), ptr::null(), ptr::null(), &mut create_error) };
    assert!(!handle.is_null());

    // Pass NULL for both result_json and error_msg
    let tag = unsafe { monty_run(handle, ptr::null_mut(), ptr::null_mut()) };
    assert_eq!(tag, MontyResultTag::Ok);

    unsafe { monty_free(handle) };
}

// ---------------------------------------------------------------------------
// 10. monty_start on simple code → COMPLETE via FFI
// ---------------------------------------------------------------------------

#[test]
fn start_complete_via_ffi() {
    let code = c("3 + 7");
    let mut create_error: *mut c_char = ptr::null_mut();

    let handle =
        unsafe { monty_create(code.as_ptr(), ptr::null(), ptr::null(), &mut create_error) };
    assert!(!handle.is_null());

    let mut out_error: *mut c_char = ptr::null_mut();
    let tag = unsafe { monty_start(handle, &mut out_error) };
    assert_eq!(tag, MontyProgressTag::Complete);

    let result_ptr = unsafe { monty_complete_result_json(handle) };
    assert!(!result_ptr.is_null());
    let result_str = unsafe { read_c_string(result_ptr) };
    let parsed: serde_json::Value = serde_json::from_str(&result_str).unwrap();
    assert_eq!(parsed["value"], 10);

    assert_eq!(unsafe { monty_complete_is_error(handle) }, 0);

    if !out_error.is_null() {
        unsafe { monty_string_free(out_error) };
    }
    unsafe { monty_free(handle) };
}

// ---------------------------------------------------------------------------
// 11. monty_start with runtime error via FFI
// ---------------------------------------------------------------------------

#[test]
fn start_error_via_ffi() {
    let code = c("1/0");
    let mut create_error: *mut c_char = ptr::null_mut();

    let handle =
        unsafe { monty_create(code.as_ptr(), ptr::null(), ptr::null(), &mut create_error) };
    assert!(!handle.is_null());

    let mut out_error: *mut c_char = ptr::null_mut();
    let tag = unsafe { monty_start(handle, &mut out_error) };
    assert_eq!(tag, MontyProgressTag::Error);
    assert!(!out_error.is_null());

    let err_str = unsafe { read_c_string(out_error) };
    assert!(!err_str.is_empty());

    assert_eq!(unsafe { monty_complete_is_error(handle) }, 1);

    unsafe { monty_free(handle) };
}

// ---------------------------------------------------------------------------
// 12. monty_resume_with_error with NULL error_message
// ---------------------------------------------------------------------------

#[test]
fn resume_with_error_null_message() {
    let code = c("result = ext_fn(1)\nresult");
    let ext_fns = c("ext_fn");
    let mut out_error: *mut c_char = ptr::null_mut();

    let handle =
        unsafe { monty_create(code.as_ptr(), ext_fns.as_ptr(), ptr::null(), &mut out_error) };
    assert!(!handle.is_null());

    let tag = unsafe { monty_start(handle, &mut out_error) };
    assert_eq!(tag, MontyProgressTag::Pending);

    // Pass NULL error_message
    let mut err2: *mut c_char = ptr::null_mut();
    let tag = unsafe { monty_resume_with_error(handle, ptr::null(), &mut err2) };
    assert_eq!(tag, MontyProgressTag::Error);

    if !err2.is_null() {
        unsafe { monty_string_free(err2) };
    }
    unsafe { monty_free(handle) };
}

// ---------------------------------------------------------------------------
// 13. monty_restore with garbage bytes — covers restore Err path
// ---------------------------------------------------------------------------

#[test]
fn restore_invalid_data() {
    let garbage: [u8; 16] = [0xFF; 16];
    let mut out_error: *mut c_char = ptr::null_mut();

    let handle = unsafe { monty_restore(garbage.as_ptr(), garbage.len(), &mut out_error) };
    assert!(handle.is_null());
    assert!(!out_error.is_null());

    let err_str = unsafe { read_c_string(out_error) };
    assert!(err_str.contains("restore failed"));
}

// ---------------------------------------------------------------------------
// 14. monty_snapshot after run (Complete state → Err)
// ---------------------------------------------------------------------------

#[test]
fn snapshot_wrong_state_via_ffi() {
    let code = c("2 + 2");
    let mut create_error: *mut c_char = ptr::null_mut();

    let handle =
        unsafe { monty_create(code.as_ptr(), ptr::null(), ptr::null(), &mut create_error) };
    assert!(!handle.is_null());

    // Run to completion first
    let mut result: *mut c_char = ptr::null_mut();
    let mut err: *mut c_char = ptr::null_mut();
    unsafe { monty_run(handle, &mut result, &mut err) };
    if !result.is_null() {
        unsafe { monty_string_free(result) };
    }
    if !err.is_null() {
        unsafe { monty_string_free(err) };
    }

    // Now snapshot should fail
    let mut snap_len: usize = 0;
    let snap_ptr = unsafe { monty_snapshot(handle, &mut snap_len) };
    assert!(snap_ptr.is_null());

    unsafe { monty_free(handle) };
}

// ---------------------------------------------------------------------------
// 15. type(42) via Python — covers Type conversion branch
// ---------------------------------------------------------------------------

#[test]
fn type_return_via_python() {
    let code = c("type(42)");
    let mut create_error: *mut c_char = ptr::null_mut();

    let handle =
        unsafe { monty_create(code.as_ptr(), ptr::null(), ptr::null(), &mut create_error) };
    assert!(!handle.is_null());

    let mut result_json: *mut c_char = ptr::null_mut();
    let mut error_msg: *mut c_char = ptr::null_mut();
    let tag = unsafe { monty_run(handle, &mut result_json, &mut error_msg) };
    assert_eq!(tag, MontyResultTag::Ok);

    let json_str = unsafe { read_c_string(result_json) };
    let parsed: serde_json::Value = serde_json::from_str(&json_str).unwrap();
    // Type variant returns format!("{t}") which should contain "int"
    let val = parsed["value"].as_str().unwrap();
    assert!(
        val.contains("int"),
        "expected 'int' in type string, got: {val}"
    );

    if !error_msg.is_null() {
        unsafe { monty_string_free(error_msg) };
    }
    unsafe { monty_free(handle) };
}

// ---------------------------------------------------------------------------
// 16. len via Python — covers BuiltinFunction conversion branch
// ---------------------------------------------------------------------------

#[test]
fn builtin_fn_return_via_python() {
    let code = c("len");
    let mut create_error: *mut c_char = ptr::null_mut();

    let handle =
        unsafe { monty_create(code.as_ptr(), ptr::null(), ptr::null(), &mut create_error) };
    assert!(!handle.is_null());

    let mut result_json: *mut c_char = ptr::null_mut();
    let mut error_msg: *mut c_char = ptr::null_mut();
    let tag = unsafe { monty_run(handle, &mut result_json, &mut error_msg) };
    assert_eq!(tag, MontyResultTag::Ok);

    let json_str = unsafe { read_c_string(result_json) };
    let parsed: serde_json::Value = serde_json::from_str(&json_str).unwrap();
    // BuiltinFunction variant returns format!("{f:?}")
    assert!(parsed["value"].is_string());

    if !error_msg.is_null() {
        unsafe { monty_string_free(error_msg) };
    }
    unsafe { monty_free(handle) };
}

// ---------------------------------------------------------------------------
// 17. Iterative with limits via FFI
// ---------------------------------------------------------------------------

#[test]
fn iterative_with_limits_via_ffi() {
    let code = c("result = ext_fn(5)\nresult * 3");
    let ext_fns = c("ext_fn");
    let mut create_error: *mut c_char = ptr::null_mut();

    let handle = unsafe {
        monty_create(
            code.as_ptr(),
            ext_fns.as_ptr(),
            ptr::null(),
            &mut create_error,
        )
    };
    assert!(!handle.is_null());

    // Set limits to use LimitedTracker path
    unsafe { monty_set_memory_limit(handle, 10 * 1024 * 1024) };
    unsafe { monty_set_time_limit_ms(handle, 5000) };

    let mut out_error: *mut c_char = ptr::null_mut();
    let tag = unsafe { monty_start(handle, &mut out_error) };
    assert_eq!(tag, MontyProgressTag::Pending);

    // Read function name
    let fn_name_ptr = unsafe { monty_pending_fn_name(handle) };
    let fn_name = unsafe { read_c_string(fn_name_ptr) };
    assert_eq!(fn_name, "ext_fn");

    // Resume
    let value = c("10");
    let mut resume_error: *mut c_char = ptr::null_mut();
    let tag = unsafe { monty_resume(handle, value.as_ptr(), &mut resume_error) };
    assert_eq!(tag, MontyProgressTag::Complete);

    let result_ptr = unsafe { monty_complete_result_json(handle) };
    let result_str = unsafe { read_c_string(result_ptr) };
    let result: serde_json::Value = serde_json::from_str(&result_str).unwrap();
    assert_eq!(result["value"], 30);

    if !out_error.is_null() {
        unsafe { monty_string_free(out_error) };
    }
    if !resume_error.is_null() {
        unsafe { monty_string_free(resume_error) };
    }
    unsafe { monty_free(handle) };
}

// ---------------------------------------------------------------------------
// 18. Multiple ext_fn calls via FFI (Paused→Paused transitions)
// ---------------------------------------------------------------------------

#[test]
fn multiple_ext_fn_calls_via_ffi() {
    let code = c("a = ext_fn(1)\nb = ext_fn(2)\na + b");
    let ext_fns = c("ext_fn");
    let mut create_error: *mut c_char = ptr::null_mut();

    let handle = unsafe {
        monty_create(
            code.as_ptr(),
            ext_fns.as_ptr(),
            ptr::null(),
            &mut create_error,
        )
    };
    assert!(!handle.is_null());

    let mut out_error: *mut c_char = ptr::null_mut();
    let tag = unsafe { monty_start(handle, &mut out_error) };
    assert_eq!(tag, MontyProgressTag::Pending);

    // First resume
    let v1 = c("100");
    let tag = unsafe { monty_resume(handle, v1.as_ptr(), &mut out_error) };
    assert_eq!(tag, MontyProgressTag::Pending);

    // Second resume
    let v2 = c("200");
    let tag = unsafe { monty_resume(handle, v2.as_ptr(), &mut out_error) };
    assert_eq!(tag, MontyProgressTag::Complete);

    let result_ptr = unsafe { monty_complete_result_json(handle) };
    let result_str = unsafe { read_c_string(result_ptr) };
    let result: serde_json::Value = serde_json::from_str(&result_str).unwrap();
    assert_eq!(result["value"], 300);

    if !out_error.is_null() {
        unsafe { monty_string_free(out_error) };
    }
    unsafe { monty_free(handle) };
}

// ---------------------------------------------------------------------------
// 19. Run with NULL result_json but valid error_msg (error path)
// ---------------------------------------------------------------------------

#[test]
fn run_error_with_null_result_json() {
    let code = c("1/0");
    let mut create_error: *mut c_char = ptr::null_mut();

    let handle =
        unsafe { monty_create(code.as_ptr(), ptr::null(), ptr::null(), &mut create_error) };
    assert!(!handle.is_null());

    // Pass NULL for result_json only
    let mut error_msg: *mut c_char = ptr::null_mut();
    let tag = unsafe { monty_run(handle, ptr::null_mut(), &mut error_msg) };
    assert_eq!(tag, MontyResultTag::Error);
    assert!(!error_msg.is_null());

    let err = unsafe { read_c_string(error_msg) };
    assert!(!err.is_empty());

    unsafe { monty_free(handle) };
}

// ---------------------------------------------------------------------------
// 20. monty_create with non-UTF8 ext_fns (covers Err(_) => vec![])
// ---------------------------------------------------------------------------

#[test]
fn create_with_ext_fns_empty_string() {
    let code = c("2 + 2");
    let ext_fns = c(""); // empty string → vec![]
    let mut create_error: *mut c_char = ptr::null_mut();

    let handle = unsafe {
        monty_create(
            code.as_ptr(),
            ext_fns.as_ptr(),
            ptr::null(),
            &mut create_error,
        )
    };
    assert!(!handle.is_null());

    let mut result_json: *mut c_char = ptr::null_mut();
    let mut error_msg: *mut c_char = ptr::null_mut();
    let tag = unsafe { monty_run(handle, &mut result_json, &mut error_msg) };
    assert_eq!(tag, MontyResultTag::Ok);

    if !result_json.is_null() {
        unsafe { monty_string_free(result_json) };
    }
    if !error_msg.is_null() {
        unsafe { monty_string_free(error_msg) };
    }
    unsafe { monty_free(handle) };
}

// ---------------------------------------------------------------------------
// 21. monty_start with NULL out_error (covers the out_error.is_null guard)
// ---------------------------------------------------------------------------

#[test]
fn start_with_null_out_error() {
    let code = c("2 + 2");
    let mut create_error: *mut c_char = ptr::null_mut();

    let handle =
        unsafe { monty_create(code.as_ptr(), ptr::null(), ptr::null(), &mut create_error) };
    assert!(!handle.is_null());

    // Pass NULL for out_error
    let tag = unsafe { monty_start(handle, ptr::null_mut()) };
    assert_eq!(tag, MontyProgressTag::Complete);

    unsafe { monty_free(handle) };
}

// ---------------------------------------------------------------------------
// 22. monty_restore with NULL out_error (covers the out_error.is_null guard)
// ---------------------------------------------------------------------------

#[test]
fn restore_invalid_with_null_out_error() {
    let garbage: [u8; 8] = [0xAB; 8];
    // Pass NULL for out_error
    let handle = unsafe { monty_restore(garbage.as_ptr(), garbage.len(), ptr::null_mut()) };
    assert!(handle.is_null());
}

// ---------------------------------------------------------------------------
// 23. monty_create with NULL out_error (covers the out_error.is_null guard)
// ---------------------------------------------------------------------------

#[test]
fn create_error_with_null_out_error() {
    let code = c("def"); // syntax error
    // Pass NULL for out_error
    let handle = unsafe { monty_create(code.as_ptr(), ptr::null(), ptr::null(), ptr::null_mut()) };
    assert!(handle.is_null());
}

// ---------------------------------------------------------------------------
// 24. complete accessors after run via FFI
// ---------------------------------------------------------------------------

#[test]
fn complete_accessors_after_run() {
    let code = c("42");
    let mut create_error: *mut c_char = ptr::null_mut();

    let handle =
        unsafe { monty_create(code.as_ptr(), ptr::null(), ptr::null(), &mut create_error) };
    assert!(!handle.is_null());

    let mut result: *mut c_char = ptr::null_mut();
    let mut err: *mut c_char = ptr::null_mut();
    let tag = unsafe { monty_run(handle, &mut result, &mut err) };
    assert_eq!(tag, MontyResultTag::Ok);

    // complete_result_json should work
    let cres = unsafe { monty_complete_result_json(handle) };
    assert!(!cres.is_null());
    unsafe { monty_string_free(cres) };

    // complete_is_error should return 0
    assert_eq!(unsafe { monty_complete_is_error(handle) }, 0);

    // pending accessors should return NULL/-1
    let fn_name = unsafe { monty_pending_fn_name(handle) };
    assert!(fn_name.is_null());
    let fn_args = unsafe { monty_pending_fn_args_json(handle) };
    assert!(fn_args.is_null());

    if !result.is_null() {
        unsafe { monty_string_free(result) };
    }
    if !err.is_null() {
        unsafe { monty_string_free(err) };
    }
    unsafe { monty_free(handle) };
}

// ---------------------------------------------------------------------------
// 25. Non-UTF8 code → covers lib.rs lines 41-42, 44
// ---------------------------------------------------------------------------

#[test]
fn create_with_non_utf8_code() {
    // Construct invalid UTF-8: 0xFF is never valid in UTF-8
    let bad_bytes: &[u8] = &[0xFF, 0xFE, 0x00]; // null-terminated
    let mut out_error: *mut c_char = ptr::null_mut();

    let handle = unsafe {
        monty_create(
            bad_bytes.as_ptr().cast(),
            ptr::null(),
            ptr::null(),
            &mut out_error,
        )
    };
    assert!(handle.is_null());
    assert!(!out_error.is_null());

    let err = unsafe { read_c_string(out_error) };
    assert!(err.contains("not valid UTF-8"));
}

// ---------------------------------------------------------------------------
// 26. Non-UTF8 ext_fns → covers lib.rs line 54
// ---------------------------------------------------------------------------

#[test]
fn create_with_non_utf8_ext_fns() {
    let code = c("2 + 2");
    // Invalid UTF-8 for ext_fns
    let bad_ext: &[u8] = &[0xFF, 0xFE, 0x00];
    let mut out_error: *mut c_char = ptr::null_mut();

    let handle = unsafe {
        monty_create(
            code.as_ptr(),
            bad_ext.as_ptr().cast(),
            ptr::null(),
            &mut out_error,
        )
    };
    // Should succeed (Err(_) => vec![] — just ignores bad ext_fns)
    assert!(!handle.is_null());

    unsafe { monty_free(handle) };
}

// ---------------------------------------------------------------------------
// 27. Non-UTF8 value_json in monty_resume → covers lib.rs lines 200-201, 203
// ---------------------------------------------------------------------------

#[test]
fn resume_with_non_utf8_value() {
    let code = c("result = ext_fn(1)\nresult");
    let ext_fns = c("ext_fn");
    let mut out_error: *mut c_char = ptr::null_mut();

    let handle =
        unsafe { monty_create(code.as_ptr(), ext_fns.as_ptr(), ptr::null(), &mut out_error) };
    assert!(!handle.is_null());

    let tag = unsafe { monty_start(handle, &mut out_error) };
    assert_eq!(tag, MontyProgressTag::Pending);

    // Pass invalid UTF-8 as value_json
    let bad_json: &[u8] = &[0xFF, 0xFE, 0x00];
    let mut resume_error: *mut c_char = ptr::null_mut();
    let tag = unsafe { monty_resume(handle, bad_json.as_ptr().cast(), &mut resume_error) };
    assert_eq!(tag, MontyProgressTag::Error);
    assert!(!resume_error.is_null());

    let err = unsafe { read_c_string(resume_error) };
    assert!(err.contains("not valid UTF-8"));

    unsafe { monty_free(handle) };
}

// ---------------------------------------------------------------------------
// 28. Non-UTF8 error_message in monty_resume_with_error → covers lib.rs lines 253-254, 256
// ---------------------------------------------------------------------------

#[test]
fn resume_with_error_non_utf8_message() {
    let code = c("result = ext_fn(1)\nresult");
    let ext_fns = c("ext_fn");
    let mut out_error: *mut c_char = ptr::null_mut();

    let handle =
        unsafe { monty_create(code.as_ptr(), ext_fns.as_ptr(), ptr::null(), &mut out_error) };
    assert!(!handle.is_null());

    let tag = unsafe { monty_start(handle, &mut out_error) };
    assert_eq!(tag, MontyProgressTag::Pending);

    // Pass invalid UTF-8 as error_message
    let bad_msg: &[u8] = &[0xFF, 0xFE, 0x00];
    let mut resume_error: *mut c_char = ptr::null_mut();
    let tag =
        unsafe { monty_resume_with_error(handle, bad_msg.as_ptr().cast(), &mut resume_error) };
    assert_eq!(tag, MontyProgressTag::Error);
    assert!(!resume_error.is_null());

    let err = unsafe { read_c_string(resume_error) };
    assert!(err.contains("not valid UTF-8"));

    unsafe { monty_free(handle) };
}

// ---------------------------------------------------------------------------
// 29. monty_set_stack_limit with valid handle → covers lib.rs line 426
// ---------------------------------------------------------------------------

#[test]
fn set_stack_limit_via_ffi() {
    let code = c("2 + 2");
    let mut create_error: *mut c_char = ptr::null_mut();

    let handle =
        unsafe { monty_create(code.as_ptr(), ptr::null(), ptr::null(), &mut create_error) };
    assert!(!handle.is_null());

    unsafe { monty_set_stack_limit(handle, 50) };

    let mut result_json: *mut c_char = ptr::null_mut();
    let mut error_msg: *mut c_char = ptr::null_mut();
    let tag = unsafe { monty_run(handle, &mut result_json, &mut error_msg) };
    assert_eq!(tag, MontyResultTag::Ok);

    if !result_json.is_null() {
        unsafe { monty_string_free(result_json) };
    }
    if !error_msg.is_null() {
        unsafe { monty_string_free(error_msg) };
    }
    unsafe { monty_free(handle) };
}

// ---------------------------------------------------------------------------
// 30. Start with limits + error → covers handle.rs line 135
// ---------------------------------------------------------------------------

#[test]
fn start_with_limits_error_via_ffi() {
    let code = c("1/0");
    let mut create_error: *mut c_char = ptr::null_mut();

    let handle =
        unsafe { monty_create(code.as_ptr(), ptr::null(), ptr::null(), &mut create_error) };
    assert!(!handle.is_null());

    unsafe { monty_set_memory_limit(handle, 10 * 1024 * 1024) };
    unsafe { monty_set_time_limit_ms(handle, 5000) };

    let mut out_error: *mut c_char = ptr::null_mut();
    let tag = unsafe { monty_start(handle, &mut out_error) };
    assert_eq!(tag, MontyProgressTag::Error);

    assert_eq!(unsafe { monty_complete_is_error(handle) }, 1);

    if !out_error.is_null() {
        unsafe { monty_string_free(out_error) };
    }
    unsafe { monty_free(handle) };
}

// ---------------------------------------------------------------------------
// 31. kwargs accessor via FFI
// ---------------------------------------------------------------------------

#[test]
fn pending_kwargs_via_ffi() {
    let code = c("result = ext_fn(1, key='val')\nresult");
    let ext_fns = c("ext_fn");
    let mut create_error: *mut c_char = ptr::null_mut();

    let handle = unsafe {
        monty_create(
            code.as_ptr(),
            ext_fns.as_ptr(),
            ptr::null(),
            &mut create_error,
        )
    };
    assert!(!handle.is_null());

    let mut out_error: *mut c_char = ptr::null_mut();
    let tag = unsafe { monty_start(handle, &mut out_error) };
    assert_eq!(tag, MontyProgressTag::Pending);

    // Check kwargs
    let kwargs_ptr = unsafe { monty_pending_fn_kwargs_json(handle) };
    assert!(!kwargs_ptr.is_null());
    let kwargs_str = unsafe { read_c_string(kwargs_ptr) };
    let kwargs: serde_json::Value = serde_json::from_str(&kwargs_str).unwrap();
    assert_eq!(kwargs["key"], "val");

    // Check args (positional)
    let args_ptr = unsafe { monty_pending_fn_args_json(handle) };
    let args_str = unsafe { read_c_string(args_ptr) };
    let args: serde_json::Value = serde_json::from_str(&args_str).unwrap();
    assert_eq!(args, serde_json::json!([1]));

    if !out_error.is_null() {
        unsafe { monty_string_free(out_error) };
    }
    unsafe { monty_free(handle) };
}

// ---------------------------------------------------------------------------
// 32. call_id accessor via FFI (increments across calls)
// ---------------------------------------------------------------------------

#[test]
fn pending_call_id_via_ffi() {
    let code = c("a = ext_fn(1)\nb = ext_fn(2)\na + b");
    let ext_fns = c("ext_fn");
    let mut create_error: *mut c_char = ptr::null_mut();

    let handle = unsafe {
        monty_create(
            code.as_ptr(),
            ext_fns.as_ptr(),
            ptr::null(),
            &mut create_error,
        )
    };
    assert!(!handle.is_null());

    let mut out_error: *mut c_char = ptr::null_mut();
    let tag = unsafe { monty_start(handle, &mut out_error) };
    assert_eq!(tag, MontyProgressTag::Pending);

    let id1 = unsafe { monty_pending_call_id(handle) };
    assert_ne!(id1, u32::MAX);

    // Resume first call
    let v1 = c("100");
    let tag = unsafe { monty_resume(handle, v1.as_ptr(), &mut out_error) };
    assert_eq!(tag, MontyProgressTag::Pending);

    let id2 = unsafe { monty_pending_call_id(handle) };
    assert_ne!(id2, u32::MAX);
    assert!(id2 > id1, "call_id should increment: {id1} -> {id2}");

    // Resume second call
    let v2 = c("200");
    let tag = unsafe { monty_resume(handle, v2.as_ptr(), &mut out_error) };
    assert_eq!(tag, MontyProgressTag::Complete);

    // After completion, call_id should return u32::MAX
    let id_done = unsafe { monty_pending_call_id(handle) };
    assert_eq!(id_done, u32::MAX);

    if !out_error.is_null() {
        unsafe { monty_string_free(out_error) };
    }
    unsafe { monty_free(handle) };
}

// ---------------------------------------------------------------------------
// 33. method_call accessor via FFI
// ---------------------------------------------------------------------------

#[test]
fn pending_method_call_via_ffi() {
    // A plain function call (not a method)
    let code = c("result = ext_fn(1)\nresult");
    let ext_fns = c("ext_fn");
    let mut create_error: *mut c_char = ptr::null_mut();

    let handle = unsafe {
        monty_create(
            code.as_ptr(),
            ext_fns.as_ptr(),
            ptr::null(),
            &mut create_error,
        )
    };
    assert!(!handle.is_null());

    let mut out_error: *mut c_char = ptr::null_mut();
    let tag = unsafe { monty_start(handle, &mut out_error) };
    assert_eq!(tag, MontyProgressTag::Pending);

    // Plain function call -> method_call should be 0
    let mc = unsafe { monty_pending_method_call(handle) };
    assert_eq!(mc, 0, "expected function call (0), got {mc}");

    // Resume to complete
    let v = c("42");
    let tag = unsafe { monty_resume(handle, v.as_ptr(), &mut out_error) };
    assert_eq!(tag, MontyProgressTag::Complete);

    // After completion, method_call should return -1
    let mc_done = unsafe { monty_pending_method_call(handle) };
    assert_eq!(mc_done, -1);

    if !out_error.is_null() {
        unsafe { monty_string_free(out_error) };
    }
    unsafe { monty_free(handle) };
}

// ---------------------------------------------------------------------------
// 34. kwargs empty when no kwargs passed
// ---------------------------------------------------------------------------

#[test]
fn pending_kwargs_empty_via_ffi() {
    let code = c("result = ext_fn(1, 2)\nresult");
    let ext_fns = c("ext_fn");
    let mut create_error: *mut c_char = ptr::null_mut();

    let handle = unsafe {
        monty_create(
            code.as_ptr(),
            ext_fns.as_ptr(),
            ptr::null(),
            &mut create_error,
        )
    };
    assert!(!handle.is_null());

    let mut out_error: *mut c_char = ptr::null_mut();
    let tag = unsafe { monty_start(handle, &mut out_error) };
    assert_eq!(tag, MontyProgressTag::Pending);

    let kwargs_ptr = unsafe { monty_pending_fn_kwargs_json(handle) };
    assert!(!kwargs_ptr.is_null());
    let kwargs_str = unsafe { read_c_string(kwargs_ptr) };
    assert_eq!(kwargs_str, "{}");

    if !out_error.is_null() {
        unsafe { monty_string_free(out_error) };
    }
    unsafe { monty_free(handle) };
}

// ---------------------------------------------------------------------------
// 35. script_name via monty_create
// ---------------------------------------------------------------------------

#[test]
fn script_name_via_ffi() {
    // Code with deliberate error to test that traceback includes script name
    let code = c("1/0");
    let name = c("my_script.py");
    let mut create_error: *mut c_char = ptr::null_mut();

    let handle =
        unsafe { monty_create(code.as_ptr(), ptr::null(), name.as_ptr(), &mut create_error) };
    assert!(!handle.is_null());

    let mut result_json: *mut c_char = ptr::null_mut();
    let mut error_msg: *mut c_char = ptr::null_mut();
    let tag = unsafe { monty_run(handle, &mut result_json, &mut error_msg) };
    assert_eq!(tag, MontyResultTag::Error);

    // The result JSON should contain the script name in error/traceback
    if !result_json.is_null() {
        let json_str = unsafe { read_c_string(result_json) };
        let parsed: serde_json::Value = serde_json::from_str(&json_str).unwrap();
        // Check traceback contains our script name
        if let Some(err) = parsed.get("error") {
            let err_str = serde_json::to_string(err).unwrap();
            assert!(
                err_str.contains("my_script.py"),
                "expected script name in error, got: {err_str}"
            );
        }
    }

    if !error_msg.is_null() {
        unsafe { monty_string_free(error_msg) };
    }
    unsafe { monty_free(handle) };
}

// ---------------------------------------------------------------------------
// 36. Null safety for new accessor functions
// ---------------------------------------------------------------------------

#[test]
fn null_safety_new_accessors() {
    // monty_pending_fn_kwargs_json with NULL
    let p = unsafe { monty_pending_fn_kwargs_json(ptr::null()) };
    assert!(p.is_null());

    // monty_pending_call_id with NULL
    let id = unsafe { monty_pending_call_id(ptr::null()) };
    assert_eq!(id, u32::MAX);

    // monty_pending_method_call with NULL
    let mc = unsafe { monty_pending_method_call(ptr::null()) };
    assert_eq!(mc, -1);
}

// ---------------------------------------------------------------------------
// 37. New accessors in wrong state (Ready -> should return None/sentinel)
// ---------------------------------------------------------------------------

#[test]
fn new_accessors_wrong_state_via_ffi() {
    let code = c("2 + 2");
    let mut create_error: *mut c_char = ptr::null_mut();

    let handle =
        unsafe { monty_create(code.as_ptr(), ptr::null(), ptr::null(), &mut create_error) };
    assert!(!handle.is_null());

    // Before any execution — Ready state
    let kwargs_ptr = unsafe { monty_pending_fn_kwargs_json(handle) };
    assert!(kwargs_ptr.is_null());

    let call_id = unsafe { monty_pending_call_id(handle) };
    assert_eq!(call_id, u32::MAX);

    let mc = unsafe { monty_pending_method_call(handle) };
    assert_eq!(mc, -1);

    unsafe { monty_free(handle) };
}

// ---------------------------------------------------------------------------
// 38. Error JSON includes exc_type and traceback via run
// ---------------------------------------------------------------------------

#[test]
fn error_json_exc_type_and_traceback_via_ffi() {
    let code = c("x = int('not_a_number')");
    let mut create_error: *mut c_char = ptr::null_mut();

    let handle =
        unsafe { monty_create(code.as_ptr(), ptr::null(), ptr::null(), &mut create_error) };
    assert!(!handle.is_null());

    let mut result_json: *mut c_char = ptr::null_mut();
    let mut error_msg: *mut c_char = ptr::null_mut();
    let tag = unsafe { monty_run(handle, &mut result_json, &mut error_msg) };
    assert_eq!(tag, MontyResultTag::Error);
    assert!(!result_json.is_null());

    let json_str = unsafe { read_c_string(result_json) };
    let parsed: serde_json::Value = serde_json::from_str(&json_str).unwrap();

    // error object should have exc_type
    let err = parsed.get("error").expect("expected error field");
    assert!(
        err.get("exc_type").is_some(),
        "expected exc_type in error: {err}"
    );
    let exc_type = err["exc_type"].as_str().unwrap();
    assert_eq!(exc_type, "ValueError");

    // error should have traceback array
    if let Some(tb) = err.get("traceback") {
        assert!(tb.is_array());
        let frames = tb.as_array().unwrap();
        assert!(!frames.is_empty());
        // Each frame should have start_line, start_column
        let frame = &frames[0];
        assert!(frame.get("start_line").is_some());
        assert!(frame.get("start_column").is_some());
    }

    if !error_msg.is_null() {
        unsafe { monty_string_free(error_msg) };
    }
    unsafe { monty_free(handle) };
}
