use std::collections::HashSet;

use monty::{
    ExtFunctionResult, MontyObject, MontyRepl, NameLookupResult, NoLimitTracker, PrintWriter,
    ReplFunctionCall, ReplOsCall, ReplProgress, ReplResolveFutures, ReplStartError,
    detect_repl_continuation_mode,
};
use serde_json::Value;

use crate::convert::{json_to_monty_object, monty_object_to_json};
use crate::error::monty_exception_to_json;
use crate::handle::{MontyProgressTag, MontyResultTag};

/// The concrete tracker type used for REPL execution.
///
/// REPLs use `NoLimitTracker` by default — no time, memory, or stack
/// limits. Interactive sessions should not be bounded by default.
/// Callers can add limits later via a dedicated API if needed.
type Tracker = NoLimitTracker;

/// Integer codes returned by `monty_repl_detect_continuation`.
///
/// Matches `ReplContinuationMode` variants for the C API.
pub const CONTINUATION_COMPLETE: i32 = 0;
pub const CONTINUATION_INCOMPLETE_IMPLICIT: i32 = 1;
pub const CONTINUATION_INCOMPLETE_BLOCK: i32 = 2;

// ---------------------------------------------------------------------------
// Metadata types (duplicated from handle.rs to avoid coupling)
// ---------------------------------------------------------------------------

/// Metadata captured when paused at a `FunctionCall`.
struct PendingMeta {
    fn_name: String,
    args_json: String,
    kwargs_json: String,
    call_id: u32,
    method_call: bool,
}

/// Metadata captured when paused at an `OsCall`.
struct OsCallMeta {
    os_fn_name: String,
    args_json: String,
    kwargs_json: String,
    call_id: u32,
}

// ---------------------------------------------------------------------------
// State machine
// ---------------------------------------------------------------------------

/// Internal state of the REPL handle.
///
/// Unlike `HandleState`, the REPL handle is **reusable** — after completion
/// the `MontyRepl` is recovered so subsequent feeds can execute.
enum ReplHandleState {
    /// REPL is idle, ready for `feed_run()` or `feed_start()`.
    Idle(MontyRepl<Tracker>),
    /// Paused at an external function call.
    Paused {
        call: ReplFunctionCall<Tracker>,
        meta: PendingMeta,
    },
    /// Paused at an OS call.
    OsCall {
        call: ReplOsCall<Tracker>,
        meta: OsCallMeta,
    },
    /// Awaiting async future resolution.
    Futures {
        futures: ReplResolveFutures<Tracker>,
        call_ids_json: String,
    },
    /// Snippet completed; REPL recovered and result available.
    Complete {
        repl: MontyRepl<Tracker>,
        result_json: String,
        is_error: bool,
    },
    /// Temporary placeholder during state transitions.
    Consumed,
}

