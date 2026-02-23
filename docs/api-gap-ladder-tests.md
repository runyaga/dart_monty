# API Gap Ladder Tests

Companion to `api-gap-demos.md`. Each tier below contains ladder test
fixtures that exercise capabilities missing from the current dart_monty
API. All fixtures use `"xfail"` with a reason string until the
underlying feature is implemented — at which point xfail is removed and
the test must pass. An unexpected pass (XPASS) signals that a feature
was implemented but the fixture wasn't updated.

## Schema Extensions

The current fixture schema supports simple run, error, and iterative
(external function) execution. The gap tiers require new fields.
Runners that don't recognize a field should skip the fixture gracefully.

```json
{
  "id": 100,
  "tier": 8,
  "name": "...",
  "code": "...",

  // --- Existing fields ---
  "expected": null,
  "expectedContains": null,
  "expectedSorted": false,
  "expectError": false,
  "errorContains": null,
  "externalFunctions": null,
  "resumeValues": null,
  "resumeErrors": null,
  "nativeOnly": false,
  "xfail": "reason string",

  // --- New fields (gap tiers) ---
  "expectedKwargs": null,           // Map: expected kwargs on pending call
  "expectedFnName": null,           // String: expected function name on pending
  "expectedCallId": null,           // int: expected call_id
  "expectedMethodCall": null,       // bool: expected method_call flag
  "expectedExcType": null,          // String: expected exception type name
  "expectedTraceback": null,        // List<Map>: expected stack frames
  "expectedTypeTag": null,          // String: "$tuple", "$set", "$bytes", etc.
  "scriptName": null,               // String: script name to pass to run/start
  "limits": null,                   // Map: resource limits to apply
  "replSteps": null,                // List<Map>: REPL feed sequence
  "asyncResumeMap": null,           // Map<callId, value>: for futures resolution
  "osCallResponses": null,          // Map<function, value>: for OS call responses
  "expectedPrintLines": null,       // List<String>: expected live print lines
  "typeCheckExpected": null         // Map: expected type-check diagnostics
}
```

---

## Tier 8: kwargs & Call Metadata (Demo 4)

Tests that external function calls preserve keyword arguments, call IDs,
and the method_call flag.

| ID | Name | Python Code | Validates |
|----|------|-------------|-----------|
| 100 | kwargs simple | `result = search(query="hello", limit=10)` | `expectedKwargs: {"query": "hello", "limit": 10}` |
| 101 | kwargs mixed positional | `send("alice@x.com", subject="hi", body="text")` | `args[0]` = email, kwargs = subject+body |
| 102 | kwargs only | `config(debug=true, verbose=false, port=8080)` | All three kwargs preserved, no positional args |
| 103 | kwargs with default passthrough | `db_query(table="users")` | Single kwarg, no positional |
| 104 | kwargs ordering preserved | `f(z=3, a=1, m=2)` | kwargs order matches call site |
| 105 | method_call flag true | `obj = get_obj()\nobj.process(x=1)` | `expectedMethodCall: true` on second call |
| 106 | method_call flag false | `process(x=1)` | `expectedMethodCall: false` |
| 107 | call_id sequential | `a = f(1)\nb = f(2)\nc = f(3)` | call_ids are 0, 1, 2 (or sequential) |
| 108 | kwargs value types | `f(s="hi", n=42, b=true, x=3.14, none=None)` | All Python types survive in kwargs |

