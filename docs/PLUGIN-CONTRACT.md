# Monty Plugin Contract

Everything you need to build, test, and register a MontyPlugin.

## MontyPlugin Base Class

Every plugin extends `MontyPlugin` from `dart_monty_bridge`:

```dart
import 'package:dart_monty_bridge/dart_monty_bridge.dart';

class MyPlugin extends MontyPlugin {
  @override
  String get namespace => 'my';

  @override
  String? get systemPromptContext => 'One-line LLM description.';

  @override
  String get pythonPrelude => '''
def my_helper(x):
    return my_do_thing(x=x)
_help_docs[my_helper] = "Does a thing. Usage: my_helper(x)"
_help_list = _help_list + [["my_helper", "Does a thing"]]''';

  @override
  List<HostFunction> get functions => [_doThing()];

  @override
  Future<void> onRegister(MontyBridge bridge) async {}

  @override
  Future<void> onDispose() async {}
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `namespace` | Yes | Unique lowercase identifier (`[a-z][a-z0-9_]*`, max 32 chars) |
| `systemPromptContext` | No | Short description injected into the LLM system prompt |
| `pythonPrelude` | No | Python code evaluated once on session creation |
| `functions` | Yes | List of `HostFunction`s callable from Python |
| `onRegister(bridge)` | No | Called when attached to a bridge (setup) |
| `onDispose()` | No | Called when session ends (cleanup, must be idempotent) |

### Reserved namespaces

`introspection` is reserved for built-in functions.

## HostFunction

A host function is a schema + async handler:

```dart
HostFunction _doThing() => HostFunction(
      schema: const HostFunctionSchema(
        name: 'my_do_thing',
        description: 'Does a thing with x.',
        params: [
          HostParam(
            name: 'x',
            type: HostParamType.string,
            description: 'The thing to do.',
          ),
        ],
      ),
      handler: (args) async {
        final x = args['x'];
        if (x is! String) {
          throw ArgumentError('x must be a string.');
        }
        return 'did $x';
      },
    );
```

### HostFunctionSchema

| Field | Type | Description |
|-------|------|-------------|
| `name` | `String` | Function name as registered with the interpreter. **Must** start with `{namespace}_`. |
| `description` | `String` | Human-readable description (shown to LLM in tool schemas). |
| `params` | `List<HostParam>` | Ordered parameter definitions. Positional args from Python map to params by order; keyword args overlay by name. |

### HostParam

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | `String` | — | Parameter name (becomes key in the validated args map). |
| `type` | `HostParamType` | — | Expected type. |
| `isRequired` | `bool` | `true` | Whether the caller must supply a value. |
| `description` | `String?` | `null` | Human-readable description for schema export. |
| `defaultValue` | `Object?` | `null` | Default when absent and not required. |

### HostParamType

| Enum value | Dart type | Python type | JSON Schema |
|------------|-----------|-------------|-------------|
| `string` | `String` | `str` | `"string"` |
| `integer` | `int` | `int` | `"integer"` |
| `number` | `num` | `float` | `"number"` |
| `boolean` | `bool` | `bool` | `"boolean"` |
| `list` | `List<Object?>` | `list` | `"array"` |
| `map` | `Map<String, Object?>` | `dict` | `"object"` |
| `any` | `Object?` | any | `"string"` |

**Rule:** Only use JSON-safe primitive types. Never use `dynamic`. The `any` type passes through without validation — use it sparingly for polymorphic values.

### Type coercion

- `integer` params accept `int`, `num` (truncated), or numeric `String`
- `number` params accept `num` or numeric `String`
- All other types require exact match

## Naming Rules

1. **Namespace prefix:** Every function name must start with `{namespace}_`. Example: namespace `fs` → functions `fs_cat`, `fs_ls`, `fs_write`.
2. **Valid namespace:** lowercase, `[a-z][a-z0-9_]*`, max 32 characters.
3. **No duplicates:** Two plugins cannot register the same function name.
4. **No duplicate namespaces:** Each namespace can only be registered once.

## Type Marshalling (Dart to Python)

| Dart | Python | Notes |
|------|--------|-------|
| `String` | `str` | |
| `int` | `int` | |
| `double` | `float` | |
| `bool` | `bool` | |
| `null` | `None` | |
| `List<Object?>` | `list` | Elements must be JSON-safe |
| `Map<String, Object?>` | `dict` | Keys must be strings, values JSON-safe |

**Prohibited:** `DateTime`, `Uint8List`, custom classes, `dynamic`. Convert to a JSON-safe representation first (e.g. ISO 8601 string for dates).

## Error Handling

1. **Validate arguments explicitly** — use `is!` type checks, throw `ArgumentError`:
   ```dart
   final path = args['path'];
   if (path is! String) {
     throw ArgumentError('path must be a string.');
   }
   ```
2. **Never** use bare `as` casts — they throw `TypeError` which is not catchable from Python.
3. **Throw `ArgumentError`** for bad input, `StateError` for invalid state.
4. Errors thrown by handlers are surfaced to the Monty runtime as Python exceptions.

## Monty Python Subset

Monty is a restricted Python subset. Prelude code and all user-facing Python must follow these rules.

### Supported

| Feature | Example |
|---------|---------|
| Variables | `x = 42` |
| Arithmetic | `+`, `-`, `*`, `/`, `//`, `%`, `**` |
| Comparison | `==`, `!=`, `<`, `>`, `<=`, `>=` |
| Boolean | `and`, `or`, `not`, `is`, `is not` |
| Strings | `"hello"`, `'world'`, `"""multi"""` |
| String ops | `+` concatenation, `*` repeat, `[i]` index, `[a:b]` slice |
| String methods | `.upper()`, `.lower()`, `.strip()`, `.split()`, `.replace()`, `.startswith()`, `.endswith()`, `.find()`, `.join()` |
| Lists | `[1, 2, 3]`, `.append()`, `[i]`, `[a:b]`, `len()` |
| Dicts | `{"k": v}`, `[key]`, `.get()`, `.keys()`, `.values()`, `.items()` |
| Tuples | `(1, 2, 3)` |
| `if`/`elif`/`else` | Standard |
| `while` loops | `while i < n:` |
| Functions | `def f(x, y=0):` |
| `print()` | Output captured in `MontyResult.printOutput` |
| `len()` | Works on str, list, dict |
| `str()`, `int()`, `float()`, `bool()` | Type conversions |
| `None`, `True`, `False` | Literals |
| `pass` | No-op |
| `return` | From functions |
| Functions as values | `d = {f: "docs"}` — functions are hashable |