/// Opaque handle wrapping a persistent `MontyRepl` session with a
/// suspend/resume state machine.
///
/// Supports both `feed_run()` (synchronous, runs to completion) and
/// `feed_start()`/`resume()` (iterative, pauses at external function calls).
pub struct MontyReplHandle {
    state: ReplHandleState,
    ext_fn_names: HashSet<String>,
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
        Self {
            state: ReplHandleState::Idle(MontyRepl::new(script_name, NoLimitTracker)),
            ext_fn_names: HashSet::new(),
            print_output: String::new(),
        }
    }

    /// Registers external function names for `feed_start()` name resolution.
    pub fn set_ext_fns(&mut self, names: Vec<String>) {
        self.ext_fn_names = names.into_iter().collect();
    }

    // -----------------------------------------------------------------------
    // feed_run — synchronous execution (Phase 1 API, refactored for state machine)
    // -----------------------------------------------------------------------

    /// Feed a snippet and run to completion.
    ///
    /// The REPL persists heap, globals, and intern state across calls.
    /// Returns `(result_tag, result_json, error_msg)` using the same
    /// JSON format as `MontyHandle::run`.
    pub fn feed_run(&mut self, code: &str) -> (MontyResultTag, String, Option<String>) {
        let mut repl = match self.take_repl() {
            Ok(r) => r,
            Err(msg) => return (MontyResultTag::Error, String::new(), Some(msg)),
        };

        let mut buf = String::new();
        let result = repl.feed_run(code, vec![], PrintWriter::CollectString(&mut buf));

        self.print_output.push_str(&buf);

        match result {
            Ok(obj) => {
                let val = monty_object_to_json(&obj);
                let result_json = build_repl_result_json(&val, None, &self.print_output);
                self.print_output.clear();
                self.state = ReplHandleState::Idle(repl);
                (MontyResultTag::Ok, result_json, None)
            }
            Err(exc) => {
                let err_json = monty_exception_to_json(&exc);
                let result_json =
                    build_repl_result_json(&Value::Null, Some(err_json), &self.print_output);
                let msg = exc.summary();
                self.print_output.clear();
                self.state = ReplHandleState::Idle(repl);
                (MontyResultTag::Error, result_json, Some(msg))
            }
        }
    }

    // -----------------------------------------------------------------------
    // feed_start / resume — iterative execution (Phase 2)
    // -----------------------------------------------------------------------

    /// Start iterative execution of a snippet. Pauses at external function
    /// calls, OS calls, or future resolution.
    ///
    /// Returns a progress tag. Use the accessor methods to read state, then
    /// call `resume()` or `resume_with_error()` to continue.
    pub fn feed_start(&mut self, code: &str) -> (MontyProgressTag, Option<String>) {
        let repl = match self.take_repl() {
            Ok(r) => r,
            Err(msg) => return (MontyProgressTag::Error, Some(msg)),
        };

        let mut buf = String::new();
        let result = repl.feed_start(code, vec![], PrintWriter::CollectString(&mut buf));
        self.print_output.push_str(&buf);

        match result {
            Ok(progress) => self.process_repl_progress(progress),
            Err(err) => self.handle_repl_start_error(*err),
        }
    }

    /// Resume a paused execution with a JSON-encoded return value.
    pub fn resume(&mut self, value_json: &str) -> (MontyProgressTag, Option<String>) {
        let val: Value = match serde_json::from_str(value_json) {
            Ok(v) => v,
            Err(e) => return (MontyProgressTag::Error, Some(format!("invalid JSON: {e}"))),
        };
        let obj = json_to_monty_object(&val);

        let state = std::mem::replace(&mut self.state, ReplHandleState::Consumed);
        match state {
            ReplHandleState::Paused { call, .. } => {
                let mut buf = String::new();
                let result = call.resume(
                    ExtFunctionResult::Return(obj),
                    PrintWriter::CollectString(&mut buf),
                );
                self.print_output.push_str(&buf);
                match result {
                    Ok(progress) => self.process_repl_progress(progress),
                    Err(err) => self.handle_repl_start_error(*err),
                }
            }
            ReplHandleState::OsCall { call, .. } => {
                let mut buf = String::new();
                let result = call.resume(
                    ExtFunctionResult::Return(obj),
                    PrintWriter::CollectString(&mut buf),
                );
                self.print_output.push_str(&buf);
                match result {
                    Ok(progress) => self.process_repl_progress(progress),
                    Err(err) => self.handle_repl_start_error(*err),
                }
            }
            other => {
                self.state = other;
                (
                    MontyProgressTag::Error,
                    Some("handle not in Paused or OsCall state".into()),
                )
            }
        }
    }

    /// Resume a paused execution by raising an error in Python.
    pub fn resume_with_error(&mut self, error_message: &str) -> (MontyProgressTag, Option<String>) {
        let state = std::mem::replace(&mut self.state, ReplHandleState::Consumed);
        match state {
            ReplHandleState::Paused { call, .. } => {
                let mut buf = String::new();
                let result = call.resume(
                    ExtFunctionResult::Error(monty::MontyException::new(
                        monty::ExcType::RuntimeError,
                        Some(error_message.to_string()),
                    )),
                    PrintWriter::CollectString(&mut buf),
                );
                self.print_output.push_str(&buf);
                match result {
                    Ok(progress) => self.process_repl_progress(progress),
                    Err(err) => self.handle_repl_start_error(*err),
                }
            }
            ReplHandleState::OsCall { call, .. } => {
                let mut buf = String::new();
                let result = call.resume(
                    ExtFunctionResult::Error(monty::MontyException::new(
                        monty::ExcType::RuntimeError,
                        Some(error_message.to_string()),
                    )),
                    PrintWriter::CollectString(&mut buf),
                );
                self.print_output.push_str(&buf);
                match result {
                    Ok(progress) => self.process_repl_progress(progress),
                    Err(err) => self.handle_repl_start_error(*err),
                }
            }
            other => {
                self.state = other;
                (
                    MontyProgressTag::Error,
                    Some("handle not in Paused or OsCall state".into()),
                )
            }
        }
    }

    /// Resume by converting the pending call into a future.
    pub fn resume_as_future(&mut self) -> (MontyProgressTag, Option<String>) {
        let state = std::mem::replace(&mut self.state, ReplHandleState::Consumed);
        match state {
            ReplHandleState::Paused { call, .. } => {
                let mut buf = String::new();
                let result = call.resume_pending(PrintWriter::CollectString(&mut buf));
                self.print_output.push_str(&buf);
                match result {
                    Ok(progress) => self.process_repl_progress(progress),
                    Err(err) => self.handle_repl_start_error(*err),
                }
            }
            other => {
                self.state = other;
                (
                    MontyProgressTag::Error,
                    Some("handle not in Paused state".into()),
                )
            }
        }
    }

    /// Resolve pending futures with results and errors.
    pub fn resume_futures(
        &mut self,
        results_json: &str,
        errors_json: &str,
    ) -> (MontyProgressTag, Option<String>) {
        let state = std::mem::replace(&mut self.state, ReplHandleState::Consumed);
        let ReplHandleState::Futures { futures, .. } = state else {
            self.state = state;
            return (
                MontyProgressTag::Error,
                Some("handle not in Futures state".into()),
            );
        };

        // Parse results: {"call_id": value, ...}
        let results_map: serde_json::Map<String, Value> =
            serde_json::from_str(results_json).unwrap_or_default();
        let errors_map: serde_json::Map<String, Value> =
            serde_json::from_str(errors_json).unwrap_or_default();

        let mut resolved = Vec::new();
        for (id_str, val) in &results_map {
            if let Ok(id) = id_str.parse::<u32>() {
                resolved.push((id, ExtFunctionResult::Return(json_to_monty_object(val))));
            }
        }
        for (id_str, val) in &errors_map {
            if let Ok(id) = id_str.parse::<u32>() {
                let msg = val.as_str().unwrap_or("error").to_string();
                let exc = monty::MontyException::new(monty::ExcType::RuntimeError, Some(msg));
                resolved.push((id, ExtFunctionResult::Error(exc)));
            }
        }

        let mut buf = String::new();
        let result = futures.resume(resolved, PrintWriter::CollectString(&mut buf));
        self.print_output.push_str(&buf);

        match result {
            Ok(progress) => self.process_repl_progress(progress),
            Err(err) => self.handle_repl_start_error(*err),
        }
    }

    // -----------------------------------------------------------------------
    // State accessors
    // -----------------------------------------------------------------------

    /// Returns the pending function name, if in Paused state.
    pub fn pending_fn_name(&self) -> Option<&str> {
        match &self.state {
            ReplHandleState::Paused { meta, .. } => Some(&meta.fn_name),
            _ => None,
        }
    }

    /// Returns the pending function arguments as JSON, if in Paused state.
    pub fn pending_fn_args_json(&self) -> Option<&str> {
        match &self.state {
            ReplHandleState::Paused { meta, .. } => Some(&meta.args_json),
            _ => None,
        }
    }

    /// Returns the pending keyword arguments as JSON, if in Paused state.
    pub fn pending_fn_kwargs_json(&self) -> Option<&str> {
        match &self.state {
            ReplHandleState::Paused { meta, .. } => Some(&meta.kwargs_json),
            _ => None,
        }
    }

    /// Returns the pending call ID, if in Paused state.
    pub fn pending_call_id(&self) -> Option<u32> {
        match &self.state {
            ReplHandleState::Paused { meta, .. } => Some(meta.call_id),
            _ => None,
        }
    }

    /// Whether the pending call is a method call, if in Paused state.
    pub fn pending_method_call(&self) -> Option<bool> {
        match &self.state {
            ReplHandleState::Paused { meta, .. } => Some(meta.method_call),
            _ => None,
        }
    }

    /// Returns the OS call function name, if in OsCall state.
    pub fn os_call_fn_name(&self) -> Option<&str> {
        match &self.state {
            ReplHandleState::OsCall { meta, .. } => Some(&meta.os_fn_name),
            _ => None,
        }
    }

    /// Returns the OS call arguments as JSON, if in OsCall state.
    pub fn os_call_args_json(&self) -> Option<&str> {
        match &self.state {
            ReplHandleState::OsCall { meta, .. } => Some(&meta.args_json),
            _ => None,
        }
    }

    /// Returns the OS call keyword arguments as JSON, if in OsCall state.
    pub fn os_call_kwargs_json(&self) -> Option<&str> {
        match &self.state {
            ReplHandleState::OsCall { meta, .. } => Some(&meta.kwargs_json),
            _ => None,
        }
    }

    /// Returns the OS call ID, if in OsCall state.
    pub fn os_call_id(&self) -> Option<u32> {
        match &self.state {
            ReplHandleState::OsCall { meta, .. } => Some(meta.call_id),
            _ => None,
        }
    }

    /// Returns the completed result JSON, if in Complete state.
    pub fn complete_result_json(&self) -> Option<&str> {
        match &self.state {
            ReplHandleState::Complete { result_json, .. } => Some(result_json),
            _ => None,
        }
    }

    /// Whether the completed result is an error, if in Complete state.
    pub fn complete_is_error(&self) -> Option<bool> {
        match &self.state {
            ReplHandleState::Complete { is_error, .. } => Some(*is_error),
            _ => None,
        }
    }

    /// Returns the pending future call IDs as JSON, if in Futures state.
    pub fn pending_future_call_ids(&self) -> Option<&str> {
        match &self.state {
            ReplHandleState::Futures { call_ids_json, .. } => Some(call_ids_json),
            _ => None,
        }
    }

    // -----------------------------------------------------------------------
    // Stateless helpers
    // -----------------------------------------------------------------------

    /// Detect whether a source fragment is complete or needs more input.
    #[must_use]
    pub fn detect_continuation(source: &str) -> i32 {
        use monty::ReplContinuationMode;
        match detect_repl_continuation_mode(source) {
            ReplContinuationMode::Complete => CONTINUATION_COMPLETE,
            ReplContinuationMode::IncompleteImplicit => CONTINUATION_INCOMPLETE_IMPLICIT,
            ReplContinuationMode::IncompleteBlock => CONTINUATION_INCOMPLETE_BLOCK,
        }
    }

    // -----------------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------------

    /// Extracts the `MontyRepl` from `Idle` or `Complete` state.
    ///
    /// Sets state to `Consumed` temporarily. The caller must store a new
    /// state before returning to the C API.
    fn take_repl(&mut self) -> Result<MontyRepl<Tracker>, String> {
        let state = std::mem::replace(&mut self.state, ReplHandleState::Consumed);
        match state {
            ReplHandleState::Idle(repl) | ReplHandleState::Complete { repl, .. } => Ok(repl),
            other => {
                self.state = other;
                Err("handle not in Idle or Complete state".into())
            }
        }
    }

    /// Processes a `ReplProgress` value, updating the handle state and
    /// returning the progress tag.
    ///
    /// `NameLookup` variants are auto-resolved in a loop using `ext_fn_names`.
    fn process_repl_progress(
        &mut self,
        mut progress: ReplProgress<Tracker>,
    ) -> (MontyProgressTag, Option<String>) {
        loop {
            match progress {
                ReplProgress::Complete { repl, value } => {
                    let val = monty_object_to_json(&value);
                    let result_json = build_repl_result_json(&val, None, &self.print_output);
                    self.print_output.clear();
                    self.state = ReplHandleState::Complete {
                        repl,
                        result_json,
                        is_error: false,
                    };
                    return (MontyProgressTag::Complete, None);
                }
                ReplProgress::FunctionCall(call) => {
                    let meta = build_pending_meta(
                        call.function_name.clone(),
                        &call.args,
                        &call.kwargs,
                        call.call_id,
                        call.method_call,
                    );
                    self.state = ReplHandleState::Paused { call, meta };
                    return (MontyProgressTag::Pending, None);
                }
                ReplProgress::OsCall(call) => {
                    let meta = OsCallMeta {
                        os_fn_name: call.function.to_string(),
                        args_json: serde_json::to_string(
                            &call
                                .args
                                .iter()
                                .map(monty_object_to_json)
                                .collect::<Vec<_>>(),
                        )
                        .unwrap_or_else(|_| "[]".into()),
                        kwargs_json: if call.kwargs.is_empty() {
                            "{}".into()
                        } else {
                            let map: serde_json::Map<String, Value> = call
                                .kwargs
                                .iter()
                                .map(|(k, v)| {
                                    let key = if let MontyObject::String(s) = k {
                                        s.clone()
                                    } else {
                                        format!("{k}")
                                    };
                                    (key, monty_object_to_json(v))
                                })
                                .collect();
                            serde_json::to_string(&map).unwrap_or_else(|_| "{}".into())
                        },
                        call_id: call.call_id,
                    };
                    self.state = ReplHandleState::OsCall { call, meta };
                    return (MontyProgressTag::OsCall, None);
                }
                ReplProgress::ResolveFutures(futures) => {
                    let call_ids_json = serde_json::to_string(futures.pending_call_ids())
                        .unwrap_or_else(|_| "[]".into());
                    self.state = ReplHandleState::Futures {
                        futures,
                        call_ids_json,
                    };
                    return (MontyProgressTag::ResolveFutures, None);
                }
                ReplProgress::NameLookup(lookup) => {
                    let name = lookup.name.clone();
                    let mut buf = String::new();
                    let result = if self.ext_fn_names.contains(&name) {
                        lookup.resume(
                            NameLookupResult::Value(MontyObject::Function {
                                name,
                                docstring: None,
                            }),
                            PrintWriter::CollectString(&mut buf),
                        )
                    } else {
                        lookup.resume(
                            NameLookupResult::Undefined,
                            PrintWriter::CollectString(&mut buf),
                        )
                    };
                    self.print_output.push_str(&buf);
                    match result {
                        Ok(next) => progress = next,
                        Err(err) => return self.handle_repl_start_error(*err),
                    }
                }
            }
        }
    }

    /// Handles a `ReplStartError` — recovers the REPL and stores the error.
    fn handle_repl_start_error(
        &mut self,
        err: ReplStartError<Tracker>,
    ) -> (MontyProgressTag, Option<String>) {
        let err_json = monty_exception_to_json(&err.error);
        let msg = err.error.summary();
        let result_json = build_repl_result_json(&Value::Null, Some(err_json), &self.print_output);
        self.print_output.clear();
        self.state = ReplHandleState::Complete {
            repl: err.repl,
            result_json,
            is_error: true,
        };
        (MontyProgressTag::Error, Some(msg))
    }
}