```json
[
  {
    "id": 100,
    "tier": 8,
    "name": "kwargs simple key-value",
    "code": "result = search(query=\"hello\", limit=10)\nresult",
    "expected": "found",
    "expectedContains": null,
    "expectedSorted": false,
    "expectError": false,
    "errorContains": null,
    "externalFunctions": ["search"],
    "resumeValues": ["found"],
    "resumeErrors": null,
    "expectedKwargs": {"query": "hello", "limit": 10},
    "expectedFnName": "search",
    "nativeOnly": false,
    "xfail": "kwargs not exposed in MontyPending"
  },
  {
    "id": 101,
    "tier": 8,
    "name": "kwargs mixed with positional args",
    "code": "send(\"alice@x.com\", subject=\"hi\", body=\"text\")\n\"ok\"",
    "expected": "ok",
    "expectedContains": null,
    "expectedSorted": false,
    "expectError": false,
    "errorContains": null,
    "externalFunctions": ["send"],
    "resumeValues": [null],
    "resumeErrors": null,
    "expectedKwargs": {"subject": "hi", "body": "text"},
    "expectedFnName": "send",
    "nativeOnly": false,
    "xfail": "kwargs not exposed in MontyPending"
  },
  {
    "id": 102,
    "tier": 8,
    "name": "kwargs only no positional",
    "code": "config(debug=True, verbose=False, port=8080)\n\"ok\"",
    "expected": "ok",
    "expectedContains": null,
    "expectedSorted": false,
    "expectError": false,
    "errorContains": null,
    "externalFunctions": ["config"],
    "resumeValues": [null],
    "resumeErrors": null,
    "expectedKwargs": {"debug": true, "verbose": false, "port": 8080},
    "expectedFnName": "config",
    "nativeOnly": false,
    "xfail": "kwargs not exposed in MontyPending"
  }
]
```

---

## Tier 9: Exception Fidelity (Demo 3)

Tests that exception type, full traceback frames, and structured error
metadata are preserved through the bridge.

| ID | Name | Python Code | Validates |
|----|------|-------------|-----------|
| 110 | exc_type ValueError | `int("abc")` | `expectedExcType: "ValueError"` |
| 111 | exc_type TypeError | `len(42)` | `expectedExcType: "TypeError"` |
| 112 | exc_type KeyError | `{}["missing"]` | `expectedExcType: "KeyError"` |
| 113 | exc_type IndexError | `[][0]` | `expectedExcType: "IndexError"` |
| 114 | exc_type ZeroDivisionError | `1/0` | `expectedExcType: "ZeroDivisionError"` |
| 115 | exc_type AttributeError | `"hi".no_method()` | `expectedExcType: "AttributeError"` |
| 116 | exc_type RecursionError | `def f(): f()\nf()` | `expectedExcType: "RecursionError"` |
| 117 | traceback single frame | `raise ValueError("x")` | 1 frame: line 1, `<module>` |
| 118 | traceback two frames | `def f(): raise ValueError("x")\nf()` | 2 frames: `f` at line 1, `<module>` at line 2 |
| 119 | traceback three frames deep | `def a(): ...\ndef b(): a()\ndef c(): b()\nc()` | 3 frames with correct function names |
| 120 | traceback preserves preview_line | `x = 1 + "bad"` | frame has `preview_line` containing the source |
| 121 | traceback filename from script_name | script_name="my_script.py" + error | `filename == "my_script.py"` in all frames |

```json
[
  {
    "id": 110,
    "tier": 9,
    "name": "exc_type ValueError",
    "code": "int(\"abc\")",
    "expected": null,
    "expectedContains": null,
    "expectedSorted": false,
    "expectError": true,
    "errorContains": "invalid literal",
    "externalFunctions": null,
    "resumeValues": null,
    "resumeErrors": null,
    "expectedExcType": "ValueError",
    "nativeOnly": false,
    "xfail": "exc_type not exposed in MontyException"
  },
  {
    "id": 111,
    "tier": 9,
    "name": "exc_type TypeError",
    "code": "len(42)",
    "expected": null,
    "expectedContains": null,
    "expectedSorted": false,
    "expectError": true,
    "errorContains": "has no len",
    "externalFunctions": null,
    "resumeValues": null,
    "resumeErrors": null,
    "expectedExcType": "TypeError",
    "nativeOnly": false,
    "xfail": "exc_type not exposed in MontyException"
  },
  {
    "id": 118,
    "tier": 9,
    "name": "traceback two frames deep",
    "code": "def f():\n    raise ValueError(\"boom\")\nf()",
    "expected": null,
    "expectedContains": null,
    "expectedSorted": false,
    "expectError": true,
    "errorContains": "boom",
    "externalFunctions": null,
    "resumeValues": null,
    "resumeErrors": null,
    "expectedExcType": "ValueError",
    "expectedTraceback": [
      {"frameName": "<module>", "line": 3},
      {"frameName": "f", "line": 2}
    ],
    "nativeOnly": false,
    "xfail": "traceback not exposed in MontyException"
  }
]
```

