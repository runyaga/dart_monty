#!/usr/bin/env bash
# =============================================================================
# Unified Quality Gate — dart_monty (single-package)
# =============================================================================
# Single script that runs EVERY quality check. Must pass before any PR merges.
# Gracefully skips checks when toolchains are missing (cargo, Chrome, dcm)
# but Dart gates always run.
#
# Usage: bash tool/gate.sh
#        bash tool/gate.sh --dart-only    # Skip Rust, WASM, web integration
# =============================================================================
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

DART_ONLY=false
if [[ "${1:-}" == "--dart-only" ]]; then
  DART_ONLY=true
fi

FAILED=()
SKIPPED=()

# Helper: run a check, track failures
run_check() {
  local name="$1"
  shift
  echo ""
  echo "========================================"
  echo "  $name"
  echo "========================================"
  # EXIT 77 MEANS "DID NOT RUN", AND IT IS NOT A PASS.
  #
  # This was binary -- exit 0 PASSED, anything else FAILED -- so a check that
  # deliberately skipped itself reported PASSED. With the DCM licence quota
  # exhausted that mattered: `DCM_ALLOW_MISSING=1 bash tool/gate.sh` would print
  # PASSED for two ratchets that had verified none of the 253 findings they
  # own. A skip is still green -- it is an opted-in decision, not a failure --
  # but it has to be VISIBLE as a skip, or the summary lies by omission.
  if "$@"; then
    echo "  -> PASSED"
  else
    local rc=$?
    if [ "$rc" -eq 77 ]; then
      echo "  -> SKIPPED (did not run, checked nothing)"
      SKIPPED+=("$name — did not run, checked nothing")
    else
      echo "  -> FAILED"
      FAILED+=("$name")
    fi
  fi
}

# Helper: run a test check WITH A FLOOR under how many tests must register.
#
# A SUITE THAT REGISTERS NOTHING PRINTS SUCCESS AND EXITS 0. ci.yaml has
# guarded that since its four `assert_test_count.sh` calls (unit 450,
# integration 290, example 4, wasm 8). THIS GATE DID NOT — measured
# 2026-09-17, `grep -c assert_test_count tool/gate.sh` was 0 — so the run that
# is the precondition for every commit here would have gone green on a suite
# that registered zero tests. Same gap, same fix, as dart_monty_core bedbd87.
#
# The floor is set UNDER the observed count so ordinary churn does not trip
# it. Raise it when the suite grows; never lower it to make a run pass.
run_test_check() {
  local name="$1"
  local min="$2"
  shift 2
  local log
  log="$(mktemp)"
  echo ""
  echo "========================================"
  echo "  $name"
  echo "========================================"
  # RUN IT INSIDE A CONDITIONAL. This script is `set -e`, so a bare failing
  # pipeline ABORTS the gate instead of recording FAILED — measured: a suite
  # that exits 79 ("no tests ran") killed the whole run at rc 79, skipping
  # every later check and printing no summary. `set -e` is suspended inside an
  # `if` condition, which is why the original run_check has always used one.
  local rc=0
  if "$@" 2>&1 | tee "$log"; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    # Only when the suite itself passed. Layering a count complaint on top of
    # a real failure buries the diagnosis.
    if bash tool/assert_test_count.sh "$log" "$min" "$name"; then
      echo "  -> PASSED"
    else
      echo "  -> FAILED"
      FAILED+=("$name")
    fi
  elif [ "$rc" -eq 77 ]; then
    echo "  -> SKIPPED (did not run, checked nothing)"
    SKIPPED+=("$name — did not run, checked nothing")
  else
    echo "  -> FAILED"
    FAILED+=("$name")
  fi
  rm -f "$log"
}

# Helper: skip a check
skip_check() {
  local name="$1"
  local reason="$2"
  echo ""
  echo "========================================"
  echo "  $name — SKIPPED ($reason)"
  echo "========================================"
  SKIPPED+=("$name")
}

# -------------------------------------------------------
# 0. Resolve nested packages
# -------------------------------------------------------
# BEFORE format and analyze, because both of them read example/ and
# example/web/ and the root `dart pub get` resolves only the first of those.
# CI run 35144134742 failed with 21 unresolved-URI errors in example/web while
# this gate was green on a laptop — the laptop had example/web resolved from an
# earlier run. Reproduced on a pristine clone. A gate whose result depends on
# leftover state is not a gate.
run_check "resolve nested packages" bash tool/resolve_packages.sh

