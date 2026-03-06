# dart_persistent — Design Plan

> ZODB-style persistent object graph for Monty. No pickle, no MVCC. Just objects in storage.

## 1. Package Location

`packages/dart_persistent/` — pure Dart (no Flutter SDK). Depends on
`dart_monty_platform_interface` for `MontySession` and `MontySnapshotCapable`.
Does NOT depend on `dart_monty_ffi` or `dart_monty_wasm` — the caller injects those.

## 2. API Surface

```
lib/
  dart_persistent.dart              # barrel export
  dart_persistent.prompt.md         # package-level LLM guide
  src/
    persistent.dart                 # Persistent mixin
    persistent_mapping.dart         # PersistentMapping (root dict)
    persistent_list.dart            # PersistentList
    oid.dart                        # OID typedef + generation
    connection.dart                 # Connection (ties objects to storage)
    transaction.dart                # Transaction (commit / abort)
    storage.dart                    # PersistentStorage abstract interface
    serializer.dart                 # JSON serializer for object graphs
    host_functions.dart             # Host function registry for db_* functions
    storage/
      in_memory_storage.dart        # InMemoryStorage (testing)
      local_storage.dart            # LocalStorage (web)
      file_storage.dart             # FileStorage (native, dart:io)
```

### Core Types

**`Persistent` (mixin)**
- `int? get oid` — assigned when first added to a Connection
- `bool get pChanged` — dirty flag (matches ZODB `_p_changed`)
- `Connection? get pConnection` — back-reference to owning connection
- `Map<String, Object?> toJson()` / `void fromJson(Map<String, Object?> data)`

**`PersistentMapping`** (with `Persistent`)
- Wraps `Map<String, Object?>`, delegates `[]`, `[]=`, `remove`, `keys`, `length`
- Setting a value marks `pChanged = true`

**`PersistentList`** (with `Persistent`)
- Wraps `List<Object?>`, delegates `add`, `[]`, `[]=`, `removeAt`, `length`
- Mutations mark `pChanged = true`

**`Connection`**
- `Connection({required PersistentStorage storage})`
- `PersistentMapping root()` — the root object (OID 0)
- `void add(Persistent obj)` — assign OID, register with connection
- `Transaction transaction()` — current transaction

**`Transaction`**
- `Future<void> commit()` — serialize dirty objects → storage
- `Future<void> abort()` — discard dirty, reload from last commit

**`PersistentStorage` (abstract)**
- `Future<void> store(OID oid, Map<String, Object?> data)`
- `Future<Map<String, Object?>?> load(OID oid)`
- `Future<void> storeAll(Map<OID, Map<String, Object?>> batch)`
- `Future<Map<OID, Map<String, Object?>>> loadAll()`
- `Future<void> clear()`

## 3. Python-Side Host Functions

Named to match Python conventions. `db_*` prefix for persistence ops:

| Host Function | Python Call | Description |
|---|---|---|
| `json_dumps` | `json_dumps(obj)` | Serialize to JSON string |
| `json_loads` | `json_loads(s)` | Parse JSON string |
| `db_root` | `db_root()` | Get root PersistentMapping as dict |
| `db_get` | `db_get(oid)` | Load object by OID |
| `db_set` | `db_set(oid, data)` | Store/update object by OID |
| `db_commit` | `db_commit()` | Commit all dirty objects |
| `db_abort` | `db_abort()` | Revert to last committed state |
| `db_new_mapping` | `db_new_mapping()` | Create new persistent dict |
| `db_new_list` | `db_new_list()` | Create new persistent list |

```python
root = db_root()
root["users"] = db_new_mapping()
root["users"]["alice"] = "admin"
db_commit()
# Refresh page → data persists
```

## 4. Storage Backends

| Backend | Use Case | Mechanism |
|---|---|---|
| `InMemoryStorage` | Testing | `Map<OID, Map>` in memory |
| `LocalStorage` | Web | Single JSON blob in localStorage |
| `FileStorage` | Native | JSONL file via dart:io |

**Why not snapshot-based?** Snapshots capture entire interpreter state (too
coarse for per-object storage), are not portable between native/web, and
are not human-readable. JSON serialization is the right v1 approach.

## 5. Transaction Model

- **Commit:** Walk dirty objects → `toJson()` → `storage.storeAll(batch)` → clear dirty flags
- **Abort:** For each dirty object → `fromJson(lastCommitted[oid])` → clear dirty flags
- **No MVCC.** Single connection, single transaction.
- Connection maintains `Map<OID, Map<String, Object?>> _lastCommitted` as abort point.

## 6. `.prompt.md` Convention

Every `.dart` file gets a sibling `.prompt.md`:

```markdown
# <ClassName> — LLM Usage Guide

> LLM prompt: Use this document when working with `<ClassName>`.

## Purpose
One sentence.

## Quick Example
5-15 lines of working code.

## API Reference
| Method | Signature | Description |

## Invariants
- Things that must always be true.

## Common Patterns / Anti-Patterns

## Related Files
```

## 7. Implementation Steps

### Phase 1: Scaffolding
1. `pubspec.yaml`, `analysis_options.yaml`, barrel export

### Phase 2: Core Types
2. `oid.dart` — OID typedef + OidGenerator
3. `persistent.dart` — Persistent mixin
4. `persistent_mapping.dart` — PersistentMapping
5. `persistent_list.dart` — PersistentList
6. `serializer.dart` — JSON serializer (nested Persistent → `{"__oid__": N}`)

### Phase 3: Storage
7. `storage.dart` — PersistentStorage interface
8. `in_memory_storage.dart`, `local_storage.dart`, `file_storage.dart`

### Phase 4: Connection + Transaction
9. `transaction.dart` — commit/abort
10. `connection.dart` — root, add, transaction lifecycle

### Phase 5: Host Functions
11. `host_functions.dart` — `PersistentHostFunctions` class with dispatch table

### Phase 6: Tests
12. Unit tests for each type (90%+ coverage target)
13. Integration test: full Python → db_root → mutate → db_commit → reload cycle

### Phase 7: Root Project Integration
14. Add to `dependency_overrides`, `analyze_packages.py`, create `tool/test_persistent.sh`

## 8. Key Dependencies

- `dart_monty_platform_interface` — MontySession, MontySnapshotCapable, MockMontyPlatform
- `meta` — annotations
- `collection` — equality helpers
- No Flutter SDK dependency (pure Dart)