---

## Tier 10: Rich Types (Demos 8, 10)

Tests that Python's distinct collection and structured types survive the
bridge with type identity preserved.

| ID | Name | Python Code | Validates |
|----|------|-------------|-----------|
| 130 | tuple vs list identity | `(1, 2, 3)` | `expectedTypeTag: "$tuple"` |
| 131 | nested tuple | `((1, 2), (3, 4))` | Outer and inner are both `$tuple` |
| 132 | set deduplication | `{1, 2, 2, 3, 3, 3}` | `expectedTypeTag: "$set"`, length 3 |
| 133 | frozenset | `frozenset([1, 2, 3])` | `expectedTypeTag: "$frozenset"` |
| 134 | set vs list | `[{1,2}, [1,2]]` | First is `$set`, second is list |
| 135 | bytes literal | `b"hello"` | `expectedTypeTag: "$bytes"`, value = [104,101,108,108,111] |
| 136 | bytes from encode | `"cafe".encode("utf-8")` | `$bytes` tag preserved |
| 137 | bytes round-trip | `INPUT_DATA[::-1]` (input: bytes) | Input as bytes, output as bytes |
| 138 | namedtuple fields | `from collections import namedtuple\nP=namedtuple("Point","x y")\nP(1,2)` | type_name="Point", field_names=["x","y"] |
| 139 | dataclass basic | `from dataclasses import dataclass\n@dataclass\nclass P:\n  x:int\n  y:int\nP(1,2)` | name="P", field_names=["x","y"] |
| 140 | dataclass frozen | `@dataclass(frozen=True)\nclass P:\n  x:int\nP(1)` | `frozen: true` |
| 141 | pathlib.Path | `from pathlib import Path\nPath("/tmp/test")` | `expectedTypeTag: "$path"` or string "/tmp/test" |
| 142 | bytes large payload | `b"x" * 10000` | 10000-byte bytes object, not 50KB JSON array |
| 143 | bigint large | `2 ** 100` | Value as string or BigInt, not truncated |
| 144 | mixed collection types | `{"t": (1,), "s": {2}, "l": [3], "b": b"4"}` | Dict with typed values |

```json
[
  {
    "id": 130,
    "tier": 10,
    "name": "tuple identity preserved",
    "code": "(1, 2, 3)",
    "expected": [1, 2, 3],
    "expectedContains": null,
    "expectedSorted": false,
    "expectError": false,
    "errorContains": null,
    "externalFunctions": null,
    "resumeValues": null,
    "resumeErrors": null,
    "expectedTypeTag": "$tuple",
    "nativeOnly": false,
    "xfail": "tuple collapses to list through JSON bridge"
  },
  {
    "id": 132,
    "tier": 10,
    "name": "set deduplication preserved",
    "code": "{1, 2, 2, 3, 3, 3}",
    "expected": [1, 2, 3],
    "expectedContains": null,
    "expectedSorted": true,
    "expectError": false,
    "errorContains": null,
    "externalFunctions": null,
    "resumeValues": null,
    "resumeErrors": null,
    "expectedTypeTag": "$set",
    "nativeOnly": false,
    "xfail": "set collapses to list through JSON bridge"
  },
  {
    "id": 135,
    "tier": 10,
    "name": "bytes literal",
    "code": "b\"hello\"",
    "expected": [104, 101, 108, 108, 111],
    "expectedContains": null,
    "expectedSorted": false,
    "expectError": false,
    "errorContains": null,
    "externalFunctions": null,
    "resumeValues": null,
    "resumeErrors": null,
    "expectedTypeTag": "$bytes",
    "nativeOnly": false,
    "xfail": "bytes loses type tag through JSON bridge"
  }
]
```

