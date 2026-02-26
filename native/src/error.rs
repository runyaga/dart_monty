use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

use monty::MontyException;
use serde_json::{Value, json};

/// Allocate a C string from a Rust `&str`. Caller must free with `monty_string_free`.
pub fn to_c_string(s: &str) -> *mut c_char {
    CString::new(s).unwrap_or_default().into_raw()
}

/// Wrap a closure in `catch_unwind`, returning `Err(message)` on panic.
pub fn catch_ffi_panic<F, T>(f: F) -> Result<T, String>
where
    F: FnOnce() -> T,
{
    catch_unwind(AssertUnwindSafe(f)).map_err(|payload| {
        if let Some(s) = payload.downcast_ref::<&str>() {
            s.to_string()
        } else if let Some(s) = payload.downcast_ref::<String>() {
            s.clone()
        } else {
            "unknown panic".to_string()
        }
    })
}

/// Parse a C string pointer, writing to `out_error` on failure.
/// Returns `Ok(&str)` or `Err(())` if null or invalid UTF-8.
///
/// # Safety
/// `ptr` must be a valid NUL-terminated C string if non-null.
pub unsafe fn parse_c_str<'a>(
    ptr: *const c_char,
    name: &str,
    out_error: *mut *mut c_char,
) -> Result<&'a str, ()> {
    if ptr.is_null() {
        if !out_error.is_null() {
            unsafe { *out_error = to_c_string(&format!("{name} is NULL")) };
        }
        return Err(());
    }
    match unsafe { CStr::from_ptr(ptr) }.to_str() {
        Ok(s) => Ok(s),
        Err(_) => {
            if !out_error.is_null() {
                unsafe { *out_error = to_c_string(&format!("{name} is not valid UTF-8")) };
            }
            Err(())
        }
    }
}

/// Convert a `MontyException` to a snake_case JSON value matching Dart's
/// `MontyException.fromJson`.
///
/// Includes `exc_type` (e.g. `"ValueError"`) and full `traceback` array
/// with all frames from the upstream exception.
pub fn monty_exception_to_json(e: &MontyException) -> Value {
    let mut obj = json!({
        "message": e.summary(),
        "exc_type": e.exc_type().to_string(),
    });
    let map = obj.as_object_mut().unwrap();

    let traceback = e.traceback();

    // Legacy single-frame fields (last frame) for backward compatibility
    if let Some(frame) = traceback.last() {
        map.insert("filename".into(), json!(frame.filename));
        map.insert("line_number".into(), json!(frame.start.line));
        map.insert("column_number".into(), json!(frame.start.column));
        if let Some(ref preview) = frame.preview_line {
            map.insert("source_code".into(), json!(preview));
        }
    }

    // Full traceback array
    if !traceback.is_empty() {
        let frames: Vec<Value> = traceback
            .iter()
            .map(|frame| {
                let mut f = json!({
                    "filename": frame.filename,
                    "start_line": frame.start.line,
                    "start_column": frame.start.column,
                    "end_line": frame.end.line,
                    "end_column": frame.end.column,
                });
                let fm = f.as_object_mut().unwrap();
                if let Some(ref name) = frame.frame_name {
                    fm.insert("frame_name".into(), json!(name));
                }
                if let Some(ref preview) = frame.preview_line {
                    fm.insert("preview_line".into(), json!(preview));
                }
                if frame.hide_caret {
                    fm.insert("hide_caret".into(), json!(true));
                }
                if frame.hide_frame_name {
                    fm.insert("hide_frame_name".into(), json!(true));
                }
                f
            })
            .collect();
        map.insert("traceback".into(), json!(frames));
    }

    obj
}

#[cfg(test)]
mod tests {
    use super::*;
    use monty::ExcType;
    use std::ffi::CStr;
    use std::ptr;

    #[test]
    fn test_to_c_string_basic() {
        let ptr = to_c_string("hello");
        assert!(!ptr.is_null());
        let cs = unsafe { CStr::from_ptr(ptr) };
        assert_eq!(cs.to_str().unwrap(), "hello");
        unsafe { drop(CString::from_raw(ptr)) };
    }

    #[test]
    fn test_to_c_string_empty() {
        let ptr = to_c_string("");
        assert!(!ptr.is_null());
        let cs = unsafe { CStr::from_ptr(ptr) };
        assert_eq!(cs.to_str().unwrap(), "");
        unsafe { drop(CString::from_raw(ptr)) };
    }

