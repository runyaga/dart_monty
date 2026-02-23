# API Gap Demonstrations

Eleven capabilities that are **impossible** with the current dart_monty
API but would work if we closed the gaps identified in
`api-coverage-plan.md`.

---

## Demo 1: Interactive Python Console (REPL API)

**Blocked by:** Missing REPL API (Tier 2, Item 7)

An interactive console where each line the user types builds on the
previous state — variables persist, functions stay defined, errors don't
destroy the session.

**Python session the user wants to run:**

```python
>>> x = 10
>>> x * 2
20
>>> def greet(name):
...     return f"Hello, {name}!"
>>> greet("Flutter")
'Hello, Flutter!'
>>> 1 / 0          # error — but session survives
ZeroDivisionError: division by zero
>>> x              # still 10
10
```

**Dart code that would need to exist:**

```dart
// Create a persistent REPL session
final repl = await MontyRepl.create();

// Feed lines incrementally — state accumulates
final r1 = await repl.feed('x = 10');            // MontyObject: None
final r2 = await repl.feed('x * 2');             // MontyObject: 20
final r3 = await repl.feed('''
def greet(name):
    return f"Hello, {name}!"
''');
final r4 = await repl.feed('greet("Flutter")');  // MontyObject: "Hello, Flutter!"

// Errors preserve session state
try {
  await repl.feed('1 / 0');
} on MontyException catch (e) {
  print(e.excType);  // "ZeroDivisionError"
  // Session is NOT destroyed — repl is still usable
}

final r5 = await repl.feed('x');  // MontyObject: 10 — state survived

// Snapshot the REPL for later
final bytes = await repl.dump();
// ... days later ...
final restored = await MontyRepl.load(bytes);
final r6 = await restored.feed('x + 1');  // 11
```

**Why it fails today:** `MontyPlatform` only supports `run()` (stateless)
and `start()`/`resume()` (iterative but single-script). There is no way
to feed multiple independent code snippets into a persistent namespace.
Every `run()` call starts from scratch — variables from previous calls
are gone.

**Use cases unlocked:** AI agent tool loops (LLM feeds code
incrementally), educational Python REPLs, notebook-style execution cells.

---

## Demo 2: Concurrent Async HTTP with Python await (Futures API)

**Blocked by:** Missing Async/Futures API (Tier 2, Item 8) + missing
call_id (Tier 1, Item 6)

Python code that uses `async`/`await` with `asyncio.gather` to make
multiple external calls concurrently, with the Dart host acting as the
event loop.

**Python code:**

```python
import asyncio

async def fetch_all():
    # These three calls should happen concurrently on the host side
    a, b, c = await asyncio.gather(
        fetch("https://api.example.com/users"),
        fetch("https://api.example.com/posts"),
        fetch("https://api.example.com/comments"),
    )
    return {"users": len(a), "posts": len(b), "comments": len(c)}

result = await fetch_all()
```

**Dart code that would need to exist:**

```dart
final monty = MontyPlatform.instance;
var progress = await monty.start(
  pythonCode,
  externalFunctions: ['fetch'],
);

while (progress is! MontyComplete) {
  if (progress is MontyPending) {
    // Single external function call — resolve it
    final url = progress.arguments.first as String;
    final response = await http.get(Uri.parse(url));
    progress = await monty.resume(response.body);

  } else if (progress is MontyResolveFutures) {
    // Multiple concurrent futures — resolve them in parallel!
    final pendingIds = progress.pendingCallIds; // [1, 2, 3]
    final results = await Future.wait(
      pendingIds.map((id) async {
        // Host knows which call_id maps to which URL
        final response = await http.get(Uri.parse(urlForCallId[id]!));
        return MapEntry(id, response.body);
      }),
    );
    progress = await monty.resolveFutures(
      Map.fromEntries(results),
    );
  }
}
```

**Why it fails today:** When Python calls `asyncio.gather(fetch(...),
fetch(...), fetch(...))`, the VM yields `ResolveFutures` — a progress
variant that dart_monty doesn't recognize. The execution simply fails or
hangs. There is also no `call_id` on `MontyPending`, so even if we could
receive multiple pending calls, we couldn't correlate responses back to
the correct Python awaitable.