---

## Tier 11: OS Calls (Demo 7)

Tests that Python `os.getenv`, `os.environ`, and file stat calls yield
to the host and accept responses.

| ID | Name | Python Code | Validates |
|----|------|-------------|-----------|
| 150 | os.getenv hit | `import os\nos.getenv("HOME")` | OsCall with function=Getenv, host returns "/home/user" |
| 151 | os.getenv miss with default | `import os\nos.getenv("MISSING", "fallback")` | Host returns None, Python uses "fallback" |
| 152 | os.environ access | `import os\nos.environ["API_KEY"]` | OsCall with function=Environ, host returns dict |
| 153 | os.environ KeyError | `import os\nos.environ["NOPE"]` | Host returns env dict missing "NOPE", Python raises KeyError |
| 154 | os.stat file exists | `import os\nos.stat("/app/config.yaml").st_size` | OsCall with function=FileStat, host returns stat result |
| 155 | os.stat file not found | `import os\nos.stat("/nope")` | Host resumes with FileNotFoundError |
| 156 | multiple os calls | `import os\na=os.getenv("A")\nb=os.getenv("B")\na+b` | Two sequential OsCalls |

```json
[
  {
    "id": 150,
    "tier": 11,
    "name": "os.getenv returns host value",
    "code": "import os\nos.getenv(\"HOME\")",
    "expected": "/home/user",
    "expectedContains": null,
    "expectedSorted": false,
    "expectError": false,
    "errorContains": null,
    "externalFunctions": null,
    "resumeValues": null,
    "resumeErrors": null,
    "osCallResponses": {"Getenv": "/home/user"},
    "nativeOnly": false,
    "xfail": "OsCall progress variant not handled"
  },
  {
    "id": 153,
    "tier": 11,
    "name": "os.environ missing key raises KeyError",
    "code": "import os\nos.environ[\"NOPE\"]",
    "expected": null,
    "expectedContains": null,
    "expectedSorted": false,
    "expectError": true,
    "errorContains": "KeyError",
    "externalFunctions": null,
    "resumeValues": null,
    "resumeErrors": null,
    "osCallResponses": {"Environ": {"HOME": "/home/user"}},
    "nativeOnly": false,
    "xfail": "OsCall progress variant not handled"
  }
]
```

---

## Tier 12: REPL Sessions (Demo 1)

Tests that use the `replSteps` field to feed multiple code snippets into
a persistent session. Each step has `code`, optional `expected` or
`expectError`, and the session state persists across steps.

| ID | Name | Steps | Validates |
|----|------|-------|-----------|
| 160 | repl variable persistence | `x=10` -> `x*2` | Second step returns 20 |
| 161 | repl function persistence | `def f(n): return n+1` -> `f(41)` | Returns 42 |
| 162 | repl error recovery | `x=10` -> `1/0` (error) -> `x` | x is still 10 after error |
| 163 | repl accumulation | `a=[]` -> `a.append(1)` -> `a.append(2)` -> `a` | Returns [1, 2] |
| 164 | repl import persistence | `import sys` -> `sys.platform` | Returns "monty" |
| 165 | repl overwrite variable | `x=1` -> `x=2` -> `x` | Returns 2 |
| 166 | repl external fn in session | `result=fetch("url")` -> `result` | External fn works in REPL context |
| 167 | repl snapshot and restore | `x=42` -> snapshot -> restore -> `x` | Variable survives dump/load |
| 168 | repl continuation detect | `def f(n):` (incomplete) | `ReplContinuationMode::IncompleteBlock` |