    #[test]
    fn test_to_c_string_with_interior_nul() {
        // CString::new fails on interior nul — should return empty string
        let ptr = to_c_string("hello\0world");
        assert!(!ptr.is_null());
        let cs = unsafe { CStr::from_ptr(ptr) };
        assert_eq!(cs.to_str().unwrap(), "");
        unsafe { drop(CString::from_raw(ptr)) };
    }

    #[test]
    fn test_catch_ffi_panic_success() {
        let result = catch_ffi_panic(|| 42);
        assert_eq!(result, Ok(42));
    }

    #[test]
    fn test_catch_ffi_panic_str() {
        let result = catch_ffi_panic(|| panic!("boom"));
        assert_eq!(result, Err("boom".to_string()));
    }

    #[test]
    fn test_catch_ffi_panic_string() {
        let result = catch_ffi_panic(|| panic!("{}", "formatted boom"));
        assert_eq!(result, Err("formatted boom".to_string()));
    }

    #[test]
    fn test_monty_exception_to_json_basic() {
        let exc = MontyException::new(ExcType::ValueError, Some("bad value".into()));
        let json = monty_exception_to_json(&exc);
        let obj = json.as_object().unwrap();
        assert!(obj["message"].as_str().unwrap().contains("bad value"));
        assert_eq!(obj["exc_type"].as_str().unwrap(), "ValueError");
    }

    #[test]
    fn test_monty_exception_to_json_with_traceback() {
        // Run code that produces a multi-frame traceback through monty
        use monty::{MontyRun, NoLimitTracker, PrintWriter};

        let code = "def inner():\n    1/0\n\ndef outer():\n    inner()\n\nouter()";
        let compiled = MontyRun::new(code.into(), "<test>", vec![], vec![]).unwrap();
        let mut print = PrintWriter::Disabled;
        let err = compiled
            .run(vec![], NoLimitTracker, &mut print)
            .unwrap_err();

        let json = monty_exception_to_json(&err);
        let obj = json.as_object().unwrap();

        // Should have exc_type
        assert_eq!(obj["exc_type"].as_str().unwrap(), "ZeroDivisionError");

        // Should have traceback array with multiple frames
        let tb = obj["traceback"].as_array().unwrap();
        assert!(
            tb.len() >= 3,
            "expected 3+ frames (module, outer, inner), got {}",
            tb.len()
        );

        // Each frame should have required fields
        for frame in tb {
            assert!(frame["filename"].is_string());
            assert!(frame["start_line"].is_number());
            assert!(frame["start_column"].is_number());
            assert!(frame["end_line"].is_number());
            assert!(frame["end_column"].is_number());
        }

        // Inner frames should have frame_name
        let has_frame_name = tb.iter().any(|f| f.get("frame_name").is_some());
        assert!(
            has_frame_name,
            "expected at least one frame with frame_name"
        );

        // Legacy single-frame fields should match last frame
        assert!(obj.get("filename").is_some());
        assert!(obj.get("line_number").is_some());
        assert!(obj.get("column_number").is_some());
    }

    #[test]
    fn test_catch_ffi_panic_non_string_payload() {
        // Panic with a non-string payload (Box<i32>) → "unknown panic" branch
        let result = catch_ffi_panic(|| {
            std::panic::resume_unwind(Box::new(42i32));
        });
        assert_eq!(result, Err("unknown panic".to_string()));
    }

    #[test]
    fn test_parse_c_str_valid() {
        let c = CString::new("hello").unwrap();
        let mut err: *mut c_char = ptr::null_mut();
        let result = unsafe { parse_c_str(c.as_ptr(), "arg", &mut err) };
        assert_eq!(result, Ok("hello"));
        assert!(err.is_null());
    }

    #[test]
    fn test_parse_c_str_null() {
        let mut err: *mut c_char = ptr::null_mut();
        let result = unsafe { parse_c_str(ptr::null(), "arg", &mut err) };
        assert!(result.is_err());
        assert!(!err.is_null());
        let msg = unsafe { CStr::from_ptr(err) }.to_str().unwrap();
        assert_eq!(msg, "arg is NULL");
        unsafe { drop(CString::from_raw(err)) };
    }
}