// ---------------------------------------------------------------------------
// Helper functions
// ---------------------------------------------------------------------------

/// Build a `PendingMeta` from function call data.
fn build_pending_meta(
    function_name: String,
    args: &[MontyObject],
    kwargs: &[(MontyObject, MontyObject)],
    call_id: u32,
    method_call: bool,
) -> PendingMeta {
    let args_json =
        serde_json::to_string(&args.iter().map(monty_object_to_json).collect::<Vec<_>>())
            .unwrap_or_else(|_| "[]".into());

    let kwargs_json = if kwargs.is_empty() {
        "{}".into()
    } else {
        let map: serde_json::Map<String, Value> = kwargs
            .iter()
            .map(|(k, v)| {
                let key = if let MontyObject::String(s) = k {
                    s.clone()
                } else {
                    format!("{k}")
                };
                (key, monty_object_to_json(v))
            })
            .collect();
        serde_json::to_string(&map).unwrap_or_else(|_| "{}".into())
    };

    PendingMeta {
        fn_name: function_name,
        args_json,
        kwargs_json,
        call_id,
        method_call,
    }
}

/// Build result JSON in the same format as `MontyHandle::run` results.
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

    // -----------------------------------------------------------------------
    // Phase 1 tests (feed_run still works with new state machine)
    // -----------------------------------------------------------------------

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

        let (tag, _, _) = repl.feed_run("1 / 0");
        assert_eq!(tag, MontyResultTag::Error);

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

    // -----------------------------------------------------------------------
    // Phase 2 tests (feed_start + resume)
    // -----------------------------------------------------------------------

    #[test]
    fn feed_start_with_ext_fn_pauses() {
        let mut repl = MontyReplHandle::new("test.py");
        repl.set_ext_fns(vec!["get_temp".into()]);

        let (tag, _) = repl.feed_start("result = get_temp()");
        assert_eq!(tag, MontyProgressTag::Pending);
        assert_eq!(repl.pending_fn_name(), Some("get_temp"));
        assert_eq!(repl.pending_call_id(), Some(0));
    }

    #[test]
    fn feed_start_resume_completes() {
        let mut repl = MontyReplHandle::new("test.py");
        repl.set_ext_fns(vec!["get_temp".into()]);

        let (tag, _) = repl.feed_start("result = get_temp()\nresult");
        assert_eq!(tag, MontyProgressTag::Pending);

        let (tag, _) = repl.resume("72");
        assert_eq!(tag, MontyProgressTag::Complete);

        // Verify result JSON — last expression is `result` which evaluates to 72
        let result_json = repl.complete_result_json().unwrap();
        let parsed: serde_json::Value = serde_json::from_str(result_json).unwrap();
        assert_eq!(parsed["value"], 72);
    }

    #[test]
    fn feed_start_state_persists_after_resume() {
        let mut repl = MontyReplHandle::new("test.py");
        repl.set_ext_fns(vec!["get_temp".into()]);

        // Use feed_start to set a variable via external function
        let (tag, _) = repl.feed_start("temp = get_temp()");
        assert_eq!(tag, MontyProgressTag::Pending);

        let (tag, _) = repl.resume("72");
        assert_eq!(tag, MontyProgressTag::Complete);

        // Now use feed_run to verify state persisted
        let (tag, json, _) = repl.feed_run("temp");
        assert_eq!(tag, MontyResultTag::Ok);
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["value"], 72);
    }

    #[test]
    fn feed_start_multiple_ext_fn_calls() {
        let mut repl = MontyReplHandle::new("test.py");
        repl.set_ext_fns(vec!["get_a".into(), "get_b".into()]);

        let (tag, _) = repl.feed_start("a = get_a()\nb = get_b()\na + b");

        // First call: get_a
        assert_eq!(tag, MontyProgressTag::Pending);
        assert_eq!(repl.pending_fn_name(), Some("get_a"));

        let (tag, _) = repl.resume("10");

        // Second call: get_b
        assert_eq!(tag, MontyProgressTag::Pending);
        assert_eq!(repl.pending_fn_name(), Some("get_b"));

        let (tag, _) = repl.resume("20");

        // Complete with a + b = 30
        assert_eq!(tag, MontyProgressTag::Complete);
        let result_json = repl.complete_result_json().unwrap();
        let parsed: serde_json::Value = serde_json::from_str(result_json).unwrap();
        assert_eq!(parsed["value"], 30);
    }

    #[test]
    fn feed_start_resume_with_error() {
        let mut repl = MontyReplHandle::new("test.py");
        repl.set_ext_fns(vec!["fetch".into()]);

        let (tag, _) = repl.feed_start(
            "try:\n    result = fetch('url')\nexcept Exception as e:\n    result = str(e)\nresult",
        );
        assert_eq!(tag, MontyProgressTag::Pending);

        let (tag, _) = repl.resume_with_error("connection refused");
        assert_eq!(tag, MontyProgressTag::Complete);

        let result_json = repl.complete_result_json().unwrap();
        let parsed: serde_json::Value = serde_json::from_str(result_json).unwrap();
        assert!(
            parsed["value"]
                .as_str()
                .unwrap()
                .contains("connection refused")
        );
    }

    #[test]
    fn feed_start_error_recovers_repl() {
        let mut repl = MontyReplHandle::new("test.py");
        repl.feed_run("x = 42");

        // feed_start with code that raises immediately
        let (tag, _) = repl.feed_start("1 / 0");
        assert_eq!(tag, MontyProgressTag::Error);
        assert_eq!(repl.complete_is_error(), Some(true));

        // REPL is recovered — x still accessible
        let (tag, json, _) = repl.feed_run("x");
        assert_eq!(tag, MontyResultTag::Ok);
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["value"], 42);
    }

    #[test]
    fn feed_start_unknown_fn_yields_pending() {
        let mut repl = MontyReplHandle::new("test.py");
        // Without ext_fns registered, an unknown function call still
        // yields Pending — the host decides how to respond.
        let (tag, _) = repl.feed_start("unknown_fn()");
        assert_eq!(tag, MontyProgressTag::Pending);
        assert_eq!(repl.pending_fn_name(), Some("unknown_fn"));

        // Resume with error to reject the call.
        let (tag, _) = repl.resume_with_error("not implemented");
        // The snippet wraps the error, so it completes with an error.
        assert_eq!(tag, MontyProgressTag::Error);
        assert_eq!(repl.complete_is_error(), Some(true));
    }

    #[test]
    fn resume_wrong_state_returns_error() {
        let mut repl = MontyReplHandle::new("test.py");
        let (tag, err) = repl.resume("42");
        assert_eq!(tag, MontyProgressTag::Error);
        assert!(err.is_some());
    }

    #[test]
    fn feed_run_after_feed_start_cycle() {
        let mut repl = MontyReplHandle::new("test.py");
        repl.set_ext_fns(vec!["get_val".into()]);

        // feed_start cycle
        repl.feed_start("x = get_val()");
        repl.resume("100");

        // feed_run should still work
        let (tag, json, _) = repl.feed_run("x * 2");
        assert_eq!(tag, MontyResultTag::Ok);
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["value"], 200);
    }
}