```json
[
  {
    "id": 160,
    "tier": 12,
    "name": "repl variable persistence across feeds",
    "code": null,
    "expected": 20,
    "expectedContains": null,
    "expectedSorted": false,
    "expectError": false,
    "errorContains": null,
    "externalFunctions": null,
    "resumeValues": null,
    "resumeErrors": null,
    "replSteps": [
      {"code": "x = 10", "expected": null},
      {"code": "x * 2", "expected": 20}
    ],
    "nativeOnly": false,
    "xfail": "REPL API not implemented"
  },
  {
    "id": 162,
    "tier": 12,
    "name": "repl error recovery preserves state",
    "code": null,
    "expected": 10,
    "expectedContains": null,
    "expectedSorted": false,
    "expectError": false,
    "errorContains": null,
    "externalFunctions": null,
    "resumeValues": null,
    "resumeErrors": null,
    "replSteps": [
      {"code": "x = 10", "expected": null},
      {"code": "1 / 0", "expectError": true, "errorContains": "ZeroDivision"},
      {"code": "x", "expected": 10}
    ],
    "nativeOnly": false,
    "xfail": "REPL API not implemented"
  }
]
```

---

## Tier 13: Async / Futures (Demo 2)

Tests that Python `async`/`await` and `asyncio.gather` yield
`ResolveFutures` to the host, with call_id correlation for parallel
resolution.

| ID | Name | Python Code | Validates |
|----|------|-------------|-----------|
| 170 | single await external | `async def f(): return await fetch("u")\nawait f()` | Future created, resolved, value returned |
| 171 | asyncio.gather two | `import asyncio\nawait asyncio.gather(fetch("a"), fetch("b"))` | Two pending call_ids, both resolved |
| 172 | asyncio.gather three | `import asyncio\nawait asyncio.gather(f("a"),f("b"),f("c"))` | Three pending call_ids |
| 173 | future error propagation | `await fetch("bad")` + host returns error | Python sees RuntimeError |
| 174 | mixed sync and async | `x = compute(1)\ny = await fetch("u")\nx + y` | First is sync resume, second is future |
| 175 | nested async | `async def inner(): return await fetch("u")\nasync def outer(): return await inner()\nawait outer()` | Nested coroutine chain |

```json
[
  {
    "id": 170,
    "tier": 13,
    "name": "single await external future",
    "code": "async def f():\n    return await fetch(\"url\")\nawait f()",
    "expected": "response",
    "expectedContains": null,
    "expectedSorted": false,
    "expectError": false,
    "errorContains": null,
    "externalFunctions": ["fetch"],
    "resumeValues": null,
    "resumeErrors": null,
    "asyncResumeMap": {"0": "response"},
    "nativeOnly": false,
    "xfail": "async/futures not implemented"
  },
  {
    "id": 171,
    "tier": 13,
    "name": "asyncio.gather two concurrent futures",
    "code": "import asyncio\nawait asyncio.gather(fetch(\"a\"), fetch(\"b\"))",
    "expected": ["result_a", "result_b"],
    "expectedContains": null,
    "expectedSorted": false,
    "expectError": false,
    "errorContains": null,
    "externalFunctions": ["fetch"],
    "resumeValues": null,
    "resumeErrors": null,
    "asyncResumeMap": {"0": "result_a", "1": "result_b"},
    "nativeOnly": false,
    "xfail": "async/futures not implemented"
  }
]
```

---

## Tier 14: Resource Limits (Demo 9)

Tests fine-grained resource control: allocation caps, GC interval,
time limit re-arming.

| ID | Name | Code | Validates |
|----|------|------|-----------|
| 180 | max_allocations exceeded | Allocate 1000 objects with limit 500 | MemoryError from allocation cap |
| 181 | max_allocations sufficient | Allocate 100 objects with limit 500 | Succeeds |
| 182 | gc_interval triggers collection | Allocate with gc_interval=100 | Memory stays bounded |
| 183 | time limit re-arm between phases | Long external call + more Python | Python phase gets fresh time budget |
| 184 | allocation limit vs memory limit | Many small objects (low memory, high count) | Allocation limit triggers first |