**Use cases unlocked:** Parallel API calls from sandboxed Python, async
tool execution in AI agents, concurrent data fetching pipelines.

---

## Demo 3: Rich Error Diagnostics (Full Tracebacks + Exception Types)

**Blocked by:** Missing full tracebacks (Tier 1, Item 2) + missing
exception types (Tier 1, Item 3)

Display a proper multi-frame Python traceback with syntax highlighting,
programmatically handle different exception types, and show the exact
code that failed at each call level.

**Python code:**

```python
def validate_age(age):
    if age < 0:
        raise ValueError("Age cannot be negative")
    return age

def process_user(data):
    name = data["name"]
    age = validate_age(data["age"])
    return f"{name} is {age} years old"

process_user({"name": "Alice", "age": -5})
```

**Dart code that would need to exist:**

```dart
final result = await monty.run(pythonCode);

if (!result.isSuccess) {
  final ex = result.error!;

  // Programmatic exception type dispatch
  switch (ex.excType) {
    case ExcType.valueError:
      showUserFriendlyValidationError(ex.message);
    case ExcType.typeError:
      showTypeMismatchDialog(ex.message);
    case ExcType.syntaxError:
      highlightSyntaxError(ex.lineNumber, ex.columnNumber);
    default:
      showGenericError(ex.message);
  }

  // Render full traceback (3 frames deep)
  for (final frame in ex.traceback) {
    print('  File "${frame.filename}", line ${frame.start.line}, '
        'in ${frame.frameName ?? "<module>"}');
    if (frame.previewLine != null) {
      print('    ${frame.previewLine}');
      // Show caret pointing to exact column
      if (!frame.hideCaret) {
        print('    ${" " * frame.start.column}^');
      }
    }
  }
  // Output:
  //   File "script.py", line 11, in <module>
  //     process_user({"name": "Alice", "age": -5})
  //   File "script.py", line 8, in process_user
  //     age = validate_age(data["age"])
  //   File "script.py", line 3, in validate_age
  //     raise ValueError("Age cannot be negative")
  //                       ^
}
```

**Why it fails today:** `MontyException` only has a flat `message` string
and a single `filename`/`lineNumber`/`columnNumber` from the top frame.
There is no `excType` field — you cannot distinguish `ValueError` from
`TypeError` without parsing the message string. There is no `traceback`
list — you only see where the error was raised, not the chain of calls
that led there.

**Use cases unlocked:** IDE-quality error display, programmatic error
handling in agent loops (retry on timeout, fail on type error), debugging
tools, educational error explanations.

---

## Demo 4: Agent Tool Call with Keyword Arguments (kwargs)

**Blocked by:** Missing kwargs (Tier 1, Item 1) + missing method_call
flag (Tier 1, Item 6)

An AI agent writes Python that calls external tools using keyword
arguments — the natural Python calling convention for named parameters.

**Python code (written by an LLM agent):**

```python
# Agent-generated tool calls using natural Python kwargs
result = db_query(
    table="users",
    where="age > 21",
    order_by="name",
    limit=10,
)

# Method-style call on a returned object
chart = result.plot(
    x="name",
    y="age",
    kind="bar",
    title="Users Over 21",
)

# Mixed positional + keyword
send_email(
    "alice@example.com",          # positional: to
    subject="Query Results",      # keyword
    body=format_table(result),    # keyword with nested call
    priority="high",              # keyword
)
```

**Dart code that would need to exist:**