# -------------------------------------------------------
# 1. Dart Format
# -------------------------------------------------------
# --output=none is REQUIRED: without it `dart format` rewrites files even
# with --set-exit-if-changed, so the "check" silently mutates the tree.
run_check "dart format" dart format --output=none --set-exit-if-changed .

# -------------------------------------------------------
# 2. Dart Analyze
# -------------------------------------------------------
run_check "dart analyze" dart analyze --fatal-infos

# -------------------------------------------------------
# 3. Dart Doc Validate Links
# -------------------------------------------------------
run_check "dart doc --validate-links" dart doc --validate-links .
# FOUR files declare the dart_monty_core ref and nothing compared them:
# example/pubspec.yaml sat 197 commits behind while the root was on 0.23, so the
# examples compiled this package against a core with no `asStringMap`, and
# pages.yaml sat 315 behind. The local gate cannot see either — it never
# resolves example/ or example/web — which is why the guard checks the
# DECLARATIONS rather than waiting for a build. It discovers the files rather
# than listing them, because its predecessor listed two and passed green on a
# tree with a 197-commit disagreement.
run_check "core ref agreement" bash tool/check_core_ref.sh
# actionlint over every workflow. Ported from dart_monty_core, where it exists
# because a malformed workflow does not fail — it silently stops running, and a
# job that never starts reports nothing at all.
run_check "workflows valid" bash tool/check_workflows_valid.sh
# Pages copies from five locations and compiles seven entrypoints. A missing
# one fails the DEPLOY, and GitHub Pages hides that by continuing to serve
# the last good build — so it reads as "the site is stale", not "the site is
# broken". The live site was last built 2026-06-02.
run_check "pages inputs" bash tool/check_pages_inputs.sh
# The site is the one artefact a user meets without a pubspec in front of
# them, so "the demo is broken" and "the demo is old" are indistinguishable
# without a version on the page. Hand-written and CHECKED, not injected: a
# placeholder that stops matching fails silently, which is exactly how a
# __BUILD_DATE__ sed sat in pages.yaml substituting nothing.
run_check "page versions" bash tool/check_page_versions.sh
run_check "html escaping" bash tool/check_html_escaping.sh
# Every published demo must actually RUN. Measured 2026-09-16: the four native
# examples were executed, the seven web entrypoints were COMPILED AND NEVER
# RUN, and the eight published pages were exercised by nothing at all. A demo
# that compiles can still throw on load, 404 its own .dart.js, or fail to boot
# WASM — and async_matrix_demo.dart.js did 404 on the live site while its page
# returned 200. This assembles the site and drives headless Chrome at every
# page. Exits 77 (a VISIBLE skip) when no browser is installed.
run_check "demo pages boot" bash tool/check_demo_pages.sh
# Ported from dart_monty_core. It asks one question of every public entry
# point in lib/dart_monty.dart's export closure: does ANY file that runs
# against a real backend call it? A unit test against a mock does not count —
# that is the whole point, and in core the same check found six entry points
# green on a mock and unproven on FFI/WASM.
run_check "api exercised" bash tool/check_api_exercised.sh

