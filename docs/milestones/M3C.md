# M3C: Cross-Platform Parity and Python Ladder

## Goal

Exhaustive cross-platform testing: identical Python code must produce
identical results on native FFI and WASM paths. Snapshot portability
between native and WASM.

## Prerequisites

- M3A (Native FFI package) complete
- M3B (Web spike) passes GO decision

## Deliverables

- Cross-path parity test suite
- Python compatibility ladder (Tiers 1-6)
- Snapshot portability tests (native <-> WASM)
- `tool/test_cross_path_parity.sh`
- `tool/test_python_ladder.sh`
- `tool/test_snapshot_portability.sh`

## Work Items

### 3C.1 Cross-Path Parity Tests

Run identical Python code through native FFI and web WASM, assert identical
results:

- [ ] Arithmetic, string ops, collections, builtins
- [ ] External functions: register, poll/resume
- [ ] Resource limits: same error on both paths
- [ ] Error handling: same error structure on both paths
- [ ] Snapshot parity: create on native, restore on WASM (and reverse)

### 3C.2 Python Compatibility Ladder

Growing test suite in `test/fixtures/python_ladder/`:

| Tier | Feature | Gate |
|------|---------|------|
| 1 | Expressions | M3C |
| 2 | Variables and collections | M3C |
| 3 | Control flow | M3C |
| 4 | Functions | M3C |
| 5 | Error handling | M3C |
| 6 | External functions | M3C |
| 7+ | Classes, async, etc. | Future milestones |

### 3C.3 Snapshot Portability

- [ ] Create snapshot via Dart FFI (native library)
- [ ] Restore snapshot in browser (Monty WASM)
- [ ] Verify same result on both paths
- [ ] If NOT portable: document as limitation

### 3C.4 Automation

- [ ] `tool/test_cross_path_parity.sh`
- [ ] `tool/test_python_ladder.sh --tiers=1-6`
- [ ] `tool/test_snapshot_portability.sh`
- [ ] Shared JSON test fixtures consumed by both native and browser runners

## Quality Gate

```bash
tool/test_cross_path_parity.sh
tool/test_python_ladder.sh --tiers=1-6
tool/test_snapshot_portability.sh
```