### NOT Supported

| Feature | Workaround |
|---------|------------|
| `for x in items:` | Use `while` loop with index |
| `range()` | Use `while i < n: ... i = i + 1` |
| f-strings `f"{x}"` | Use `str(x)` + concatenation |
| `import` | Not available — host functions are globals |
| List comprehensions | Use `while` loop + `.append()` |
| `try`/`except` | Not available from user code |
| `class` definitions | Not available |
| `with` statements | Not available |
| `lambda` | Use `def` instead |
| `*args`, `**kwargs` | Use explicit parameters |
| Decorators | Not available |
| `assert` | Not available |
| `type()` | Not available |
| Sets | Use lists or dicts |

### Side-by-side workarounds

**Iterating a list:**
```python
# NOT supported:
# for item in items:
#     process(item)

# Workaround:
i = 0
while i < len(items):
    process(items[i])
    i = i + 1
```

**Building a string from parts:**
```python
# NOT supported:
# result = f"Hello {name}, you are {age}"

# Workaround:
result = "Hello " + name + ", you are " + str(age)
```

**Filtering a list:**
```python
# NOT supported:
# evens = [x for x in nums if x % 2 == 0]

# Workaround:
evens = []
i = 0
while i < len(nums):
    if nums[i] % 2 == 0:
        evens.append(nums[i])
    i = i + 1
```

## pythonPrelude Rules

The prelude is evaluated **once** on session creation, before any user code runs.

1. Must be valid Monty Python (see subset above).
2. Define convenience wrapper functions that call your `{namespace}_*` host functions.
3. Register help entries using `_help_docs` (function ref → description) and `_help_list` (ordered display list). These globals are initialized by the runtime before your prelude runs.
4. Keep it short — the prelude adds to every session's startup cost.

### Prelude template

```python
def my_helper(x):
    return my_do_thing(x=x)
_help_docs[my_helper] = "Does a thing. Usage: my_helper(x)"
_help_list = _help_list + [["my_helper", "Does a thing"]]

def my_other(a, b):
    return my_combine(a=a, b=b)
_help_docs[my_other] = "Combine a and b. Usage: my_other(a, b)"
_help_list = _help_list + [["my_other", "Combine a and b"]]
```

**Important:** Use `_help_list = _help_list + [[...]]` (list concatenation), not `.append()`, for maximum Monty compatibility.

### Help system

The runtime generates a global `help()` function after all plugin preludes:

```python
help()       # → formatted list of all registered functions
help(cat)    # → "Read a UTF-8 text file. Usage: cat(path)"
```

## Testing Pattern

