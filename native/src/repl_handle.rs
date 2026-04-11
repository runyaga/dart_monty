use monty::{
    LimitedTracker, MontyRepl, PrintWriter, ResourceLimits, detect_repl_continuation_mode,
};
use serde_json::Value;

use crate::convert::monty_object_to_json;
use crate::error::monty_exception_to_json;
use crate::handle::MontyResultTag;

/// The concrete tracker type used for REPL execution.
type Tracker = LimitedTracker;

/// Default resource limits for REPL snippets.
fn default_limits() -> ResourceLimits {
    let mut limits = ResourceLimits::new();
    limits.max_duration = Some(std::time::Duration::from_secs(30));
    limits.max_memory = Some(256 * 1024 * 1024); // 256 MB
    limits.max_recursion_depth = Some(1000);
    limits
}

/// Integer codes returned by `monty_repl_detect_continuation`.
///
/// Matches `ReplContinuationMode` variants for the C API.
pub const CONTINUATION_COMPLETE: i32 = 0;
pub const CONTINUATION_INCOMPLETE_IMPLICIT: i32 = 1;
pub const CONTINUATION_INCOMPLETE_BLOCK: i32 = 2;

/// Opaque handle wrapping a persistent `MontyRepl` session.
///
/// Unlike `MontyHandle` which is consumed on execution, this handle
/// survives across multiple `feed_run` calls — each snippet executes
/// against accumulated heap/global state without replaying prior code.
pub struct MontyReplHandle {
    repl: MontyRepl<Tracker>,
    print_output: String,
}

impl std::fmt::Debug for MontyReplHandle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MontyReplHandle").finish_non_exhaustive()
    }
}

impl MontyReplHandle {
    /// Creates a new REPL handle with an empty interpreter state.
    #[must_use]
    pub fn new(script_name: &str) -> Self {
        let limits = default_limits();
        let tracker = Tracker::new(limits);
        Self {
            repl: MontyRepl::new(script_name, tracker),
            print_output: String::new(),
        }
    }

    /// Feed a snippet and run to completion.
    ///
    /// The REPL persists heap, globals, and intern state across calls.
    /// Returns `(result_tag, result_json, error_msg)` using the same
    /// JSON format as `MontyHandle::run`.
    pub fn feed_run(&mut self, code: &str) -> (MontyResultTag, String, Option<String>) {
        let mut buf = String::new();
        let result = self
            .repl
            .feed_run(code, vec![], PrintWriter::Collect(&mut buf));

        self.print_output.push_str(&buf);

        match result {
            Ok(obj) => {
                let val = monty_object_to_json(&obj);
                let result_json = build_repl_result_json(&val, None, &self.print_output);
                // Reset print buffer after including in result.
                self.print_output.clear();
                (MontyResultTag::Ok, result_json, None)
            }
            Err(exc) => {
                let err_json = monty_exception_to_json(&exc);
                let result_json =
                    build_repl_result_json(&Value::Null, Some(err_json), &self.print_output);
                let msg = exc.summary();
                // Reset print buffer after including in result.
                self.print_output.clear();
                (MontyResultTag::Error, result_json, Some(msg))
            }
        }
    }

    /// Detect whether a source fragment is complete or needs more input.
    ///
    /// Returns one of the `CONTINUATION_*` constants. This is a stateless
    /// operation — no REPL handle is needed, but the method is here for
    /// convenience alongside the handle API.
    #[must_use]
    pub fn detect_continuation(source: &str) -> i32 {
        use monty::ReplContinuationMode;
        match detect_repl_continuation_mode(source) {
            ReplContinuationMode::Complete => CONTINUATION_COMPLETE,
            ReplContinuationMode::IncompleteImplicit => CONTINUATION_INCOMPLETE_IMPLICIT,
            ReplContinuationMode::IncompleteBlock => CONTINUATION_INCOMPLETE_BLOCK,
        }
    }
}

/// Build result JSON in the same format as `MontyHandle::run` results.
///
/// Uses zero-valued usage since REPL doesn't currently track per-snippet
/// resource consumption.
fn build_repl_result_json(value: &Value, error: Option<Value>, print_output: &str) -> String {
    let mut result = serde_json::json!({
        "value": value,
        "usage": {
            "memory_bytes_used": 0,
            "time_elapsed_ms": 0,
            "stack_depth_used": 0,
        },
    });
    if let Some(err) = error {
        result.as_object_mut().unwrap().insert("error".into(), err);
    }
    if !print_output.is_empty() {
        result
            .as_object_mut()
            .unwrap()
            .insert("print_output".into(), Value::String(print_output.into()));
    }
    serde_json::to_string(&result).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repl_handle_basic_state_persistence() {
        let mut repl = MontyReplHandle::new("test.py");
        let (tag, _, _) = repl.feed_run("x = 42");
        assert_eq!(tag, MontyResultTag::Ok);

        let (tag, json, _) = repl.feed_run("x + 1");
        assert_eq!(tag, MontyResultTag::Ok);
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["value"], 43);
    }

    #[test]
    fn repl_handle_function_persistence() {
        let mut repl = MontyReplHandle::new("test.py");
        repl.feed_run("def f():\n    return 99");

        let (tag, json, _) = repl.feed_run("f()");
        assert_eq!(tag, MontyResultTag::Ok);
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["value"], 99);
    }

    #[test]
    fn repl_handle_survives_error() {
        let mut repl = MontyReplHandle::new("test.py");
        let (tag, _, _) = repl.feed_run("x = 10");
        assert_eq!(tag, MontyResultTag::Ok);

        // This should raise but the REPL survives.
        let (tag, _, _) = repl.feed_run("1 / 0");
        assert_eq!(tag, MontyResultTag::Error);

        // x should still be accessible.
        let (tag, json, _) = repl.feed_run("x");
        assert_eq!(tag, MontyResultTag::Ok);
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["value"], 10);
    }

    #[test]
    fn repl_handle_print_output() {
        let mut repl = MontyReplHandle::new("test.py");
        let (tag, json, _) = repl.feed_run("print('hello')");
        assert_eq!(tag, MontyResultTag::Ok);
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["print_output"], "hello\n");
    }

    #[test]
    fn detect_continuation_complete() {
        assert_eq!(
            MontyReplHandle::detect_continuation("x = 1"),
            CONTINUATION_COMPLETE
        );
    }

    #[test]
    fn detect_continuation_incomplete_block() {
        assert_eq!(
            MontyReplHandle::detect_continuation("def f():"),
            CONTINUATION_INCOMPLETE_BLOCK,
        );
    }

    #[test]
    fn detect_continuation_incomplete_implicit() {
        assert_eq!(
            MontyReplHandle::detect_continuation("x = (1 +"),
            CONTINUATION_INCOMPLETE_IMPLICIT,
        );
    }
}