```json
[
  {
    "id": 180,
    "tier": 14,
    "name": "max_allocations exceeded",
    "code": "data = []\nfor i in range(1000):\n    data.append({\"k\": i})\nlen(data)",
    "expected": null,
    "expectedContains": null,
    "expectedSorted": false,
    "expectError": true,
    "errorContains": "MemoryError",
    "externalFunctions": null,
    "resumeValues": null,
    "resumeErrors": null,
    "limits": {"maxAllocations": 500},
    "nativeOnly": false,
    "xfail": "max_allocations not exposed in MontyLimits"
  },
  {
    "id": 181,
    "tier": 14,
    "name": "max_allocations sufficient",
    "code": "data = []\nfor i in range(100):\n    data.append(i)\nlen(data)",
    "expected": 100,
    "expectedContains": null,
    "expectedSorted": false,
    "expectError": false,
    "errorContains": null,
    "externalFunctions": null,
    "resumeValues": null,
    "resumeErrors": null,
    "limits": {"maxAllocations": 500},
    "nativeOnly": false,
    "xfail": "max_allocations not exposed in MontyLimits"
  }
]
```

---

## Tier 15: Script Naming (Demo 11)

Tests that `scriptName` is passed through to the interpreter and appears
in error tracebacks.

| ID | Name | Code | Validates |
|----|------|------|-----------|
| 190 | script_name in error | `1/0` with scriptName="calc.py" | Error filename == "calc.py" |
| 191 | script_name in traceback | `def f(): 1/0\nf()` with scriptName="app.py" | Both frames show "app.py" |
| 192 | script_name default | `1/0` without scriptName | Filename is default (not "calc.py") |
| 193 | script_name in __name__ | `__name__` with scriptName="my_module" | Returns "my_module" or "__main__" |

```json
[
  {
    "id": 190,
    "tier": 15,
    "name": "script_name appears in error filename",
    "code": "1 / 0",
    "expected": null,
    "expectedContains": null,
    "expectedSorted": false,
    "expectError": true,
    "errorContains": "ZeroDivision",
    "externalFunctions": null,
    "resumeValues": null,
    "resumeErrors": null,
    "scriptName": "calc.py",
    "expectedTraceback": [
      {"filename": "calc.py", "line": 1}
    ],
    "nativeOnly": false,
    "xfail": "scriptName parameter not supported"
  }
]
```

---

## Tier 16: Print Streaming (Demo 6)

Tests that print output is captured per-line in real-time, not just as
a final batch string.

| ID | Name | Code | Validates |
|----|------|------|-----------|
| 200 | single print | `print("hello")` | `expectedPrintLines: ["hello"]` |
| 201 | multiple prints | `print("a")\nprint("b")\nprint("c")` | 3 lines in order |
| 202 | print during external call | `print("before")\nfetch("u")\nprint("after")` | "before" arrives before resume |
| 203 | print with sep and end | `print(1, 2, 3, sep="-")` | `expectedPrintLines: ["1-2-3"]` |
| 204 | print in loop | `for i in range(5): print(i)` | Lines 0-4 in order |
| 205 | print interleaved with external | `print("1")\nf()\nprint("2")\nf()\nprint("3")` | Lines arrive between resumes |

```json
[
  {
    "id": 200,
    "tier": 16,
    "name": "single print captured as line",
    "code": "print(\"hello\")",
    "expected": null,
    "expectedContains": null,
    "expectedSorted": false,
    "expectError": false,
    "errorContains": null,
    "externalFunctions": null,
    "resumeValues": null,
    "resumeErrors": null,
    "expectedPrintLines": ["hello"],
    "nativeOnly": false,
    "xfail": "live print streaming not implemented"
  },
  {
    "id": 202,
    "tier": 16,
    "name": "print before external call arrives early",
    "code": "print(\"before\")\nresult = fetch(\"url\")\nprint(\"after\")\nresult",
    "expected": "data",
    "expectedContains": null,
    "expectedSorted": false,
    "expectError": false,
    "errorContains": null,
    "externalFunctions": ["fetch"],
    "resumeValues": ["data"],
    "resumeErrors": null,
    "expectedPrintLines": ["before", "after"],
    "nativeOnly": false,
    "xfail": "live print streaming not implemented"
  }
]
```