### Handler test args must be JSON-safe primitives

When testing `handler(args)`, the `args` map simulates a JSON payload coming
from Python. It MUST contain **only** JSON-safe primitives (`String`, `int`,
`double`, `bool`, `List`, `Map`).

- **NEVER** pass Dart Enums, classes, or complex objects into the `args` map.
- If the underlying Dart package uses Enums (e.g. `Namespace.url`), pass the
  primitive string representation in the test, just as a Python caller would.
- Use `final` (not `const`) when extracting values from library objects for
  test args, to avoid Dart's strict constant evaluation errors with property
  accessors.

```dart
// WRONG — passes an Enum into args:
const ns = Namespace.url;
await handler({'namespace': ns, 'name': 'test'});

// WRONG — const can't evaluate .value:
const ns = Namespace.url.value;

// CORRECT — use final or a string literal:
final ns = Namespace.url.value;
await handler({'namespace': ns, 'name': 'test'});
// or:
await handler({'namespace': '6ba7b811-9dad-11d1-80b4-00c04fd430c8', 'name': 'test'});
```

### Unit tests

Test each handler in isolation with a temp directory (for I/O plugins) or mock dependencies:

```dart
import 'package:test/test.dart';

void main() {
  group('MyPlugin', () {
    late MyPlugin plugin;

    setUp(() {
      plugin = MyPlugin();
    });

    test('namespace is my', () {
      expect(plugin.namespace, 'my');
    });

    test('provides N functions', () {
      expect(plugin.functions, hasLength(N));
      final names = plugin.functions.map((f) => f.schema.name).toSet();
      expect(names, containsAll(['my_do_thing', 'my_combine']));
    });

    test('pythonPrelude defines wrapper functions', () {
      expect(plugin.pythonPrelude, contains('def my_helper('));
    });

    group('my_do_thing', () {
      late Map<String, HostFunction> byName;

      setUp(() {
        byName = {for (final f in plugin.functions) f.schema.name: f};
      });

      test('happy path', () async {
        final result = await byName['my_do_thing']!.handler({
          'x': 'hello',
        });
        expect(result, 'did hello');
      });

      test('rejects non-string x', () async {
        expect(
          () => byName['my_do_thing']!.handler({'x': 123}),
          throwsA(isA<ArgumentError>()),
        );
      });
    });
  });
}
```

### Integration tests

Use a `RecordingBridge` to verify registration, or a `_ScriptableBridge` to test the full pipeline:

```dart
test('registers onto bridge via PluginRegistry', () async {
  final bridge = RecordingBridge();
  final registry = PluginRegistry()..register(plugin);
  await registry.attachTo(bridge);

  final names = bridge.registered.map((f) => f.schema.name).toSet();
  expect(names, contains('my_do_thing'));
});
```

### Schema tests

Verify parameter definitions:

```dart
test('my_do_thing has x param', () {
  final schema = byName['my_do_thing']!.schema;
  expect(schema.params, hasLength(1));
  expect(schema.params[0].name, 'x');
  expect(schema.params[0].type, HostParamType.string);
});
```

## Registration

### In soliplex_scripting (factory)

Pass your plugin via the `extraPlugins` parameter:

```dart
final factory = createMontyScriptEnvironmentFactory(
  hostApi: hostApi,
  extraPlugins: [MyPlugin()],
);
```

### In dart_monty_mcp (MCP server)

```dart
final server = MontyMcpServer(platformFactory: platformFactory);
server.registerPlugin(MyPlugin());
```

The MCP server exposes plugin functions both as Python-callable host functions and as direct MCP tools.

### In soliplex_cli (TUI)

Plugins passed via `extraPlugins` are available in the interactive REPL.

## Complete Worked Example: LocalFsPlugin

A sandboxed file system plugin with 8 functions, path traversal prevention, and Linux-style naming.