# -------------------------------------------------------
# 4. Pymarkdown (all markdown files)
# -------------------------------------------------------
if command -v pymarkdown &>/dev/null; then
  run_check "pymarkdown scan" pymarkdown \
    --set "extensions.front-matter.enabled=\$!True" \
    --disable-rules MD013,MD024,MD033,MD036,MD041,MD060 \
    scan docs/*.md
else
  skip_check "pymarkdown scan" "pymarkdown not installed (pip install pymarkdownlnt)"
fi

# -------------------------------------------------------
# 5. Gitleaks (secret detection)
# -------------------------------------------------------
if command -v gitleaks &>/dev/null; then
  run_check "gitleaks detect" gitleaks detect --no-banner
else
  skip_check "gitleaks detect" "gitleaks not installed"
fi

# -------------------------------------------------------
# 6. DCM (Dart Code Metrics) — requires dcm installed
# -------------------------------------------------------
# Helper: advisory check (reports but does not fail gate)
run_advisory() {
  local name="$1"
  shift
  echo ""
  echo "========================================"
  echo "  $name (advisory)"
  echo "========================================"
  if "$@"; then
    echo "  -> CLEAN"
  else
    echo "  -> ISSUES FOUND (advisory — not blocking gate)"
  fi
}

# DCM RUNS ON THE HOST, NOT IN THE CONTAINER.
#
# The container ships dcm 1.37.0; both baselines here were generated by 1.39.0,
# the version this project standardises on. dcm_ratchet.sh pins the version on
# purpose -- counts are not comparable across releases -- so an in-container run
# can only ever produce "dcm version mismatch", which is a failure about the
# toolchain rather than about the code. Measured 2026-09-16 on integration/0.23:
# that was the single FAILED check in an otherwise 10-pass gate.
#
# So: detect the container and SKIP, visibly. A skip is green -- it is an
# opted-in decision -- but it must never read as a pass, because these two
# ratchets own 253 findings between them and a skipped run has verified none.
dcm_in_container() { [ -e /run/.containerenv ] || [ -e /.dockerenv ]; }

# ONE NAME FOR ONE DECISION. There were three: this file honoured
# DCM_ALLOW_MISSING, tool/dcm_ratchet.sh honoured DCM_RATCHET_ALLOW_MISSING and
# tool/dcm_suite_ratchet.sh honoured DCM_SUITE_ALLOW_MISSING -- and the
# DCM_ALLOW_MISSING branch below is an `elif` reached ONLY when `dcm` is absent.
#
# So in the common blocked case -- dcm installed but the licence expired or the
# CI-key quota exhausted -- control took the `command -v dcm` branch, ran the
# ratchets, and DCM_ALLOW_MISSING did nothing at all. Measured 2026-09-17
# against "CI key limit for this month has been exceeded":
#
#     bash tool/gate.sh                      -> FAILED (dcm ratchet, dcm suite)
#     DCM_ALLOW_MISSING=1 bash tool/gate.sh  -> FAILED, identically, rc=1
#
# That is the variable dcm_ratchet.sh:73 PRINTS as the remedy, from inside a
# branch gated on a different one. Following the instruction the gate gives you
# could not work. Forwarding it is the fix: the opt-out stays deliberate and
# stays loud -- each ratchet still reports its own SKIP and "checked nothing" --
# but the documented name now reaches the scripts that act on it.
if [ "${DCM_ALLOW_MISSING:-0}" = "1" ]; then
  export DCM_RATCHET_ALLOW_MISSING=1
  export DCM_SUITE_ALLOW_MISSING=1
fi

if dcm_in_container; then
  skip_check "dcm ratchet"       "DCM runs on the host: bash tool/dcm_host_gate.sh"
  skip_check "dcm suite ratchet" "DCM runs on the host: bash tool/dcm_host_gate.sh"
elif command -v dcm &>/dev/null; then
  # Blocking: 98 lint rules, must be zero issues
  # Ratchet, not a clean run: `dcm analyze lib` has 9 pre-existing issues, so a
  # zero-issue gate could never pass and a raw count hides new issues behind
  # net improvements. Fails only on NEW issues above tool/dcm-baseline.json.
  run_check "dcm ratchet" bash tool/dcm_ratchet.sh
  # BLOCKING, baselined. These five used to be `run_advisory` -- report, never
  # fail -- and two more (check-exports-completeness,
  # check-unnecessarily-public-code) were not run at all. Measured 2026-09-15,
  # the unenforced total was 244:
  #
  #     calculate-metrics                 29      advisory
  #     check-parameters                  45      advisory
  #     check-unused-code                  7      advisory
  #     check-dependencies                 6      advisory
  #     check-unused-files                 3      advisory
  #     check-exports-completeness         4      NOT RUN
  #     check-unnecessarily-public-code  150      NOT RUN
  #
  # An advisory check is a check whose output nobody reads twice. Ratcheted
  # instead: a new rule, a per-rule increase, a new file or a per-file increase
  # fails; reducing is always allowed but must be CAPTURED, or the count drifts
  # back up while the gate stays green.
  run_check "dcm suite ratchet" bash tool/dcm_suite_ratchet.sh

  # Upload to DCM dashboard (main branch only, requires DCM_PROJECT_KEY)
  if [[ "${DCM_PROJECT_KEY:-}" != "" ]]; then
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    if [[ "$CURRENT_BRANCH" == "main" ]]; then
      echo ""
      echo "========================================"
      echo "  DCM dashboard upload"
      echo "========================================"
      dcm run lib \
        --all \
        --upload \
        --project="$DCM_PROJECT_KEY" \
        --email="${DCM_EMAIL:-}" \
        --ci-key="${DCM_CI_KEY:-}" \
        && echo "  -> UPLOADED" \
        || echo "  -> UPLOAD FAILED (non-blocking)"
    else
      echo ""
      echo "  DCM dashboard: skipped (not on main, branch=$CURRENT_BRANCH)"
    fi
  fi
elif [ "${DCM_ALLOW_MISSING:-0}" = "1" ]; then
  # DELIBERATE opt-out, and it is loud. DCM is now the enforcement mechanism for
  # 253 findings across eight checks (9 lint + 244 suite), so `dcm` being absent
  # means this gate verified none of them. That is a decision the caller makes
  # explicitly, never one the gate makes on the caller's behalf.
  skip_check "dcm" "dcm absent, SKIPPED ON PURPOSE (DCM_ALLOW_MISSING=1) — 253 findings unchecked"
else
  # NOT a skip. `if command -v dcm` used to fall through to skip_check here, so
  # a machine without dcm got a green gate that had checked nothing DCM-related
  # -- and dcm is commercial, so that is the common case for a new contributor
  # rather than an exotic one. A gate that decides on its own to check nothing
  # is not a gate.
  echo ""
  echo "FAIL: dcm is not installed, and it now enforces 253 findings"
  echo "      (tool/dcm-baseline.json 9 + tool/dcm-suite-baseline.json 244)."
  echo "  Install:  brew tap CQLabs/dcm && brew install dcm"
  echo "  dcm is NOT a pub package — 'dart pub global activate dcm' cannot work."
  echo "  It also needs credentials, because it is commercial:"
  echo "    export DCM_CI_KEY=...   # the CI key, NOT a license-key"
  echo "    export DCM_EMAIL=...    # the purchase email"
  echo "  To run the gate anyway, knowing it then checks none of those 253:"
  echo "    DCM_ALLOW_MISSING=1 bash tool/gate.sh"
  FAILED+=("dcm not installed")
fi

# -------------------------------------------------------
# 7. Dart Tests (unit)
# -------------------------------------------------------
# Floor 500: 530 tests observed locally 2026-09-17.
run_test_check "dart test" 500 dart test

# -------------------------------------------------------
# 8. Rust Gate — skip if no cargo
# -------------------------------------------------------
if [[ "$DART_ONLY" == true ]]; then
  skip_check "Rust gate" "--dart-only flag"
elif command -v cargo &>/dev/null; then
  run_check "Rust gate" bash tool/test_rust.sh
else
  skip_check "Rust gate" "cargo not installed"
fi

# -------------------------------------------------------
# 9. Python Ladder Parity — skip if --dart-only
# -------------------------------------------------------
if [[ "$DART_ONLY" == true ]]; then
  skip_check "Python ladder parity" "--dart-only flag"
else
  run_check "Python ladder parity" bash tool/test_python_ladder.sh
fi

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
echo ""
echo "========================================"
echo "  GATE SUMMARY"
echo "========================================"

if [ ${#SKIPPED[@]} -gt 0 ]; then
  echo ""
  echo "  Skipped (${#SKIPPED[@]}):"
  for s in "${SKIPPED[@]}"; do
    echo "    - $s"
  done
fi

if [ ${#FAILED[@]} -gt 0 ]; then
  echo ""
  echo "  FAILED (${#FAILED[@]}):"
  for f in "${FAILED[@]}"; do
    echo "    - $f"
  done
  echo ""
  echo "  GATE: FAILED"
  exit 1
fi

echo ""
echo "  GATE: PASSED (${#SKIPPED[@]} skipped)"
exit 0
