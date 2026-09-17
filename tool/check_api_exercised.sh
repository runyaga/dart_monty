#!/usr/bin/env bash
# =============================================================================
# tool/check_api_exercised.sh — is every public entry point actually PLUMBED?
# =============================================================================
# A mock proves the wiring compiles. It cannot prove the engine can do the
# thing. Monty.compile() had a thorough test file --
# test/unit/platform/monty_compile_test.dart -- written entirely against
# MockMontyPlatform, whose compileCode returns `jsonEncode({'code': code})`.
# Nothing ever called Monty.compile() against FFI or WASM, so the API was green
# in CI and dead in every shipped configuration: native/src/handle.rs:558
# returns Err unconditionally, on every target (core#152).
#
# This asks one question of each public entry point on Monty and MontyRepl:
# does ANY file that runs against a real backend mention it?
#
# THE REAL SURFACE IS THREE DIRECTORIES, NOT ONE. Getting this wrong is how the
# check cries wolf, and a check that cries wolf gets deleted. Measured while
# writing it -- scanning only `test/**/*_test.dart` reported five entry points
# as untested and all five were FALSE:
#
#   test/integration/**   incl. the shared `_*_body.dart` bodies that the
#                         ffi_/wasm_ pairs import -- `typeCheck`,
#                         `resolveFutures` and `resumeAsFuture` live ONLY there
#   example/**            smoke-run by tool/run_example_smoke.sh and by CI --
#                         `clearState` and `detectContinuation` live only here
#   packages/*/lib/**     the conformance runners, driven on real backends by
#                         corpus_js / corpus_wasm / oracle_ffi -- this is the
#                         only caller of `resumeWithException`
#
# The entry-point list is DERIVED from the source, not enumerated here. A
# hand-written list does not grow a row when someone adds a public method, so
# the new method would be exempt from the check by default -- which is the
# failure this exists to prevent, wearing a different hat.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

BASELINE=tool/api-exercised-baseline.txt

python3 - "$BASELINE" <<'PY'
import re, sys, pathlib

baseline_path = pathlib.Path(sys.argv[1])
declared = set()
if baseline_path.exists():
    for line in baseline_path.read_text().splitlines():
        line = line.split('#', 1)[0].strip()
        if line:
            declared.add(line)

# THE SOURCE LIST IS DISCOVERED, NOT ENUMERATED -- and it used to be two
# hard-coded filenames, which is the very failure the header above warns
# about, one level up. The METHOD list was derived; the FILE list was not, so
# a public entry point added to any class other than Monty or MontyRepl was
# exempt from this check by default. Measured, 2026-09-17: the two-file list
# saw 18 entry points; the export closure of the public library sees 37 across
# 33 files, and ELEVEN of the extra ones are not exercised on any real
# backend -- including resumeNameLookupValue(), startPrecompiled() and
# restoreSnapshot(), which is precisely the mock-green/backend-dead shape this
# check was written for.
#
# The closure is the right boundary rather than `lib/**/*.dart`: globbing all
# of lib/ pulls in the FFI and WASM binding layers (416 methods) that no
# consumer calls directly, and a check that cries wolf gets deleted.
def _export_closure(root):
    EXPORT = re.compile(r"^export\s+'([^']+)'", re.M)
    seen, queue = set(), [pathlib.Path(root)]
    while queue:
        f = queue.pop()
        if f in seen or not f.exists():
            continue
        seen.add(f)
        for rel in EXPORT.findall(f.read_text(errors='replace')):
            if rel.startswith(('package:', 'dart:')):
                continue
            queue.append((f.parent / rel).resolve().relative_to(pathlib.Path.cwd()))
    return sorted(str(f) for f in seen)

SOURCES = _export_closure('lib/dart_monty.dart')

# Refuse rather than check a set that collapsed. If an `export` rename or a
# moved file shrinks the closure, every entry point silently disappears and
# this reports a clean pass over nothing.
if len(SOURCES) < 4:
    print(f'FAIL: the public export closure is only {len(SOURCES)} file(s).')
    print('  Expected 4+. A closure that stopped resolving would examine')
    print('  almost nothing and still print PASS.')
    print('  NOTE the floor is low BECAUSE this package is a thin facade: it')
    print('  re-exports dart_monty_core rather than redeclaring it, so its own')
    print('  closure is 5 files against core\'s 33. Raise this floor if that')
    print('  stops being true.')
    sys.exit(1)
# A public method declaration at class-member indentation. `_private` and
# operators are excluded; getters have no parens and are not entry points.
DECL = re.compile(
    r'^  (?:static\s+)?(?:Future<[^>]*>|Stream<[^>]*>|void|[A-Z][\w<>?,\[\] ]*)\s+'
    r'([a-z]\w*)\s*\(', re.M)

