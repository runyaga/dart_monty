use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, RwLock, Weak};
use std::time::Duration;

use std::collections::HashSet;

use monty::{
    CancellableTracker, ExtFunctionResult, FunctionCall, LimitedTracker, MontyException,
    MontyObject, MontyRun, NameLookupResult, NoLimitTracker, PrintWriter, ResolveFutures,
    ResourceLimits, RunProgress,
};
use serde_json::Value;

use crate::convert::{json_to_monty_object, monty_object_to_json};
use crate::error::monty_exception_to_json;

// ---------------------------------------------------------------------------
// Cancel Registry — global, thread-safe, UAF-immune
// ---------------------------------------------------------------------------

/// Global registry mapping monotonic handle IDs to weak cancel flags.
/// Uses `Weak<AtomicBool>` so entries become dead when the handle drops.
static CANCEL_REGISTRY: LazyLock<RwLock<HashMap<u64, Weak<AtomicBool>>>> =
    LazyLock::new(|| RwLock::new(HashMap::new()));

/// Monotonic handle ID counter. Eliminates ABA problem from address reuse.
static NEXT_HANDLE_ID: AtomicU64 = AtomicU64::new(1);

/// Type aliases for CancellableTracker-wrapped tracker types.
type CLimited = CancellableTracker<LimitedTracker>;
type CUnlimited = CancellableTracker<NoLimitTracker>;

/// Maps a `ResourceTracker` type to its `HandleState` variants.
trait TrackerExt: monty::ResourceTracker + Sized {
    fn into_paused(call: FunctionCall<Self>, meta: PendingMeta) -> HandleState;
    fn into_futures(futures: ResolveFutures<Self>, call_ids_json: String) -> HandleState;
}

impl TrackerExt for CLimited {
    fn into_paused(call: FunctionCall<Self>, meta: PendingMeta) -> HandleState {
        HandleState::PausedLimited { call, meta }
    }
    fn into_futures(futures: ResolveFutures<Self>, call_ids_json: String) -> HandleState {
        HandleState::FuturesLimited {
            futures,
            call_ids_json,
        }
    }
}

impl TrackerExt for CUnlimited {
    fn into_paused(call: FunctionCall<Self>, meta: PendingMeta) -> HandleState {
        HandleState::PausedNoLimit { call, meta }
    }
    fn into_futures(futures: ResolveFutures<Self>, call_ids_json: String) -> HandleState {
        HandleState::FuturesNoLimit {
            futures,
            call_ids_json,
        }
    }
}

/// Result tag for `monty_run` — matches `MontyResultTag` in the C header.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MontyResultTag {
    Ok = 0,
    Error = 1,
}

/// Progress tag for `monty_start`/`monty_resume` — matches `MontyProgressTag`
/// in the C header.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MontyProgressTag {
    Complete = 0,
    Pending = 1,
    Error = 2,
    ResolveFutures = 3,
}

/// Metadata captured when paused at a `FunctionCall`.
struct PendingMeta {
    fn_name: String,
    args_json: String,
    kwargs_json: String,
    call_id: u32,
    method_call: bool,
}

/// Internal state of a running handle.
enum HandleState {
    Ready(MontyRun),
    PausedLimited {
        call: FunctionCall<CLimited>,
        meta: PendingMeta,
    },
    PausedNoLimit {
        call: FunctionCall<CUnlimited>,
        meta: PendingMeta,
    },
    FuturesLimited {
        futures: ResolveFutures<CLimited>,
        call_ids_json: String,
    },
    FuturesNoLimit {
        futures: ResolveFutures<CUnlimited>,
        call_ids_json: String,
    },
    Complete {
        result_json: String,
        is_error: bool,
    },
    Consumed,
}

/// Opaque handle exposed to C callers.
pub struct MontyHandle {
    state: HandleState,
    limits: Option<ResourceLimits>,
    ext_fn_names: HashSet<String>,
    usage_json: String,
    print_output: String,
    /// Shared cancel flag — set to `true` to request cancellation.
    /// Cloned into every `CancellableTracker` created for this handle.
    cancel_flag: Arc<AtomicBool>,
    /// Monotonic ID for cross-isolate cancel registry lookup.
    handle_id: u64,
}

impl MontyHandle {
    /// Create a new handle from Python source code.
    ///
    /// `script_name` sets the filename used in tracebacks and error messages.
    /// Pass `None` to default to `"<input>"`.
    pub fn new(
        code: String,
        external_functions: Vec<String>,
        script_name: Option<String>,
    ) -> Result<Self, MontyException> {
        let name = script_name.unwrap_or_else(|| "<input>".into());
        let compiled = MontyRun::new(code, &name, vec![])?;
        let cancel_flag = Arc::new(AtomicBool::new(false));
        let id = NEXT_HANDLE_ID.fetch_add(1, Ordering::Relaxed);

        CANCEL_REGISTRY
            .write()
            .unwrap_or_else(|e| e.into_inner())
            .insert(id, Arc::downgrade(&cancel_flag));

        Ok(Self {
            state: HandleState::Ready(compiled),
            limits: None,
            ext_fn_names: external_functions.into_iter().collect(),
            usage_json: default_usage_json(),
            print_output: String::new(),
            cancel_flag,
            handle_id: id,
        })
    }

    /// Run code to completion. Returns `(result_tag, result_json, error_msg)`.
    ///
    /// If the cancel flag is set, returns an error immediately without consuming
    /// the Ready state — the handle remains reusable after `reset_cancel()`.
    pub fn run(&mut self) -> (MontyResultTag, String, Option<String>) {
        if self.is_cancelled() {
            let err_json = serde_json::json!({
                "message": "KeyboardInterrupt",
                "exc_type": "KeyboardInterrupt"
            });
            let result_json = build_result_json(
                Value::Null,
                Some(err_json),
                &self.usage_json,
                &self.print_output,
            );
            return (
                MontyResultTag::Error,
                result_json,
                Some("KeyboardInterrupt".into()),
            );
        }

        let state = std::mem::replace(&mut self.state, HandleState::Consumed);
        let compiled = match state {
            HandleState::Ready(c) => c,
            _ => {
                self.state = state;
                return (
                    MontyResultTag::Error,
                    String::new(),
                    Some("handle not in Ready state".into()),
                );
            }
        };

        let mut print = PrintWriter::Collect(String::new());

        let result = if let Some(limits) = self.limits.clone() {
            let tracker = CancellableTracker::with_flag(
                LimitedTracker::new(limits),
                self.cancel_flag.clone(),
            );
            compiled.run(vec![], tracker, &mut print)
        } else {
            let tracker = CancellableTracker::with_flag(NoLimitTracker, self.cancel_flag.clone());
            compiled.run(vec![], tracker, &mut print)
        };

        self.drain_print(print);

        match result {
            Ok(obj) => {
                let val = monty_object_to_json(&obj);
                let result_json =
                    build_result_json(val, None, &self.usage_json, &self.print_output);
                self.state = HandleState::Complete {
                    result_json: result_json.clone(),
                    is_error: false,
                };
                (MontyResultTag::Ok, result_json, None)
            }
            Err(exc) => {
                let err_json = monty_exception_to_json(&exc);
                let result_json = build_result_json(
                    Value::Null,
                    Some(err_json),
                    &self.usage_json,
                    &self.print_output,
                );
                let msg = exc.summary();
                self.state = HandleState::Complete {
                    result_json: result_json.clone(),
                    is_error: true,
                };
                (MontyResultTag::Error, result_json, Some(msg))
            }
        }
    }