---

## Tier 17: Type Checking / ty (Demo 5)

Tests that Python source can be statically type-checked before execution
using the bundled ty type checker.

| ID | Name | Code | Validates |
|----|------|------|-----------|
| 210 | type error caught | `def f(x: int) -> int: return x\nf("hi")` | Diagnostic: str not assignable to int |
| 211 | clean code passes | `def f(x: int) -> int: return x + 1\nf(42)` | No diagnostics (null) |
| 212 | return type mismatch | `def f() -> int: return "hi"` | Diagnostic: str not assignable to int |
| 213 | undefined variable | `print(undefined_var)` | Diagnostic: name not defined |
| 214 | stub validation | `fetch(123)` with stub `def fetch(url: str) -> str: ...` | Diagnostic: int not assignable to str |
| 215 | multiple errors | `def f(x: int): return x\nf("a")\nf(1.5)` | Two diagnostics |

```json
[
  {
    "id": 210,
    "tier": 17,
    "name": "type error detected before execution",
    "code": "def f(x: int) -> int:\n    return x\nf(\"hi\")",
    "expected": null,
    "expectedContains": null,
    "expectedSorted": false,
    "expectError": false,
    "errorContains": null,
    "externalFunctions": null,
    "resumeValues": null,
    "resumeErrors": null,
    "typeCheckExpected": {
      "hasErrors": true,
      "errorContains": "not assignable"
    },
    "nativeOnly": false,
    "xfail": "type checking not implemented"
  },
  {
    "id": 211,
    "tier": 17,
    "name": "clean code passes type check",
    "code": "def f(x: int) -> int:\n    return x + 1\nf(42)",
    "expected": 43,
    "expectedContains": null,
    "expectedSorted": false,
    "expectError": false,
    "errorContains": null,
    "externalFunctions": null,
    "resumeValues": null,
    "resumeErrors": null,
    "typeCheckExpected": {
      "hasErrors": false
    },
    "nativeOnly": false,
    "xfail": "type checking not implemented"
  }
]
```

---

## Summary

| Tier | Name | Fixture IDs | Count | xfail Reason | Unblocks Demo |
|------|------|-------------|-------|-------------|---------------|
| 8 | kwargs & call metadata | 100-108 | 9 | kwargs not exposed | Demo 4 |
| 9 | Exception fidelity | 110-121 | 12 | exc_type / traceback not exposed | Demo 3 |
| 10 | Rich types | 130-144 | 15 | type tags lost through JSON bridge | Demos 8, 10 |
| 11 | OS calls | 150-156 | 7 | OsCall variant not handled | Demo 7 |
| 12 | REPL sessions | 160-168 | 9 | REPL API not implemented | Demo 1 |
| 13 | Async / futures | 170-175 | 6 | async/futures not implemented | Demo 2 |
| 14 | Resource limits | 180-184 | 5 | max_allocations not exposed | Demo 9 |
| 15 | Script naming | 190-193 | 4 | scriptName not supported | Demo 11 |
| 16 | Print streaming | 200-205 | 6 | live print not implemented | Demo 6 |
| 17 | Type checking | 210-215 | 6 | type checking not implemented | Demo 5 |
| | | | **79** | | |

Total: 79 new fixtures across 10 tiers, all initially xfail. As each
feature is implemented, remove the xfail and the fixture must pass.
An XPASS signals the feature was implemented but the fixture wasn't
updated — the CI should catch this.

### Fixture Progression Model

```text
Feature not started:  xfail → test SKIPs (expected failure)
Feature in progress:  xfail → some tests may XPASS (remove xfail for those)
Feature complete:     no xfail → all tests PASS
Regression:           no xfail → test FAILS (CI catches it)
```