```dart
var progress = await monty.start(agentCode, externalFunctions: [
  'db_query', 'send_email', 'format_table',
]);

while (progress is MontyPending) {
  final pending = progress as MontyPending;
  final name = pending.functionName;
  final args = pending.arguments;   // positional args
  final kwargs = pending.kwargs;    // keyword args!
  final isMethod = pending.methodCall; // true for result.plot(...)

  switch (name) {
    case 'db_query':
      // kwargs: {"table": "users", "where": "age > 21", ...}
      final table = kwargs['table'] as String;
      final where = kwargs['where'] as String;
      final orderBy = kwargs['order_by'] as String?;
      final limit = kwargs['limit'] as int?;
      final rows = await database.query(table, where, orderBy, limit);
      progress = await monty.resume(rows);

    case 'send_email':
      // args[0]: "alice@example.com" (positional)
      // kwargs: {"subject": "...", "body": "...", "priority": "high"}
      await emailService.send(
        to: args[0] as String,
        subject: kwargs['subject'] as String,
        body: kwargs['body'] as String,
      );
      progress = await monty.resume(null);
  }
}
```

**Why it fails today:** `MontyPending.arguments` is a `List<Object?>`
containing only positional arguments. All keyword arguments are silently
dropped by the C FFI and JS bridges. If an LLM writes
`db_query(table="users", where="age > 21")`, Dart receives an empty
arguments list — the table name and where clause are simply lost. There
is also no `methodCall` flag to distinguish `result.plot(...)` from a
top-level `plot(...)` call.

