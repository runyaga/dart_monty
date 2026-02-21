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
pub fn monty_exception_to_json(e: &MontyException) -> Value {
    let mut obj = json!({
        "message": e.summary(),
    });
    let map = obj.as_object_mut().unwrap();

    let traceback = e.traceback();
    if let Some(frame) = traceback.last() {
        map.insert("filename".into(), json!(frame.filename));
        map.insert("line_number".into(), json!(frame.start.line));
        map.insert("column_number".into(), json!(frame.start.column));
        if let Some(ref preview) = frame.preview_line {
            map.insert("source_code".into(), json!(preview));
        }
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
}