    /// Start iterative execution. Returns progress tag and sets internal state.
    ///
    /// If the cancel flag is set, returns an error immediately without consuming
    /// the Ready state — the handle remains reusable after `reset_cancel()`.
    pub fn start(&mut self) -> (MontyProgressTag, Option<String>) {
        if self.is_cancelled() {
            return (MontyProgressTag::Error, Some("KeyboardInterrupt".into()));
        }

        let state = std::mem::replace(&mut self.state, HandleState::Consumed);
        let compiled = match state {
            HandleState::Ready(c) => c,
            _ => {
                self.state = state;
                return (
                    MontyProgressTag::Error,
                    Some("handle not in Ready state".into()),
                );
            }
        };

        if let Some(limits) = self.limits.clone() {
            let tracker = CancellableTracker::with_flag(
                LimitedTracker::new(limits),
                self.cancel_flag.clone(),
            );
            self.run_snapshot_op(|print| compiled.start(vec![], tracker, print))
        } else {
            let tracker = CancellableTracker::with_flag(NoLimitTracker, self.cancel_flag.clone());
            self.run_snapshot_op(|print| compiled.start(vec![], tracker, print))
        }
    }

    /// Resume with a return value (JSON string).
    pub fn resume(&mut self, value_json: &str) -> (MontyProgressTag, Option<String>) {
        let val: Value = match serde_json::from_str(value_json) {
            Ok(v) => v,
            Err(e) => return (MontyProgressTag::Error, Some(format!("invalid JSON: {e}"))),
        };
        let obj = json_to_monty_object(&val);
        let result = ExtFunctionResult::Return(obj);
        self.resume_with_result(result)
    }

    /// Resume with an error message.
    pub fn resume_with_error(&mut self, error_message: &str) -> (MontyProgressTag, Option<String>) {
        let exc = MontyException::new(
            monty::ExcType::RuntimeError,
            Some(error_message.to_string()),
        );
        let result = ExtFunctionResult::Error(exc);
        self.resume_with_result(result)
    }

