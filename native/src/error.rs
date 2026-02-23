use std::ffi::{CString, c_char};
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
    }

    #[test]
    fn test_catch_ffi_panic_non_string_payload() {
        // Panic with a non-string payload (Box<i32>) → "unknown panic" branch
        let result = catch_ffi_panic(|| {
            std::panic::resume_unwind(Box::new(42i32));
        });
        assert_eq!(result, Err("unknown panic".to_string()));
    }
}