```dart
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:soliplex_interpreter_monty/soliplex_interpreter_monty.dart';

class LocalFsPlugin extends MontyPlugin {
  LocalFsPlugin({required String rootPath})
      : _rootPath = Directory(rootPath).resolveSymbolicLinksSync();

  final String _rootPath;

  @override
  String get namespace => 'fs';

  @override
  String? get systemPromptContext =>
      'Read and write local files within the sandbox root. '
      'Commands mirror Linux: cat, ls, write, mkdir, rm, stat, '
      'exists, find.';

  @override
  String get pythonPrelude => '''
def cat(path):
    return fs_cat(path=path)
_help_docs[cat] = "Read a UTF-8 text file. Usage: cat(path)"
_help_list = _help_list + [["cat", "Read a UTF-8 text file"]]

def ls(path=".", recursive=False):
    return fs_ls(path=path, recursive=recursive)
_help_docs[ls] = "List directory entries. Usage: ls(path, recursive=False)"
_help_list = _help_list + [["ls", "List directory entries"]]

def write(path, content):
    fs_write(path=path, content=content)
_help_docs[write] = "Write text to a file. Usage: write(path, content)"
_help_list = _help_list + [["write", "Write text to a file"]]

def mkdir(path):
    fs_mkdir(path=path)
_help_docs[mkdir] = "Create directory (recursive). Usage: mkdir(path)"
_help_list = _help_list + [["mkdir", "Create directory (recursive)"]]

def rm(path):
    fs_rm(path=path)
_help_docs[rm] = "Delete a file or empty directory. Usage: rm(path)"
_help_list = _help_list + [["rm", "Delete a file or empty directory"]]

def stat(path):
    return fs_stat(path=path)
_help_docs[stat] = "Get file metadata. Usage: stat(path)"
_help_list = _help_list + [["stat", "Get file metadata"]]

def exists(path):
    return fs_exists(path=path)
_help_docs[exists] = "Check if path exists. Usage: exists(path)"
_help_list = _help_list + [["exists", "Check if path exists"]]

def find(path=".", pattern="*"):
    return fs_find(path=path, pattern=pattern)
_help_docs[find] = "Find files by glob. Usage: find(path, pattern)"
_help_list = _help_list + [["find", "Find files by glob"]]''';

  @override
  List<HostFunction> get functions => [
        _cat(), _ls(), _write(), _mkdir(),
        _rm(), _stat(), _exists(), _find(),
      ];

  /// Resolves path within sandbox. Uses resolveSymbolicLinksSync for
  /// existing paths (catches symlink escapes), p.canonicalize for new
  /// paths (handles .. traversal).
  String _resolve(String path) {
    if (path.isEmpty) {
      throw ArgumentError('path must be a non-empty string.');
    }
    final joined = p.join(_rootPath, path);
    final normalized =
        FileSystemEntity.typeSync(joined) != FileSystemEntityType.notFound
            ? File(joined).resolveSymbolicLinksSync()
            : p.canonicalize(joined);
    if (!p.isWithin(_rootPath, normalized) && normalized != _rootPath) {
      throw ArgumentError('Path escapes sandbox root: $path');
    }
    return normalized;
  }

  HostFunction _cat() => HostFunction(
        schema: const HostFunctionSchema(
          name: 'fs_cat',
          description: 'Read a UTF-8 text file and return its contents.',
          params: [
            HostParam(
              name: 'path',
              type: HostParamType.string,
              description: 'Relative path within the sandbox root.',
            ),
          ],
        ),
        handler: (args) async {
          final path = args['path'];
          if (path is! String) {
            throw ArgumentError('path must be a string.');
          }
          final resolved = _resolve(path);
          final file = File(resolved);
          if (!file.existsSync()) {
            throw ArgumentError('File does not exist: $path');
          }
          return file.readAsStringSync();
        },
      );

  // ... remaining 7 functions follow the same pattern:
  // _ls(), _write(), _mkdir(), _rm(), _stat(), _exists(), _find()
}
```

### Key patterns in this example

1. **Constructor validates rootPath** — `resolveSymbolicLinksSync()` on the root itself
2. **`_resolve()` prevents escapes** — symlink resolution for existing paths, canonicalization for new paths
3. **Explicit type checks** — `path is! String` with `ArgumentError`, never bare `as`
4. **Prelude registers help** — both `_help_docs[fn]` (for `help(fn)`) and `_help_list` (for `help()`)
5. **Linux-style naming** — wrapper functions (`cat`, `ls`) hide the `fs_` prefix
6. **Schema descriptions** — clear enough for an LLM to use without additional context

## Checklist

Before submitting a plugin:

- [ ] Namespace is lowercase, `[a-z][a-z0-9_]*`, max 32 chars
- [ ] All function names start with `{namespace}_`
- [ ] All params use `HostParamType` (no `dynamic`)
- [ ] Handler validates args with `is!` checks, throws `ArgumentError`
- [ ] No bare `as` casts
- [ ] `pythonPrelude` uses only Monty-safe Python (no for-in, f-strings, imports, range)
- [ ] Help entries registered in `_help_docs` and `_help_list`
- [ ] Unit tests for each handler (happy + error paths)
- [ ] Integration test via `PluginRegistry.attachTo(bridge)`
- [ ] `dart analyze --fatal-infos` clean
- [ ] `dart test` passes