    /// Resume by creating a future (tells the VM this call returns a future).
    ///
    /// The VM continues executing until all coroutines are blocked, then
    /// yields `ResolveFutures`. Only valid in Paused state.
    pub fn resume_as_future(&mut self) -> (MontyProgressTag, Option<String>) {
        let state = std::mem::replace(&mut self.state, HandleState::Consumed);

        match state {
            HandleState::PausedLimited { call, .. } => {
                self.run_snapshot_op(|print| call.resume_pending(print))
            }
            HandleState::PausedNoLimit { call, .. } => {
                self.run_snapshot_op(|print| call.resume_pending(print))
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

    /// Get the pending future call IDs as a JSON array string.
    ///
    /// Only valid in FuturesLimited/FuturesNoLimit state. Returns
    /// a JSON array like `"[0, 1, 2]"`.
    pub fn pending_future_call_ids(&self) -> Option<&str> {
        match &self.state {
            HandleState::FuturesLimited { call_ids_json, .. }
            | HandleState::FuturesNoLimit { call_ids_json, .. } => Some(call_ids_json.as_str()),
            _ => None,
        }
    }

    /// Resume futures with results and errors.
    ///
    /// - `results_json`: JSON object `{"call_id": value, ...}` (string keys)
    /// - `errors_json`: JSON object `{"call_id": "error_message", ...}` (string keys), or empty
    pub fn resume_futures(
        &mut self,
        results_json: &str,
        errors_json: &str,
    ) -> (MontyProgressTag, Option<String>) {
        let results_map: serde_json::Map<String, Value> = match serde_json::from_str(results_json) {
            Ok(v) => v,
            Err(e) => {
                return (
                    MontyProgressTag::Error,
                    Some(format!("invalid results JSON: {e}")),
                );
            }
        };
        let errors_map: serde_json::Map<String, Value> = match serde_json::from_str(errors_json) {
            Ok(v) => v,
            Err(e) => {
                return (
                    MontyProgressTag::Error,
                    Some(format!("invalid errors JSON: {e}")),
                );
            }
        };

        let mut ext_results: Vec<(u32, ExtFunctionResult)> = Vec::new();

        for (key, val) in &results_map {
            let call_id: u32 = match key.parse() {
                Ok(id) => id,
                Err(_) => {
                    return (
                        MontyProgressTag::Error,
                        Some(format!("invalid call_id: {key}")),
                    );
                }
            };
            let obj = json_to_monty_object(val);
            ext_results.push((call_id, ExtFunctionResult::Return(obj)));
        }

        for (key, val) in &errors_map {
            let call_id: u32 = match key.parse() {
                Ok(id) => id,
                Err(_) => {
                    return (
                        MontyProgressTag::Error,
                        Some(format!("invalid call_id: {key}")),
                    );
                }
            };
            let msg = val.as_str().unwrap_or("unknown error").to_string();
            let exc = MontyException::new(monty::ExcType::RuntimeError, Some(msg));
            ext_results.push((call_id, ExtFunctionResult::Error(exc)));
        }

        let state = std::mem::replace(&mut self.state, HandleState::Consumed);

        match state {
            HandleState::FuturesLimited { futures, .. } => {
                self.run_snapshot_op(|print| futures.resume(ext_results, print))
            }
            HandleState::FuturesNoLimit { futures, .. } => {
                self.run_snapshot_op(|print| futures.resume(ext_results, print))
            }
            other => {
                self.state = other;
                (
                    MontyProgressTag::Error,
                    Some("handle not in Futures state".into()),
                )
            }
        }
    }

    /// Get the pending function name (only valid in Paused state).
    pub fn pending_fn_name(&self) -> Option<&str> {
        match &self.state {
            HandleState::PausedLimited { meta, .. } | HandleState::PausedNoLimit { meta, .. } => {
                Some(meta.fn_name.as_str())
            }
            _ => None,
        }
    }

    /// Get the pending function args as JSON (only valid in Paused state).
    pub fn pending_fn_args_json(&self) -> Option<&str> {
        match &self.state {
            HandleState::PausedLimited { meta, .. } | HandleState::PausedNoLimit { meta, .. } => {
                Some(meta.args_json.as_str())
            }
            _ => None,
        }
    }

    /// Get the pending function kwargs as JSON (only valid in Paused state).
    ///
    /// Returns a JSON object string like `{"key": value}`, or `"{}"` if no
    /// keyword arguments were passed.
    pub fn pending_fn_kwargs_json(&self) -> Option<&str> {
        match &self.state {
            HandleState::PausedLimited { meta, .. } | HandleState::PausedNoLimit { meta, .. } => {
                Some(meta.kwargs_json.as_str())
            }
            _ => None,
        }
    }

    /// Get the pending call ID (only valid in Paused state).
    ///
    /// The call ID is a monotonically increasing integer assigned by the VM
    /// to each external function call. Used for correlating async futures.
    pub fn pending_call_id(&self) -> Option<u32> {
        match &self.state {
            HandleState::PausedLimited { meta, .. } | HandleState::PausedNoLimit { meta, .. } => {
                Some(meta.call_id)
            }
            _ => None,
        }
    }

    /// Whether the pending call is a method call (only valid in Paused state).
    ///
    /// `true` when Python used `obj.method()` syntax, `false` for `func()`.
    pub fn pending_method_call(&self) -> Option<bool> {
        match &self.state {
            HandleState::PausedLimited { meta, .. } | HandleState::PausedNoLimit { meta, .. } => {
                Some(meta.method_call)
            }
            _ => None,
        }
    }

    /// Get the complete result as JSON (only valid in Complete state).
    pub fn complete_result_json(&self) -> Option<&str> {
        match &self.state {
            HandleState::Complete { result_json, .. } => Some(result_json.as_str()),
            _ => None,
        }
    }

    /// Whether the complete result is an error.
    pub fn complete_is_error(&self) -> Option<bool> {
        match &self.state {
            HandleState::Complete { is_error, .. } => Some(*is_error),
            _ => None,
        }
    }

    /// Serialize the compiled code to bytes (snapshot).
    pub fn snapshot(&self) -> Result<Vec<u8>, String> {
        match &self.state {
            HandleState::Ready(compiled) => {
                compiled.dump().map_err(|e| format!("snapshot failed: {e}"))
            }
            _ => Err("can only snapshot in Ready state".into()),
        }
    }

    /// Restore a handle from serialized bytes.
    pub fn restore(bytes: &[u8]) -> Result<Self, String> {
        let compiled = MontyRun::load(bytes).map_err(|e| format!("restore failed: {e}"))?;
        let cancel_flag = Arc::new(AtomicBool::new(false));
        let id = NEXT_HANDLE_ID.fetch_add(1, Ordering::Relaxed);

        CANCEL_REGISTRY
            .write()
            .unwrap_or_else(|e| e.into_inner())
            .insert(id, Arc::downgrade(&cancel_flag));

        Ok(Self {
            state: HandleState::Ready(compiled),
            limits: None,
            ext_fn_names: HashSet::new(),
            usage_json: default_usage_json(),
            print_output: String::new(),
            cancel_flag,
            handle_id: id,
        })
    }

    /// Set memory limit in bytes.
    pub fn set_memory_limit(&mut self, bytes: usize) {
        let limits = self.limits.get_or_insert_with(ResourceLimits::new);
        limits.max_memory = Some(bytes);
    }

    /// Set time limit in milliseconds.
    pub fn set_time_limit_ms(&mut self, ms: u64) {
        let limits = self.limits.get_or_insert_with(ResourceLimits::new);
        limits.max_duration = Some(Duration::from_millis(ms));
    }

    /// Set stack depth limit.
    pub fn set_stack_limit(&mut self, depth: usize) {
        let limits = self.limits.get_or_insert_with(ResourceLimits::new);
        limits.max_recursion_depth = Some(depth);
    }

    /// Get the monotonic handle ID for cross-isolate cancel registry lookup.
    pub fn handle_id(&self) -> u64 {
        self.handle_id
    }

    /// Request cancellation. Safe to call from any thread.
    pub fn cancel(&self) {
        self.cancel_flag.store(true, Ordering::Relaxed);
    }

    /// Query whether cancellation has been requested.
    pub fn is_cancelled(&self) -> bool {
        self.cancel_flag.load(Ordering::Relaxed)
    }

    /// Reset the cancellation flag. Call before reusing a handle after cancel.
    pub fn reset_cancel(&self) {
        self.cancel_flag.store(false, Ordering::Relaxed);
    }

    // --- private helpers ---

    fn drain_print(&mut self, print: PrintWriter) {
        if let PrintWriter::Collect(collected) = print {
            self.print_output.push_str(&collected);
        }
    }

    fn run_snapshot_op<T: TrackerExt>(
        &mut self,
        f: impl FnOnce(&mut PrintWriter) -> Result<RunProgress<T>, MontyException>,
    ) -> (MontyProgressTag, Option<String>) {
        let mut print = PrintWriter::Collect(String::new());
        let result = f(&mut print);
        match result {
            Ok(progress) => self.process_progress(progress, print),
            Err(exc) => {
                self.drain_print(print);
                self.handle_exception(exc)
            }
        }
    }

    fn resume_with_result(
        &mut self,
        result: ExtFunctionResult,
    ) -> (MontyProgressTag, Option<String>) {
        let state = std::mem::replace(&mut self.state, HandleState::Consumed);

        match state {
            HandleState::PausedLimited { call, .. } => {
                self.run_snapshot_op(|print| call.resume(result, print))
            }
            HandleState::PausedNoLimit { call, .. } => {
                self.run_snapshot_op(|print| call.resume(result, print))
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

    fn process_progress<T: TrackerExt>(
        &mut self,
        mut progress: RunProgress<T>,
        mut print: PrintWriter,
    ) -> (MontyProgressTag, Option<String>) {
        loop {
            match progress {
                RunProgress::Complete(obj) => {
                    self.drain_print(print);
                    let val = monty_object_to_json(&obj);
                    let result_json =
                        build_result_json(val, None, &self.usage_json, &self.print_output);
                    self.state = HandleState::Complete {
                        result_json,
                        is_error: false,
                    };
                    return (MontyProgressTag::Complete, None);
                }
                RunProgress::FunctionCall(call) => {
                    self.drain_print(print);
                    let meta = build_pending_meta(
                        call.function_name.clone(),
                        &call.args,
                        &call.kwargs,
                        call.call_id,
                        call.method_call,
                    );
                    self.state = T::into_paused(call, meta);
                    return (MontyProgressTag::Pending, None);
                }
                RunProgress::ResolveFutures(futures) => {
                    self.drain_print(print);
                    let call_ids_json = serde_json::to_string(futures.pending_call_ids())
                        .unwrap_or_else(|_| "[]".into());
                    self.state = T::into_futures(futures, call_ids_json);
                    return (MontyProgressTag::ResolveFutures, None);
                }
                RunProgress::NameLookup(lookup) => {
                    let name = lookup.name.clone();
                    let result = if self.ext_fn_names.contains(&name) {
                        lookup.resume(
                            NameLookupResult::Value(MontyObject::Function {
                                name,
                                docstring: None,
                            }),
                            &mut print,
                        )
                    } else {
                        lookup.resume(NameLookupResult::Undefined, &mut print)
                    };
                    match result {
                        Ok(next) => progress = next,
                        Err(exc) => {
                            self.drain_print(print);
                            return self.handle_exception(exc);
                        }
                    }
                }
                RunProgress::OsCall(_) => {
                    self.drain_print(print);
                    self.state = HandleState::Complete {
                        result_json: build_result_json(
                            Value::Null,
                            Some(
                                serde_json::json!({"message": "unsupported progress type: OsCall"}),
                            ),
                            &self.usage_json,
                            &self.print_output,
                        ),
                        is_error: true,
                    };
                    return (
                        MontyProgressTag::Error,
                        Some("unsupported progress type: OsCall".into()),
                    );
                }
            }
        }
    }

    fn handle_exception(&mut self, exc: MontyException) -> (MontyProgressTag, Option<String>) {
        let err_json = monty_exception_to_json(&exc);
        let result_json = build_result_json(
            Value::Null,
            Some(err_json),
            &self.usage_json,
            &self.print_output,
        );
        let msg = exc.summary();
        self.state = HandleState::Complete {
            result_json,
            is_error: true,
        };
        (MontyProgressTag::Error, Some(msg))
    }
}

// ---------------------------------------------------------------------------
// Registry-level cancel API (cross-isolate safe, UAF-immune)
// ---------------------------------------------------------------------------

/// Request cancellation by handle ID.
/// Returns `0` on success, `-1` if handle not found (already freed),
/// `-2` if the Arc was dropped (shouldn't happen while handle exists).
pub fn cancel_by_id(handle_id: u64) -> i32 {
    let registry = CANCEL_REGISTRY.read().unwrap_or_else(|e| e.into_inner());
    match registry.get(&handle_id) {
        None => -1,
        Some(weak) => match weak.upgrade() {
            None => -2,
            Some(flag) => {
                flag.store(true, Ordering::Relaxed);
                0
            }
        },
    }
}

/// Query cancellation by handle ID.
/// Returns `1` if cancelled, `0` if not, `-1` if handle not found.
pub fn is_cancelled_by_id(handle_id: u64) -> i32 {
    let registry = CANCEL_REGISTRY.read().unwrap_or_else(|e| e.into_inner());
    match registry.get(&handle_id) {
        None => -1,
        Some(weak) => match weak.upgrade() {
            None => -1,
            Some(flag) => {
                if flag.load(Ordering::Relaxed) {
                    1
                } else {
                    0
                }
            }
        },
    }
}

impl Drop for MontyHandle {
    fn drop(&mut self) {
        CANCEL_REGISTRY
            .write()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&self.handle_id);
    }
}

/// Build a `PendingMeta` from a `FunctionCall` variant's fields.
fn build_pending_meta(
    function_name: String,
    args: &[monty::MontyObject],
    kwargs: &[(monty::MontyObject, monty::MontyObject)],
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
                let key = if let monty::MontyObject::String(s) = k {
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

fn default_usage_json() -> String {
    r#"{"memory_bytes_used":0,"time_elapsed_ms":0,"stack_depth_used":0}"#.into()
}

fn build_result_json(
    value: Value,
    error: Option<Value>,
    usage_json: &str,
    print_output: &str,
) -> String {
    let usage: Value = serde_json::from_str(usage_json).unwrap_or(serde_json::json!({
        "memory_bytes_used": 0,
        "time_elapsed_ms": 0,
        "stack_depth_used": 0,
    }));
    let mut result = serde_json::json!({
        "value": value,
        "usage": usage,
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
    fn test_create_handle() {
        let handle = MontyHandle::new("2 + 2".into(), vec![], None);
        assert!(handle.is_ok());
    }

    #[test]
    fn test_create_handle_syntax_error() {
        let handle = MontyHandle::new("def".into(), vec![], None);
        assert!(handle.is_err());
    }

    #[test]
    fn test_run_simple() {
        let mut handle = MontyHandle::new("2 + 2".into(), vec![], None).unwrap();
        let (tag, result_json, err) = handle.run();
        assert_eq!(tag, MontyResultTag::Ok);
        assert!(err.is_none());
        let parsed: Value = serde_json::from_str(&result_json).unwrap();
        assert_eq!(parsed["value"], json!(4));
    }

    #[test]
    fn test_run_error() {
        let mut handle = MontyHandle::new("1/0".into(), vec![], None).unwrap();
        let (tag, _, err) = handle.run();
        assert_eq!(tag, MontyResultTag::Error);
        assert!(err.is_some());
    }

    #[test]
    fn test_run_not_ready() {
        let mut handle = MontyHandle::new("2 + 2".into(), vec![], None).unwrap();
        handle.run(); // consume Ready state
        let (tag, _, err) = handle.run();
        assert_eq!(tag, MontyResultTag::Error);
        assert!(err.unwrap().contains("not in Ready state"));
    }

    #[test]
    fn test_set_limits() {
        let mut handle = MontyHandle::new("2 + 2".into(), vec![], None).unwrap();
        handle.set_memory_limit(1024 * 1024);
        handle.set_time_limit_ms(5000);
        handle.set_stack_limit(100);
        let (tag, _, _) = handle.run();
        assert_eq!(tag, MontyResultTag::Ok);
    }

    #[test]
    fn test_snapshot_restore() {
        let handle = MontyHandle::new("2 + 2".into(), vec![], None).unwrap();
        let bytes = handle.snapshot().unwrap();
        assert!(!bytes.is_empty());

        let mut restored = MontyHandle::restore(&bytes).unwrap();
        let (tag, result_json, _) = restored.run();
        assert_eq!(tag, MontyResultTag::Ok);
        let parsed: Value = serde_json::from_str(&result_json).unwrap();
        assert_eq!(parsed["value"], json!(4));
    }

    #[test]
    fn test_snapshot_wrong_state() {
        let mut handle = MontyHandle::new("2 + 2".into(), vec![], None).unwrap();
        handle.run();
        let result = handle.snapshot();
        assert!(result.is_err());
    }

    #[test]
    fn test_restore_invalid_bytes() {
        let result = MontyHandle::restore(&[0, 1, 2, 3]);
        assert!(result.is_err());
    }

    #[test]
    fn test_start_complete() {
        let mut handle = MontyHandle::new("2 + 2".into(), vec![], None).unwrap();
        let (tag, err) = handle.start();
        assert_eq!(tag, MontyProgressTag::Complete);
        assert!(err.is_none());
        assert!(handle.complete_result_json().is_some());
        assert_eq!(handle.complete_is_error(), Some(false));
    }

    #[test]
    fn test_iterative_execution() {
        let code = r#"
result = ext_fn(42)
result + 1
"#;
        let mut handle = MontyHandle::new(code.into(), vec!["ext_fn".into()], None).unwrap();
        let (tag, err) = handle.start();
        assert_eq!(tag, MontyProgressTag::Pending);
        assert!(err.is_none());
        assert_eq!(handle.pending_fn_name(), Some("ext_fn"));

        let args: Value = serde_json::from_str(handle.pending_fn_args_json().unwrap()).unwrap();
        assert_eq!(args, json!([42]));

        // Resume with 100
        let (tag, err) = handle.resume("100");
        assert_eq!(tag, MontyProgressTag::Complete);
        assert!(err.is_none());

        let result: Value = serde_json::from_str(handle.complete_result_json().unwrap()).unwrap();
        assert_eq!(result["value"], json!(101));
    }

    #[test]
    fn test_resume_with_error() {
        let code = r#"
try:
    result = ext_fn(1)
except RuntimeError as e:
    result = str(e)
result
"#;
        let mut handle = MontyHandle::new(code.into(), vec!["ext_fn".into()], None).unwrap();
        let (tag, _) = handle.start();
        assert_eq!(tag, MontyProgressTag::Pending);

        let (tag, _) = handle.resume_with_error("something went wrong");
        assert_eq!(tag, MontyProgressTag::Complete);
        assert_eq!(handle.complete_is_error(), Some(false));

        let result: Value = serde_json::from_str(handle.complete_result_json().unwrap()).unwrap();
        assert!(
            result["value"]
                .as_str()
                .unwrap()
                .contains("something went wrong")
        );
    }

    #[test]
    fn test_pending_accessors_wrong_state() {
        let handle = MontyHandle::new("2 + 2".into(), vec![], None).unwrap();
        assert!(handle.pending_fn_name().is_none());
        assert!(handle.pending_fn_args_json().is_none());
        assert!(handle.complete_result_json().is_none());
        assert!(handle.complete_is_error().is_none());
    }

    #[test]
    fn test_start_not_ready() {
        let mut handle = MontyHandle::new("2 + 2".into(), vec![], None).unwrap();
        handle.run();
        let (tag, err) = handle.start();
        assert_eq!(tag, MontyProgressTag::Error);
        assert!(err.is_some());
    }

    #[test]
    fn test_resume_not_paused() {
        let mut handle = MontyHandle::new("2 + 2".into(), vec![], None).unwrap();
        let (tag, err) = handle.resume("42");
        assert_eq!(tag, MontyProgressTag::Error);
        assert!(err.is_some());
    }

    #[test]
    fn test_resume_invalid_json() {
        let code = "result = ext_fn(1)\nresult";
        let mut handle = MontyHandle::new(code.into(), vec!["ext_fn".into()], None).unwrap();
        handle.start();
        let (tag, err) = handle.resume("not valid json{");
        assert_eq!(tag, MontyProgressTag::Error);
        assert!(err.unwrap().contains("invalid JSON"));
    }

    use serde_json::json;

    #[test]
    fn test_iterative_no_limits() {
        // Exercise the NoLimitTracker path through start/resume
        let code = "result = ext_fn(10)\nresult + 5";
        let mut handle = MontyHandle::new(code.into(), vec!["ext_fn".into()], None).unwrap();
        // No limits set — uses NoLimitTracker
        let (tag, err) = handle.start();
        assert_eq!(tag, MontyProgressTag::Pending);
        assert!(err.is_none());
        assert_eq!(handle.pending_fn_name(), Some("ext_fn"));

        let (tag, err) = handle.resume("20");
        assert_eq!(tag, MontyProgressTag::Complete);
        assert!(err.is_none());

        let result: Value = serde_json::from_str(handle.complete_result_json().unwrap()).unwrap();
        assert_eq!(result["value"], json!(25));
    }

    #[test]
    fn test_start_runtime_error() {
        // Exception during start() — covers handle_exception via iterative path
        let mut handle = MontyHandle::new("1/0".into(), vec![], None).unwrap();
        let (tag, err) = handle.start();
        assert_eq!(tag, MontyProgressTag::Error);
        assert!(err.is_some());
        assert!(handle.complete_is_error() == Some(true));
    }

    #[test]
    fn test_start_with_limits_complete() {
        // LimitedTracker start that completes immediately
        let mut handle = MontyHandle::new("2 + 2".into(), vec![], None).unwrap();
        handle.set_memory_limit(10 * 1024 * 1024);
        handle.set_time_limit_ms(5000);
        let (tag, err) = handle.start();
        assert_eq!(tag, MontyProgressTag::Complete);
        assert!(err.is_none());
        assert_eq!(handle.complete_is_error(), Some(false));
    }

    #[test]
    fn test_iterative_with_limits() {
        // Exercise the LimitedTracker path through start/resume
        let code = "result = ext_fn(1)\nresult * 2";
        let mut handle = MontyHandle::new(code.into(), vec!["ext_fn".into()], None).unwrap();
        handle.set_memory_limit(10 * 1024 * 1024);
        handle.set_time_limit_ms(5000);
        let (tag, err) = handle.start();
        assert_eq!(tag, MontyProgressTag::Pending);
        assert!(err.is_none());

        let (tag, err) = handle.resume("50");
        assert_eq!(tag, MontyProgressTag::Complete);
        assert!(err.is_none());

        let result: Value = serde_json::from_str(handle.complete_result_json().unwrap()).unwrap();
        assert_eq!(result["value"], json!(100));
    }

    #[test]
    fn test_run_with_limits_error() {
        // Run with limits that triggers an exception
        let mut handle = MontyHandle::new("1/0".into(), vec![], None).unwrap();
        handle.set_memory_limit(10 * 1024 * 1024);
        let (tag, _, err) = handle.run();
        assert_eq!(tag, MontyResultTag::Error);
        assert!(err.is_some());
    }

    #[test]
    fn test_multiple_ext_fn_calls() {
        // Multiple pauses: Paused→Paused→Complete
        let code = "a = ext_fn(1)\nb = ext_fn(2)\na + b";
        let mut handle = MontyHandle::new(code.into(), vec!["ext_fn".into()], None).unwrap();
        let (tag, _) = handle.start();
        assert_eq!(tag, MontyProgressTag::Pending);
        assert_eq!(handle.pending_fn_name(), Some("ext_fn"));

        let (tag, _) = handle.resume("10");
        assert_eq!(tag, MontyProgressTag::Pending);
        assert_eq!(handle.pending_fn_name(), Some("ext_fn"));

        let (tag, _) = handle.resume("20");
        assert_eq!(tag, MontyProgressTag::Complete);

        let result: Value = serde_json::from_str(handle.complete_result_json().unwrap()).unwrap();
        assert_eq!(result["value"], json!(30));
    }

    #[test]
    fn test_default_usage_json() {
        let usage: Value = serde_json::from_str(&default_usage_json()).unwrap();
        assert_eq!(usage["memory_bytes_used"], 0);
        assert_eq!(usage["time_elapsed_ms"], 0);
        assert_eq!(usage["stack_depth_used"], 0);
    }

    #[test]
    fn test_build_result_json_ok() {
        let result = build_result_json(json!(42), None, &default_usage_json(), "");
        let parsed: Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["value"], 42);
        assert!(parsed.get("error").is_none());
        assert!(parsed.get("print_output").is_none());
        assert!(parsed["usage"].is_object());
    }

    #[test]
    fn test_build_result_json_error() {
        let err = json!({"message": "boom"});
        let result = build_result_json(Value::Null, Some(err), &default_usage_json(), "");
        let parsed: Value = serde_json::from_str(&result).unwrap();
        assert!(parsed["value"].is_null());
        assert_eq!(parsed["error"]["message"], "boom");
    }

    #[test]
    fn test_build_result_json_with_print_output() {
        let result = build_result_json(json!(42), None, &default_usage_json(), "hello world\n");
        let parsed: Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["value"], 42);
        assert_eq!(parsed["print_output"], "hello world\n");
    }

    #[test]
    fn test_build_result_json_empty_print_output_omitted() {
        let result = build_result_json(json!(42), None, &default_usage_json(), "");
        let parsed: Value = serde_json::from_str(&result).unwrap();
        assert!(parsed.get("print_output").is_none());
    }

    #[test]
    fn test_run_captures_print_output() {
        let mut handle = MontyHandle::new("print('hello')".into(), vec![], None).unwrap();
        let (tag, result_json, _) = handle.run();
        assert_eq!(tag, MontyResultTag::Ok);
        let parsed: Value = serde_json::from_str(&result_json).unwrap();
        assert_eq!(parsed["print_output"], "hello\n");
    }

    #[test]
    fn test_run_no_print_output_omits_key() {
        let mut handle = MontyHandle::new("2 + 2".into(), vec![], None).unwrap();
        let (tag, result_json, _) = handle.run();
        assert_eq!(tag, MontyResultTag::Ok);
        let parsed: Value = serde_json::from_str(&result_json).unwrap();
        assert!(parsed.get("print_output").is_none());
    }

    #[test]
    fn test_start_captures_print_no_limits() {
        let mut handle = MontyHandle::new("print('start')\n42".into(), vec![], None).unwrap();
        let (tag, err) = handle.start();
        assert_eq!(tag, MontyProgressTag::Complete);
        assert!(err.is_none());
        let result: Value = serde_json::from_str(handle.complete_result_json().unwrap()).unwrap();
        assert_eq!(result["print_output"], "start\n");
        assert_eq!(result["value"], 42);
    }

    #[test]
    fn test_start_captures_print_with_limits() {
        let mut handle = MontyHandle::new("print('limited')\n99".into(), vec![], None).unwrap();
        handle.set_memory_limit(10 * 1024 * 1024);
        let (tag, err) = handle.start();
        assert_eq!(tag, MontyProgressTag::Complete);
        assert!(err.is_none());
        let result: Value = serde_json::from_str(handle.complete_result_json().unwrap()).unwrap();
        assert_eq!(result["print_output"], "limited\n");
        assert_eq!(result["value"], 99);
    }

    #[test]
    fn test_iterative_captures_print_across_steps() {
        let code = "print('before')\na = ext_fn(1)\nprint('after')\na + 10";
        let mut handle = MontyHandle::new(code.into(), vec!["ext_fn".into()], None).unwrap();
        let (tag, _) = handle.start();
        assert_eq!(tag, MontyProgressTag::Pending);

        let (tag, _) = handle.resume("5");
        assert_eq!(tag, MontyProgressTag::Complete);
        let result: Value = serde_json::from_str(handle.complete_result_json().unwrap()).unwrap();
        assert_eq!(result["value"], 15);
        assert_eq!(result["print_output"], "before\nafter\n");
    }

    #[test]
    fn test_iterative_captures_print_with_limits() {
        let code = "print('hello')\na = ext_fn(1)\na";
        let mut handle = MontyHandle::new(code.into(), vec!["ext_fn".into()], None).unwrap();
        handle.set_memory_limit(10 * 1024 * 1024);
        let (tag, _) = handle.start();
        assert_eq!(tag, MontyProgressTag::Pending);

        let (tag, _) = handle.resume("7");
        assert_eq!(tag, MontyProgressTag::Complete);
        let result: Value = serde_json::from_str(handle.complete_result_json().unwrap()).unwrap();
        assert_eq!(result["value"], 7);
        assert_eq!(result["print_output"], "hello\n");
    }

    #[test]
    fn test_start_error_captures_print() {
        let code = "print('oops')\n1/0";
        let mut handle = MontyHandle::new(code.into(), vec![], None).unwrap();
        let (tag, err) = handle.start();
        assert_eq!(tag, MontyProgressTag::Error);
        assert!(err.is_some());
        let result: Value = serde_json::from_str(handle.complete_result_json().unwrap()).unwrap();
        assert_eq!(result["print_output"], "oops\n");
    }

    #[test]
    fn test_run_with_limits_captures_print() {
        let mut handle = MontyHandle::new("print('lim')\n7".into(), vec![], None).unwrap();
        handle.set_memory_limit(10 * 1024 * 1024);
        let (tag, result_json, _) = handle.run();
        assert_eq!(tag, MontyResultTag::Ok);
        let parsed: Value = serde_json::from_str(&result_json).unwrap();
        assert_eq!(parsed["print_output"], "lim\n");
    }

    #[test]
    fn test_start_error_captures_print_with_limits() {
        let code = "print('boom')\n1/0";
        let mut handle = MontyHandle::new(code.into(), vec![], None).unwrap();
        handle.set_memory_limit(10 * 1024 * 1024);
        let (tag, err) = handle.start();
        assert_eq!(tag, MontyProgressTag::Error);
        assert!(err.is_some());
        let result: Value = serde_json::from_str(handle.complete_result_json().unwrap()).unwrap();
        assert_eq!(result["print_output"], "boom\n");
    }

    #[test]
    fn test_resume_error_captures_print_no_limits() {
        // After resume, code raises an exception — exercises Err path in PausedNoLimit
        let code = "a = ext_fn(1)\nprint('resumed')\n1/0";
        let mut handle = MontyHandle::new(code.into(), vec!["ext_fn".into()], None).unwrap();
        let (tag, _) = handle.start();
        assert_eq!(tag, MontyProgressTag::Pending);

        let (tag, err) = handle.resume("42");
        assert_eq!(tag, MontyProgressTag::Error);
        assert!(err.is_some());
        let result: Value = serde_json::from_str(handle.complete_result_json().unwrap()).unwrap();
        assert_eq!(result["print_output"], "resumed\n");
    }

    #[test]
    fn test_resume_error_captures_print_with_limits() {
        // After resume, code raises — exercises Err path in PausedLimited
        let code = "a = ext_fn(1)\nprint('lim_resumed')\n1/0";
        let mut handle = MontyHandle::new(code.into(), vec!["ext_fn".into()], None).unwrap();
        handle.set_memory_limit(10 * 1024 * 1024);
        let (tag, _) = handle.start();
        assert_eq!(tag, MontyProgressTag::Pending);

        let (tag, err) = handle.resume("42");
        assert_eq!(tag, MontyProgressTag::Error);
        assert!(err.is_some());
        let result: Value = serde_json::from_str(handle.complete_result_json().unwrap()).unwrap();
        assert_eq!(result["print_output"], "lim_resumed\n");
    }

    #[test]
    fn test_run_error_captures_print() {
        let code = "print('err')\n1/0";
        let mut handle = MontyHandle::new(code.into(), vec![], None).unwrap();
        let (tag, result_json, err) = handle.run();
        assert_eq!(tag, MontyResultTag::Error);
        assert!(err.is_some());
        let parsed: Value = serde_json::from_str(&result_json).unwrap();
        assert_eq!(parsed["print_output"], "err\n");
    }

    #[test]
    fn test_run_error_with_limits_captures_print() {
        let code = "print('lim_err')\n1/0";
        let mut handle = MontyHandle::new(code.into(), vec![], None).unwrap();
        handle.set_memory_limit(10 * 1024 * 1024);
        let (tag, result_json, err) = handle.run();
        assert_eq!(tag, MontyResultTag::Error);
        assert!(err.is_some());
        let parsed: Value = serde_json::from_str(&result_json).unwrap();
        assert_eq!(parsed["print_output"], "lim_err\n");
    }

    // --- M7A.2: New accessor tests ---

    #[test]
    fn test_pending_kwargs_empty() {
        let code = "result = ext_fn(42)\nresult";
        let mut handle = MontyHandle::new(code.into(), vec!["ext_fn".into()], None).unwrap();
        let (tag, _) = handle.start();
        assert_eq!(tag, MontyProgressTag::Pending);
        assert_eq!(handle.pending_fn_kwargs_json(), Some("{}"));
        assert_eq!(handle.pending_call_id(), Some(0));
        assert_eq!(handle.pending_method_call(), Some(false));
    }

    #[test]
    fn test_pending_call_id_increments() {
        let code = "a = ext_fn(1)\nb = ext_fn(2)\na + b";
        let mut handle = MontyHandle::new(code.into(), vec!["ext_fn".into()], None).unwrap();
        let (tag, _) = handle.start();
        assert_eq!(tag, MontyProgressTag::Pending);
        let first_id = handle.pending_call_id().unwrap();

        let (tag, _) = handle.resume("10");
        assert_eq!(tag, MontyProgressTag::Pending);
        let second_id = handle.pending_call_id().unwrap();
        assert!(
            second_id > first_id,
            "call_id should increment: {second_id} > {first_id}"
        );
    }

    #[test]
    fn test_pending_accessors_wrong_state_new_fields() {
        let handle = MontyHandle::new("2 + 2".into(), vec![], None).unwrap();
        assert!(handle.pending_fn_kwargs_json().is_none());
        assert!(handle.pending_call_id().is_none());
        assert!(handle.pending_method_call().is_none());
    }

    #[test]
    fn test_script_name_default() {
        let mut handle = MontyHandle::new("1/0".into(), vec![], None).unwrap();
        let (tag, result_json, _) = handle.run();
        assert_eq!(tag, MontyResultTag::Error);
        let parsed: Value = serde_json::from_str(&result_json).unwrap();
        assert_eq!(parsed["error"]["filename"], "<input>");
    }

    #[test]
    fn test_script_name_custom() {
        let mut handle =
            MontyHandle::new("1/0".into(), vec![], Some("my_script.py".into())).unwrap();
        let (tag, result_json, _) = handle.run();
        assert_eq!(tag, MontyResultTag::Error);
        let parsed: Value = serde_json::from_str(&result_json).unwrap();
        assert_eq!(parsed["error"]["filename"], "my_script.py");
    }

    #[test]
    fn test_error_json_includes_exc_type() {
        let mut handle = MontyHandle::new("1/0".into(), vec![], None).unwrap();
        let (tag, result_json, _) = handle.run();
        assert_eq!(tag, MontyResultTag::Error);
        let parsed: Value = serde_json::from_str(&result_json).unwrap();
        assert_eq!(parsed["error"]["exc_type"], "ZeroDivisionError");
    }

    #[test]
    fn test_error_json_includes_traceback() {
        let mut handle = MontyHandle::new("1/0".into(), vec![], None).unwrap();
        let (_, result_json, _) = handle.run();
        let parsed: Value = serde_json::from_str(&result_json).unwrap();
        let traceback = parsed["error"]["traceback"].as_array();
        assert!(traceback.is_some(), "error should include traceback array");
        let frames = traceback.unwrap();
        assert!(
            !frames.is_empty(),
            "traceback should have at least one frame"
        );
        // Each frame should have required fields
        let frame = &frames[0];
        assert!(frame["filename"].is_string());
        assert!(frame["start_line"].is_number());
        assert!(frame["start_column"].is_number());
    }

    #[test]
    fn test_error_json_traceback_multi_frame() {
        let code = r#"
def inner():
    1/0

def outer():
    inner()

outer()
"#;
        let mut handle = MontyHandle::new(code.into(), vec![], None).unwrap();
        let (_, result_json, _) = handle.run();
        let parsed: Value = serde_json::from_str(&result_json).unwrap();
        let traceback = parsed["error"]["traceback"].as_array().unwrap();
        assert!(
            traceback.len() >= 3,
            "should have at least 3 frames (module, outer, inner): got {}",
            traceback.len()
        );
        assert_eq!(parsed["error"]["exc_type"], "ZeroDivisionError");
    }

    #[test]
    fn test_error_json_value_error_exc_type() {
        let code = "int('abc')";
        let mut handle = MontyHandle::new(code.into(), vec![], None).unwrap();
        let (_, result_json, _) = handle.run();
        let parsed: Value = serde_json::from_str(&result_json).unwrap();
        assert_eq!(parsed["error"]["exc_type"], "ValueError");
    }

    #[test]
    fn test_script_name_in_traceback() {
        let mut handle = MontyHandle::new("1/0".into(), vec![], Some("test.py".into())).unwrap();
        let (_, result_json, _) = handle.run();
        let parsed: Value = serde_json::from_str(&result_json).unwrap();
        let traceback = parsed["error"]["traceback"].as_array().unwrap();
        assert_eq!(traceback[0]["filename"], "test.py");
    }

    // --- M13: Async/Futures tests ---

    fn async_code_single() -> &'static str {
        "async def main():\n  result = await fetch('x')\n  return result\n\nawait main()"
    }

    fn async_code_gather() -> &'static str {
        "import asyncio\n\nasync def main():\n  a, b = await asyncio.gather(foo(), bar())\n  return a + b\n\nawait main()"
    }

    #[test]
    fn test_async_single_await_via_handle() {
        let mut handle =
            MontyHandle::new(async_code_single().into(), vec!["fetch".into()], None).unwrap();
        let (tag, _) = handle.start();
        assert_eq!(tag, MontyProgressTag::Pending);
        assert_eq!(handle.pending_fn_name(), Some("fetch"));

        let (tag, _) = handle.resume_as_future();
        assert_eq!(tag, MontyProgressTag::ResolveFutures);

        let call_ids = handle.pending_future_call_ids().unwrap();
        let ids: Vec<u32> = serde_json::from_str(call_ids).unwrap();
        assert_eq!(ids.len(), 1);

        let results = format!("{{\"{}\":\"response_x\"}}", ids[0]);
        let (tag, _) = handle.resume_futures(&results, "{}");
        assert_eq!(tag, MontyProgressTag::Complete);

        let result: Value = serde_json::from_str(handle.complete_result_json().unwrap()).unwrap();
        assert_eq!(result["value"], "response_x");
    }

    #[test]
    fn test_async_gather_via_handle() {
        let mut handle = MontyHandle::new(
            async_code_gather().into(),
            vec!["foo".into(), "bar".into()],
            None,
        )
        .unwrap();

        let (tag, _) = handle.start();
        assert_eq!(tag, MontyProgressTag::Pending);
        let id0 = handle.pending_call_id().unwrap();
        let (tag, _) = handle.resume_as_future();
        assert_eq!(tag, MontyProgressTag::Pending);
        let id1 = handle.pending_call_id().unwrap();
        let (tag, _) = handle.resume_as_future();
        assert_eq!(tag, MontyProgressTag::ResolveFutures);

        let call_ids = handle.pending_future_call_ids().unwrap();
        let ids: Vec<u32> = serde_json::from_str(call_ids).unwrap();
        assert_eq!(ids.len(), 2);

        let results = format!("{{\"{}\":10,\"{}\":32}}", id0, id1);
        let (tag, _) = handle.resume_futures(&results, "{}");
        assert_eq!(tag, MontyProgressTag::Complete);

        let result: Value = serde_json::from_str(handle.complete_result_json().unwrap()).unwrap();
        assert_eq!(result["value"], 42);
    }

    #[test]
    fn test_async_gather_with_error_via_handle() {
        let mut handle = MontyHandle::new(
            async_code_gather().into(),
            vec!["foo".into(), "bar".into()],
            None,
        )
        .unwrap();

        let (tag, _) = handle.start();
        assert_eq!(tag, MontyProgressTag::Pending);
        let id0 = handle.pending_call_id().unwrap();
        let (tag, _) = handle.resume_as_future();
        assert_eq!(tag, MontyProgressTag::Pending);
        let id1 = handle.pending_call_id().unwrap();
        let (tag, _) = handle.resume_as_future();
        assert_eq!(tag, MontyProgressTag::ResolveFutures);

        let results = format!("{{\"{}\":10}}", id0);
        let errors = format!("{{\"{}\":\"bar failed\"}}", id1);
        let (tag, _) = handle.resume_futures(&results, &errors);
        assert_eq!(tag, MontyProgressTag::Error);
        assert_eq!(handle.complete_is_error(), Some(true));
    }

    #[test]
    fn test_async_future_call_ids_wrong_state() {
        let handle = MontyHandle::new("2 + 2".into(), vec![], None).unwrap();
        assert!(handle.pending_future_call_ids().is_none());
    }

    #[test]
    fn test_resume_futures_wrong_state() {
        let mut handle = MontyHandle::new("2 + 2".into(), vec![], None).unwrap();
        let (tag, err) = handle.resume_futures("{}", "{}");
        assert_eq!(tag, MontyProgressTag::Error);
        assert!(err.unwrap().contains("not in Futures state"));
    }

    #[test]
    fn test_resume_as_future_wrong_state() {
        let mut handle = MontyHandle::new("2 + 2".into(), vec![], None).unwrap();
        let (tag, err) = handle.resume_as_future();
        assert_eq!(tag, MontyProgressTag::Error);
        assert!(err.unwrap().contains("not in Paused state"));
    }

    #[test]
    fn test_resume_futures_invalid_json() {
        let mut handle =
            MontyHandle::new(async_code_single().into(), vec!["fetch".into()], None).unwrap();
        let (tag, _) = handle.start();
        assert_eq!(tag, MontyProgressTag::Pending);
        let (tag, _) = handle.resume_as_future();
        assert_eq!(tag, MontyProgressTag::ResolveFutures);

        let (tag, err) = handle.resume_futures("not json", "{}");
        assert_eq!(tag, MontyProgressTag::Error);
        assert!(err.unwrap().contains("invalid results JSON"));
    }

    #[test]
    fn test_async_with_limits() {
        let mut handle =
            MontyHandle::new(async_code_single().into(), vec!["fetch".into()], None).unwrap();
        handle.set_memory_limit(10 * 1024 * 1024);
        handle.set_time_limit_ms(5000);

        let (tag, _) = handle.start();
        assert_eq!(tag, MontyProgressTag::Pending);
        let id = handle.pending_call_id().unwrap();

        let (tag, _) = handle.resume_as_future();
        assert_eq!(tag, MontyProgressTag::ResolveFutures);

        let results = format!("{{\"{id}\":\"limited_response\"}}");
        let (tag, _) = handle.resume_futures(&results, "{}");
        assert_eq!(tag, MontyProgressTag::Complete);

        let result: Value = serde_json::from_str(handle.complete_result_json().unwrap()).unwrap();
        assert_eq!(result["value"], "limited_response");
    }

    // --- Cancel tests ---

    #[test]
    fn test_cancel_before_run_returns_error() {
        // Cancel flag set before run() — returns clean error without
        // consuming Ready state. Handle remains reusable after reset.
        let mut handle = MontyHandle::new("2 + 2".into(), vec![], None).unwrap();
        handle.cancel();
        assert!(handle.is_cancelled());
        let (tag, result_json, err) = handle.run();
        assert_eq!(tag, MontyResultTag::Error);
        assert!(err.unwrap().contains("KeyboardInterrupt"));
        let parsed: Value = serde_json::from_str(&result_json).unwrap();
        assert_eq!(parsed["error"]["exc_type"], "KeyboardInterrupt");
    }

    #[test]
    fn test_cancel_before_start_returns_error() {
        let mut handle = MontyHandle::new("2 + 2".into(), vec![], None).unwrap();
        handle.cancel();
        let (tag, err) = handle.start();
        assert_eq!(tag, MontyProgressTag::Error);
        assert!(err.unwrap().contains("KeyboardInterrupt"));
    }

    #[test]
    fn test_cancel_before_run_reusable_after_reset() {
        // Cancel-before-run should NOT brick the handle. After reset,
        // the handle must still be in Ready state and execute normally.
        let mut handle = MontyHandle::new("2 + 2".into(), vec![], None).unwrap();
        handle.cancel();
        let (tag, _, _) = handle.run();
        assert_eq!(tag, MontyResultTag::Error);
        // Handle is still Ready — reset and run again
        handle.reset_cancel();
        let (tag, result_json, err) = handle.run();
        assert_eq!(tag, MontyResultTag::Ok);
        assert!(err.is_none());
        let parsed: Value = serde_json::from_str(&result_json).unwrap();
        assert_eq!(parsed["value"], json!(4));
    }

    #[test]
    fn test_cancel_before_start_reusable_after_reset() {
        let mut handle = MontyHandle::new("2 + 2".into(), vec![], None).unwrap();
        handle.cancel();
        let (tag, _) = handle.start();
        assert_eq!(tag, MontyProgressTag::Error);
        // Still Ready — reset and start again
        handle.reset_cancel();
        let (tag, err) = handle.start();
        assert_eq!(tag, MontyProgressTag::Complete);
        assert!(err.is_none());
    }

    #[test]
    fn test_cancel_reset_allows_reuse() {
        let mut handle = MontyHandle::new("2 + 2".into(), vec![], None).unwrap();
        handle.cancel();
        assert!(handle.is_cancelled());
        handle.reset_cancel();
        assert!(!handle.is_cancelled());
        let (tag, _, err) = handle.run();
        assert_eq!(tag, MontyResultTag::Ok);
        assert!(err.is_none());
    }

    #[test]
    fn test_cancel_is_idempotent() {
        let handle = MontyHandle::new("2 + 2".into(), vec![], None).unwrap();
        handle.cancel();
        handle.cancel();
        assert!(handle.is_cancelled());
    }

    #[test]
    fn test_handle_id_is_unique() {
        let h1 = MontyHandle::new("1".into(), vec![], None).unwrap();
        let h2 = MontyHandle::new("2".into(), vec![], None).unwrap();
        assert_ne!(h1.handle_id(), h2.handle_id());
    }

    #[test]
    fn test_cancel_by_id_success() {
        let handle = MontyHandle::new("2 + 2".into(), vec![], None).unwrap();
        let id = handle.handle_id();
        assert!(!handle.is_cancelled());
        let result = cancel_by_id(id);
        assert_eq!(result, 0);
        assert!(handle.is_cancelled());
    }

    #[test]
    fn test_cancel_by_id_after_free() {
        let id = {
            let handle = MontyHandle::new("2 + 2".into(), vec![], None).unwrap();
            handle.handle_id()
        };
        // Handle dropped, registry cleaned up by Drop impl
        let result = cancel_by_id(id);
        assert_eq!(result, -1);
    }

    #[test]
    fn test_cancel_by_id_not_found() {
        let result = cancel_by_id(999_999_999);
        assert_eq!(result, -1);
    }

    #[test]
    fn test_is_cancelled_by_id() {
        let handle = MontyHandle::new("2 + 2".into(), vec![], None).unwrap();
        let id = handle.handle_id();
        assert_eq!(is_cancelled_by_id(id), 0);
        handle.cancel();
        assert_eq!(is_cancelled_by_id(id), 1);
    }

    #[test]
    fn test_is_cancelled_by_id_not_found() {
        assert_eq!(is_cancelled_by_id(999_999_999), -1);
    }

    #[test]
    fn test_cancel_by_id_no_aba() {
        // Create handle, get its ID, drop it. Create a new handle — its ID
        // must be different (monotonic counter), proving no ABA.
        let old_id = {
            let h = MontyHandle::new("1".into(), vec![], None).unwrap();
            h.handle_id()
        };
        let new_handle = MontyHandle::new("2".into(), vec![], None).unwrap();
        let new_id = new_handle.handle_id();
        assert_ne!(old_id, new_id, "handle IDs must not be reused (ABA)");
        // Old ID should be gone from registry
        assert_eq!(cancel_by_id(old_id), -1);
        // New ID should work
        assert_eq!(cancel_by_id(new_id), 0);
        assert!(new_handle.is_cancelled());
    }

    #[test]
    fn test_cancel_does_not_affect_snapshot() {
        let handle = MontyHandle::new("2 + 2".into(), vec![], None).unwrap();
        handle.cancel();
        // Snapshot should still work (cancel flag is not serialized)
        let bytes = handle.snapshot().unwrap();
        let mut restored = MontyHandle::restore(&bytes).unwrap();
        // Restored handle should NOT be cancelled
        assert!(!restored.is_cancelled());
        let (tag, _, _) = restored.run();
        assert_eq!(tag, MontyResultTag::Ok);
    }

    #[test]
    fn test_cancel_with_limits() {
        // Both cancel flag and time limit active — cancel guard fires first,
        // returns clean error without entering heap setup.
        let mut handle = MontyHandle::new("2 + 2".into(), vec![], None).unwrap();
        handle.set_time_limit_ms(60_000);
        handle.cancel();
        let (tag, _, err) = handle.run();
        assert_eq!(tag, MontyResultTag::Error);
        assert!(err.unwrap().contains("KeyboardInterrupt"));
        // Still reusable after reset
        handle.reset_cancel();
        let (tag, _, err) = handle.run();
        assert_eq!(tag, MontyResultTag::Ok);
        assert!(err.is_none());
    }

    #[test]
    fn test_restored_handle_has_unique_id() {
        let handle = MontyHandle::new("2 + 2".into(), vec![], None).unwrap();
        let bytes = handle.snapshot().unwrap();
        let restored = MontyHandle::restore(&bytes).unwrap();
        assert_ne!(
            handle.handle_id(),
            restored.handle_id(),
            "restored handle must get a new ID"
        );
    }

    #[test]
    fn test_cancel_during_long_running_script() {
        // A long-running script that would take forever without cancel.
        // We cancel via the registry from another thread.
        use std::thread;

        let code = "i = 0\nwhile True:\n  i += 1\ni";
        let mut handle = MontyHandle::new(code.into(), vec![], None).unwrap();
        let id = handle.handle_id();

        // Spawn a thread that cancels after a very short time
        let cancel_thread = thread::spawn(move || {
            thread::sleep(std::time::Duration::from_millis(5));
            let result = cancel_by_id(id);
            assert_eq!(result, 0);
        });

        let (tag, _, err) = handle.run();
        cancel_thread.join().unwrap();

        // The script should have been interrupted
        assert_eq!(tag, MontyResultTag::Error);
        assert!(err.is_some());
    }

    #[test]
    fn test_cancel_before_start_with_ext_fn() {
        let code = "result = ext_fn(1)\nresult";
        let mut handle = MontyHandle::new(code.into(), vec!["ext_fn".into()], None).unwrap();
        handle.cancel();
        let (tag, err) = handle.start();
        assert_eq!(tag, MontyProgressTag::Error);
        assert!(err.unwrap().contains("KeyboardInterrupt"));
    }

    #[test]
    fn test_registry_lock_poisoning_recovery() {
        // Design doc §5: poison the RwLock via panic in a test thread,
        // then verify cancel_by_id still works via into_inner() recovery.
        use std::thread;

        let handle = MontyHandle::new("2 + 2".into(), vec![], None).unwrap();
        let id = handle.handle_id();

        // Poison the write lock by panicking while holding it
        let poison_result = thread::spawn(|| {
            let mut guard = CANCEL_REGISTRY.write().unwrap();
            guard.insert(0, Weak::new()); // do something with the guard
            panic!("intentional poison");
        })
        .join();
        assert!(poison_result.is_err(), "thread should have panicked");

        // RwLock is now poisoned — verify our recovery works
        assert!(CANCEL_REGISTRY.read().is_err(), "lock should be poisoned");

        // cancel_by_id must still work (uses unwrap_or_else into_inner)
        let result = cancel_by_id(id);
        assert_eq!(result, 0, "cancel_by_id must recover from poisoned lock");
        assert!(handle.is_cancelled());

        // is_cancelled_by_id must also recover
        assert_eq!(is_cancelled_by_id(id), 1);
    }
}