**Use cases unlocked:** Natural Python-style tool calling for AI agents,
any external function API that uses keyword arguments (which is most of
Python's ecosystem convention).

---

## Demo 5: Static Type Checking Before Execution (ty Integration)

**Blocked by:** Missing type checking API (Tier 3, Item 11)

Monty ships with [ty](https://docs.astral.sh/ty/) (Astral's Python type
checker, formerly Red Knot) built into its binary. The JS bindings
expose `Monty.typeCheck(prefixCode?)` and the Rust crate
`monty-type-checking` provides `type_check(source, stubs?)`. This lets
the host catch type errors *before* execution — crucial for AI agent
loops where an LLM generates Python code that should be validated before
running.

**Python code (generated by an LLM):**

```python
def calculate_total(prices: list[float], tax_rate: float) -> float:
    subtotal = sum(prices)
    tax = subtotal * tax_rate
    return subtotal + tax

# Bug: passing string instead of float
result = calculate_total([10.0, 20.0, "thirty"], 0.08)
```

**Dart code that would need to exist:**

```dart
final monty = MontyPlatform.instance;

// Type-check before execution — catch errors without running
final diagnostics = await monty.typeCheck(
  agentGeneratedCode,
  // Optional: provide stubs declaring external function signatures
  stubs: '''
def fetch(url: str) -> str: ...
def db_query(table: str, where: str = "") -> list[dict]: ...
''',
  format: DiagnosticFormat.json,  // or .full, .concise, .github
);

if (diagnostics != null) {
  // Type errors found — don't execute, send back to LLM for fixing
  for (final error in diagnostics.errors) {
    print('${error.filename}:${error.line}: ${error.message}');
    // script.py:7: Argument of type "str" is not assignable to
    //   parameter "prices" of type "list[float]"
    //     "thirty" is incompatible with "float"
  }

  // Send diagnostics back to the LLM for self-correction
  final fixedCode = await llm.chat(
    'Fix these type errors in the Python code:\n'
    '${diagnostics.formatted}\n\n'
    'Original code:\n$agentGeneratedCode',
  );

  // Re-check the fixed code
  final recheck = await monty.typeCheck(fixedCode, stubs: stubs);
  if (recheck == null) {
    // Clean — now safe to execute
    final result = await monty.run(fixedCode);
  }
} else {
  // No type errors — execute directly
  final result = await monty.run(agentGeneratedCode);
}
```

**Why it fails today:** dart_monty has no `typeCheck()` method. The
upstream Rust crate `monty-type-checking` provides `type_check(source,
stubs?)` returning `TypeCheckingDiagnostics` with multiple output
formats (full, concise, JSON, GitHub Actions, etc.). The JS bindings
expose it as `Monty.typeCheck(prefixCode?)`. dart_monty skips this
entirely — code goes straight to execution, and type errors only surface
as runtime exceptions (if they surface at all).

**Use cases unlocked:** LLM agent code validation loops (type-check ->
fix -> re-check -> execute), IDE-quality inline diagnostics in Flutter
code editors, CI-style gating for user-submitted Python, teaching tools
that explain type errors before they become runtime crashes.

---

## Demo 6: Live Execution Streaming with Real-Time Print Output

**Blocked by:** Missing live print streaming (Tier 1, Item 5) +
missing progress serialization (Tier 2, Item 10)

A long-running Python computation that streams its progress to the UI in
real-time, with the ability to suspend and resume across app restarts.

**Python code:**

```python
import asyncio

print("Starting training pipeline...")

for epoch in range(100):
    loss = train_epoch(epoch)
    accuracy = evaluate()
    print(f"Epoch {epoch}: loss={loss:.4f}, accuracy={accuracy:.2%}")

    if epoch % 10 == 9:
        checkpoint = snapshot_state()
        save_checkpoint(checkpoint, epoch)
        print(f"  Checkpoint saved at epoch {epoch}")

print(f"Training complete! Final accuracy: {accuracy:.2%}")
```

**Dart code that would need to exist:**

```dart
final monty = MontyPlatform.instance;

// Start with a live print callback
var progress = await monty.start(
  trainingCode,
  externalFunctions: ['train_epoch', 'evaluate', ...],
  onPrint: (String text) {
    // Called in REAL-TIME as each print() executes
    setState(() {
      _consoleLines.add(text);
    });
    // UI updates live:
    // "Starting training pipeline..."
    // "Epoch 0: loss=2.3401, accuracy=12.50%"
    // "Epoch 1: loss=1.8723, accuracy=34.20%"
    // ...
  },
);

// Process external function calls
while (progress is MontyPending) {
  final pending = progress as MontyPending;

  if (pending.functionName == 'save_checkpoint') {
    // Serialize entire execution state for crash recovery
    final stateBytes = await monty.dumpProgress();
    await File('checkpoint.bin').writeAsBytes(stateBytes);
    progress = await monty.resume(null);
  } else {
    // Handle train_epoch, evaluate, etc.
    final result = await dispatchTool(pending);
    progress = await monty.resume(result);
  }
}

// --- After app restart, resume from checkpoint ---
final savedBytes = await File('checkpoint.bin').readAsBytes();
final restored = await MontyPlatform.loadProgress(savedBytes);
// Continues from epoch 90, not epoch 0!
```

**Why it fails today:** Print output is only available in
`MontyResult.printOutput` *after* execution completes (or pauses at an
external call). During a long computation with many `print()` calls, the
UI shows nothing until the entire run finishes. There is no `onPrint`
callback. Additionally, `RunProgress::dump/load` is not exposed, so
there is no way to serialize the in-flight execution state for
suspend/resume across process restarts.

**Use cases unlocked:** Long-running computations with live progress,
training/simulation dashboards, crash-recoverable execution, background
task migration between devices.

---

## Demo 7: Sandboxed Environment & File System Access (OS Calls)

**Blocked by:** Missing OS Calls API (Tier 2, Item 9)

Python code that reads environment variables and checks file metadata
through the sandbox — the host decides what values to expose, maintaining
full control over what the sandboxed code can see.

**Python code:**

```python
import os

# Read environment configuration
db_host = os.getenv("DATABASE_URL", "localhost:5432")
api_key = os.environ["API_KEY"]
debug = os.getenv("DEBUG", "false") == "true"

# Check if a config file exists
config_stat = os.stat("/app/config.yaml")
print(f"Config size: {config_stat.st_size} bytes")
print(f"Last modified: {config_stat.st_mtime}")

# Build connection string
if debug:
    print(f"Connecting to {db_host} (debug mode)")
conn = f"postgresql://{db_host}?sslmode={'disable' if debug else 'require'}"
```

**Dart code that would need to exist:**

```dart
// Define a virtual environment — the sandbox sees ONLY what we expose
final virtualEnv = {
  'DATABASE_URL': 'prod-db.internal:5432',
  'API_KEY': 'sk-live-abc123',
  'DEBUG': 'false',
};

// Define virtual file stats
final virtualFs = {
  '/app/config.yaml': FileStat(size: 2048, modified: DateTime(2025, 6, 1)),
};

var progress = await monty.start(pythonCode);

while (progress is MontyPending) {
  final pending = progress as MontyPending;

  if (pending is MontyOsCall) {
    switch (pending.osFunction) {
      case OsFunction.getenv:
        final key = pending.arguments[0] as String;
        final defaultVal = pending.arguments.length > 1
            ? pending.arguments[1]
            : null;
        final value = virtualEnv[key] ?? defaultVal;
        progress = await monty.resume(value);

      case OsFunction.environ:
        // Return the entire virtual environment
        progress = await monty.resume(virtualEnv);

      case OsFunction.fileStat:
        final path = pending.arguments[0] as String;
        final stat = virtualFs[path];
        if (stat == null) {
          progress = await monty.resumeWithError(
            'FileNotFoundError: $path',
          );
        } else {
          progress = await monty.resume(stat.toMap());
        }
    }
  }
}
```

**Why it fails today:** When Python code calls `os.getenv()` or
`os.stat()`, monty yields `RunProgress::OsCall` — a progress variant
that dart_monty doesn't handle. The execution fails with an unrecognized
progress state. There is no `MontyOsCall` class, no `OsFunction` enum,
and no way for the host to intercept and respond to OS-level requests.

**Use cases unlocked:** Sandboxed configuration loading (expose only
safe env vars), virtual filesystem for agent code, policy-controlled
access to system metadata, multi-tenant isolation where each tenant sees
different environment variables.

---

## Demo 8: Structured Data Round-Trip (Rich MontyObject Types)

**Blocked by:** Missing rich type preservation (Tier 3, Item 12)

Python returns structured data using dataclasses, named tuples, and sets
— but Dart receives generic Maps and Lists with all type identity lost.

**Python code:**

```python
from dataclasses import dataclass

@dataclass(frozen=True)
class Point:
    x: float
    y: float

@dataclass
class GeoFence:
    name: str
    vertices: list[Point]
    tags: frozenset[str]

fence = GeoFence(
    name="Downtown",
    vertices=[Point(1.0, 2.0), Point(3.0, 4.0), Point(5.0, 6.0)],
    tags=frozenset({"restricted", "monitored", "active"}),
)

# Also return a set and a tuple for variety
unique_ids = {101, 202, 303, 202}  # set — deduplicates
dimensions = (1920, 1080)           # tuple — immutable, fixed-length

result = (fence, unique_ids, dimensions)
```

**Dart code that would need to exist:**

```dart
final result = await monty.run(pythonCode);
final value = result.value as MontyTuple;  // typed! not just List

final fence = value[0] as MontyDataclass;
print(fence.name);        // "GeoFence"
print(fence.frozen);      // true (immutable)
print(fence.fieldNames);  // ["name", "vertices", "tags"]
print(fence['name']);      // "Downtown"

final vertices = fence['vertices'] as MontyList;
final point = vertices[0] as MontyDataclass;
print(point.name);    // "Point"
print(point['x']);     // 1.0
print(point['y']);     // 2.0

final tags = fence['tags'] as MontyFrozenSet;
print(tags.contains('restricted'));  // true
print(tags.length);                  // 3

final ids = value[1] as MontySet;
print(ids.length);  // 3 (deduped: 202 appears once)

final dims = value[2] as MontyTuple;
print(dims.length);  // 2 — and it's explicitly a tuple, not a list
```

**Why it fails today:** The C FFI serializes `MontyObject` to JSON,
but our bridge discards upstream type tags (`$tuple`, `$set`,
`$frozenset`, `$bytes`). Dataclass fields (`name`, `type_id`, `frozen`,
`field_names`) are lost — everything collapses to `Map<String, dynamic>`.
Sets become `List` (duplicates may re-appear if roundtripped). Tuples
become `List` (indistinguishable from mutable lists). There is no
`MontyDataclass`, `MontySet`, `MontyFrozenSet`, or `MontyTuple` type
in Dart.

**Use cases unlocked:** Schema-aware data exchange between Python and
Dart, structural pattern matching on return types, preserving immutability
contracts (frozen dataclass, frozenset), set-based deduplication that
survives the bridge.

---

## Demo 9: Multi-Tenant Resource Budgets (Fine-Grained Limits)

**Blocked by:** Missing `max_allocations`, `gc_interval`,
`set_max_duration` (Tier 3, Item 13)

A multi-tenant platform where each user gets different resource budgets —
free-tier users get tight limits, paid users get generous ones, and the
host can re-arm time limits between external call phases.

**Python code (potentially hostile, from untrusted user):**

```python
# Attempt to exhaust memory via allocation spam
data = []
for i in range(10_000_000):
    data.append({f"key_{i}": [i] * 100})
```

**Dart code that would need to exist:**

```dart
// Free-tier user: tight budget
final freeLimits = MontyLimits(
  memoryBytes: 10 * 1024 * 1024,   // 10 MB
  time: Duration(seconds: 5),
  stackDepth: 50,
  maxAllocations: 100_000,          // cap total heap objects
  gcInterval: 1_000,                // GC every 1000 allocations
);

// Paid-tier user: generous budget
final paidLimits = MontyLimits(
  memoryBytes: 256 * 1024 * 1024,   // 256 MB
  time: Duration(seconds: 60),
  stackDepth: 200,
  maxAllocations: 10_000_000,
  gcInterval: 50_000,
);

// Execute with the appropriate budget
final result = await monty.run(userCode, limits: freeLimits);

if (!result.isSuccess) {
  final error = result.error!;
  // Programmatic resource-exceeded detection
  if (error.excType == 'MemoryError') {
    showUpgradePrompt('Memory limit reached. Upgrade for 256 MB.');
  } else if (error.excType == 'TimeoutError') {
    showUpgradePrompt('Execution timed out. Upgrade for 60s limit.');
  }
}

// For iterative execution: re-arm time limit between phases
var progress = await monty.start(longRunningCode, limits: paidLimits);
while (progress is MontyPending) {
  // External call might take 30 seconds (network I/O)
  final result = await slowExternalCall(progress);
  // Re-arm the Python-side time limit so the NEXT phase gets a fresh 60s
  await monty.setMaxDuration(Duration(seconds: 60));
  progress = await monty.resume(result);
}
```

**Why it fails today:** `MontyLimits` only exposes 3 of 5
`ResourceLimits` fields: `memoryBytes`, `time`, and `stackDepth`. The
`maxAllocations` field is missing, so there is no way to cap the total
number of heap objects (a common DoS vector in sandboxes).
`gcInterval` is missing, so the host cannot tune how often garbage
collection runs. `LimitedTracker::set_max_duration` is not exposed, so
time limits cannot be re-armed between iterative execution phases — if
an external call takes 30 seconds of wall-clock time, that counts
against the Python-side budget even though Python wasn't running.

**Use cases unlocked:** Multi-tenant SaaS with tiered resource budgets,
DoS protection via allocation caps, GC tuning for memory-sensitive
environments, fair time accounting for iterative execution with slow
external calls.

---

## Demo 10: Binary Data Processing Pipeline (Bytes Type)

**Blocked by:** Missing `Bytes` type fidelity (Tier 3, Item 12)

Python processes binary data — checksums, encoding, byte manipulation —
but the result collapses to a JSON array of integers instead of
efficient `Uint8List`.

**Python code:**

```python
import hashlib

def process_image(raw_bytes: bytes) -> dict:
    # Compute checksum
    sha = hashlib.sha256(raw_bytes).digest()

    # Simple image header parse (PNG)
    width = int.from_bytes(raw_bytes[16:20], 'big')
    height = int.from_bytes(raw_bytes[20:24], 'big')

    # Create a thumbnail placeholder (just first 1024 bytes)
    thumbnail = raw_bytes[:1024]

    return {
        "sha256": sha,              # bytes (32 bytes)
        "width": width,
        "height": height,
        "thumbnail": thumbnail,     # bytes (1024 bytes)
        "original_size": len(raw_bytes),
    }

result = process_image(INPUT_IMAGE)
```

**Dart code that would need to exist:**

```dart
// Pass binary data IN as a proper bytes input
final imageBytes = await File('photo.png').readAsBytes();

final result = await monty.run(
  pythonCode,
  inputs: {'INPUT_IMAGE': imageBytes},  // Uint8List -> MontyObject::Bytes
);

final data = result.value as Map<String, dynamic>;

// Receive binary data OUT as Uint8List, not List<int>
final sha256 = data['sha256'] as Uint8List;   // 32 bytes, zero-copy
final thumbnail = data['thumbnail'] as Uint8List;  // 1024 bytes

print('SHA-256: ${hex.encode(sha256)}');
print('Dimensions: ${data["width"]}x${data["height"]}');

// Write thumbnail efficiently — no int-by-int JSON array conversion
await File('thumb.bin').writeAsBytes(thumbnail);
```

**Why it fails today:** When Python returns `bytes`, the C FFI
serializes it as a JSON array of integers: `[137, 80, 78, 71, ...]`.
For a 1 MB image, that becomes a ~4 MB JSON string of comma-separated
numbers that must be parsed back into a Dart `List<int>` and then
manually converted to `Uint8List`. The upstream `MontyObject::Bytes`
variant holds `Vec<u8>` which could be passed directly as a byte buffer,
but the JSON bridge destroys this efficiency. Input bytes have the same
problem — there is no way to pass `Uint8List` into Python as `bytes`
without going through JSON integer arrays.

**Use cases unlocked:** Image processing pipelines, cryptographic
operations (hashing, signing), protobuf/msgpack serialization, binary
file format parsing, efficient data transfer without JSON bloat.

---

## Demo 11: Multi-Script Orchestration with Named Error Attribution

**Blocked by:** Missing `script_name` parameter (Tier 1, Item 4)

Run multiple named Python scripts in a pipeline where errors clearly
identify which script failed — essential for debugging multi-step
agent workflows.

**Dart code that would need to exist:**

```dart
// Pipeline of named scripts — each step feeds into the next
final scripts = [
  ('validators/input_sanitizer.py', sanitizerCode),
  ('transforms/normalize.py', normalizerCode),
  ('analysis/score.py', scorerCode),
  ('formatters/report.py', reportCode),
];

Map<String, dynamic> context = {'raw_input': userData};

for (final (name, code) in scripts) {
  final result = await monty.run(
    code,
    inputs: context,
    scriptName: name,   // <-- sets __name__ and traceback filenames
  );

  if (!result.isSuccess) {
    final ex = result.error!;
    // Error clearly identifies WHICH script in the pipeline failed
    print('Pipeline failed at step: ${ex.filename}');
    // "Pipeline failed at step: transforms/normalize.py"

    for (final frame in ex.traceback) {
      print('  ${frame.filename}:${frame.start.line} '
          'in ${frame.frameName}');
    }
    // Output:
    //   transforms/normalize.py:42 in normalize_field
    //   transforms/normalize.py:18 in process_record
    //   transforms/normalize.py:5 in <module>
    //
    // NOT:
    //   <script>:42 in normalize_field  (unhelpful default)

    // Log to monitoring with script attribution
    monitoring.reportError(
      script: name,
      line: ex.lineNumber,
      error: ex.message,
    );
    break;
  }

  context = result.value as Map<String, dynamic>;
}
```

**Why it fails today:** `MontyPlatform.run()` and `start()` have no
`scriptName` parameter. The upstream `MontyRun::new()` accepts
`script_name: &str` which sets the filename shown in tracebacks and
the value of `__name__` in Python. Without it, all errors report the
same generic filename (e.g. `<script>` or `<unknown>`), making it
impossible to tell which script in a multi-step pipeline failed. When
an agent runs 10 different Python snippets, every traceback looks
identical.

**Use cases unlocked:** Multi-step agent pipelines with clear error
attribution, server-side script execution with monitoring/alerting per
script, debuggable microservice-style Python orchestration, notebook-style
cells where each cell has a meaningful name in tracebacks.