# A METHOD IS ONLY A METHOD INSIDE A TYPE BODY.
#
# DECL keys off two-space indentation, and a LOCAL FUNCTION declared inside a
# top-level function body sits at exactly that indentation too. Measured when
# the source list was widened: lib/src/mount/memory_mounted_os_handler.dart
# has no class at all -- `requireParentDir`, `putContent`, `refuseDirectory`,
# `requireFile` and `notMine` are closures inside the factory function
# `memoryMountedOsHandler(...)` at line 72. All five were reported as
# unexercised public entry points. They are not public and not entry points,
# and baselining them would have recorded five exemptions for a parsing
# mistake.
#
# So track type bodies by brace depth and only accept declarations inside one.
TYPE_START = re.compile(
    r'^(?:final\s+|abstract\s+|base\s+|sealed\s+|interface\s+|mixin\s+)*'
    r'(?:class|extension|mixin|enum)\b')

def _methods_in_types(text):
    """Yield method names declared directly inside a class/extension/mixin."""
    names, depth, in_type, type_depth = [], 0, False, 0
    for line in text.splitlines():
        if not in_type and TYPE_START.match(line):
            in_type, type_depth = True, depth
        if in_type and depth == type_depth + 1:
            m = DECL.match(line)
            if m:
                names.append(m.group(1))
        depth += line.count('{') - line.count('}')
        if in_type and depth <= type_depth:
            in_type = False
    return names

entry_points = {}
for src in SOURCES:
    text = pathlib.Path(src).read_text(errors='replace')
    for name in _methods_in_types(text):
        entry_points.setdefault(name, src)

if not entry_points:
    print('FAIL: parsed ZERO public entry points out of:', ', '.join(SOURCES))
    print('  The declaration regex no longer matches this source. A check that')
    print('  silently examines nothing is worse than no check.')
    sys.exit(1)

real_files = []
for pat in ('test/integration/**/*.dart', 'example/*.dart', 'example/*/bin/*.dart'):
    real_files.extend(
        p for p in pathlib.Path('.').glob(pat) if '.dart_tool' not in str(p)
    )
# COMMENTS ARE NOT CALLS.
#
# The match is textual — `.name(` anywhere in a corpus file. A doc comment
# that QUOTES the call it is describing therefore satisfied the check without
# any code running. Caught 2026-09-17 while closing dart_monty's last gap: a
# new test's header comment contained `parent?.emitChildEvent(childHandle,
# event)` as prose, and that alone flipped the entry point to "exercised"
# before the test body was even considered.
#
# That is the same class of defect this check exists to find — something that
# looks like coverage and is not — so strip line and block comments before
# searching. Strings are left alone: a call written inside a string literal is
# vanishingly rare next to a call quoted in a comment, which is routine.
_LINE_COMMENT = re.compile(r'//[^\n]*')
_BLOCK_COMMENT = re.compile(r'/\*.*?\*/', re.S)

def _strip_comments(text):
    return _LINE_COMMENT.sub('', _BLOCK_COMMENT.sub('', text))

corpus = {
    p: _strip_comments(p.read_text(errors='replace')) for p in real_files
}

if len(corpus) < 25:
    print(f'FAIL: the real-backend surface is only {len(corpus)} files.')
    print('  Expected 30+. A glob that stopped matching would mark every')
    print('  entry point unexercised, so refuse rather than report nonsense.')
    sys.exit(1)

unexercised = []
for name in sorted(entry_points):
    hits = sum(1 for s in corpus.values() if re.search(r'\.' + name + r'\s*\(', s))
    if hits == 0:
        unexercised.append(name)

now = set(unexercised)
new = now - declared
stale = declared - now

if new:
    print(f'FAIL: {len(new)} public entry point(s) are not exercised by any')
    print('      file that runs against a real backend:')
    for n in sorted(new):
        print(f'    {n}()  —  declared in {entry_points[n]}')
    print()
    print('  A unit test against MockMontyPlatform does not count, and that is')
    print('  the point: the mock returns whatever it is told to. Add a test')
    print('  under test/integration/, an example/ program, or a conformance')
    print('  driver -- or, if it is genuinely untestable, add the name to')
    print(f'  {baseline_path} with the reason on the same line.')
    sys.exit(1)

if stale:
    print(f'FAIL: {len(stale)} name(s) in {baseline_path} ARE now exercised:')
    for n in sorted(stale):
        print(f'    {n}')
    print('  Delete those lines. A declared exception that no longer applies')
    print('  is a licence nobody is using and everybody inherits.')
    sys.exit(1)

print(f'PASS — {len(entry_points)} public entry points, '
      f'{len(entry_points) - len(now)} exercised on a real backend, '
      f'{len(now)} declared in the baseline.')
PY
