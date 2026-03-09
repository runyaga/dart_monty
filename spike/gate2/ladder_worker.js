/**
 * ladder_worker.js — Runs the full Python ladder + pressure tests
 * against dart_monty_native.wasm via direct C-ABI.
 *
 * Covers: GATE-2 (run), GATE-3 (iterative + futures), GATE-4 (error parity),
 * and stress tests (memory pressure, multi-instance, OOM).
 */

import * as cabi from './cabi.js';

// ---------------------------------------------------------------------------
// Fixture runner
// ---------------------------------------------------------------------------

/**
 * Run a single ladder fixture.
 * Returns { pass, name, tier, id, detail?, elapsed }
 */
function runFixture(fixture) {
  const t0 = performance.now();
  const { id, tier, name, code, expected, expectedContains, expectedSorted,
    expectError, errorContains, externalFunctions, resumeValues,
    resumeErrors, asyncResumeMap, asyncErrorMap, nativeOnly, xfail } = fixture;

  // Determine execution mode
  const hasExtFns = externalFunctions && externalFunctions.length > 0;
  const hasAsync = asyncResumeMap || asyncErrorMap;
  const isIterative = hasExtFns || hasAsync;

  try {
    if (!isIterative) {
      // Simple run-to-completion
      return runSimple(fixture, t0);
    } else if (hasAsync) {
      // Async/futures path
      return runAsync(fixture, t0);
    } else {
      // Iterative start/resume path
      return runIterative(fixture, t0);
    }
  } catch (e) {
    return {
      pass: false, id, tier, name,
      detail: `CRASH: ${e.message}`,
      elapsed: performance.now() - t0,
    };
  }
}

function runSimple(fixture, t0) {
  const { id, tier, name, code, expected, expectedContains, expectedSorted,
    expectError, errorContains } = fixture;

  const cr = cabi.create(code, null, null);
  if (cr.error) {
    if (expectError) {
      const pass = !errorContains || cr.error.includes(errorContains);
      return { pass, id, tier, name, detail: `create error: ${cr.error}`, elapsed: performance.now() - t0 };
    }
    return { pass: false, id, tier, name, detail: `create failed: ${cr.error}`, elapsed: performance.now() - t0 };
  }

  const result = cabi.run(cr.handle);
  cabi.free(cr.handle);

  return checkResult(result, fixture, t0);
}

function runIterative(fixture, t0) {
  const { id, tier, name, code, externalFunctions, resumeValues, resumeErrors } = fixture;

  const extFnStr = externalFunctions.join(',');
  const cr = cabi.create(code, extFnStr, null);
  if (cr.error) {
    return { pass: false, id, tier, name, detail: `create failed: ${cr.error}`, elapsed: performance.now() - t0 };
  }

  let progress = cabi.start(cr.handle);
  let resumeIdx = 0;
  const maxSteps = 50;

  for (let step = 0; step < maxSteps && progress.state === 'pending'; step++) {
    // Decide whether to resume with value or error
    if (resumeErrors && resumeIdx < resumeErrors.length && resumeErrors[resumeIdx] != null) {
      progress = cabi.resumeWithError(cr.handle, resumeErrors[resumeIdx]);
    } else if (resumeValues && resumeIdx < resumeValues.length) {
      const val = resumeValues[resumeIdx];
      progress = cabi.resume(cr.handle, JSON.stringify(val));
    } else {
      progress = cabi.resume(cr.handle, JSON.stringify(null));
    }
    resumeIdx++;
  }

  cabi.free(cr.handle);

  if (progress.state === 'complete') {
    return checkCompleteResult(progress, fixture, t0);
  }
  return { pass: false, id: fixture.id, tier: fixture.tier, name: fixture.name,
    detail: `stuck in state: ${progress.state}`, elapsed: performance.now() - t0 };
}

function runAsync(fixture, t0) {
  const { id, tier, name, code, externalFunctions, asyncResumeMap, asyncErrorMap } = fixture;

  const extFnStr = externalFunctions.join(',');
  const cr = cabi.create(code, extFnStr, null);
  if (cr.error) {
    return { pass: false, id, tier, name, detail: `create failed: ${cr.error}`, elapsed: performance.now() - t0 };
  }

  let progress = cabi.start(cr.handle);
  const maxSteps = 100;

  for (let step = 0; step < maxSteps; step++) {
    if (progress.state === 'complete') break;

    if (progress.state === 'pending') {
      // Pending external function call — resume as future
      progress = cabi.resumeAsFuture(cr.handle);
      continue;
    }

    if (progress.state === 'resolve_futures') {
      // Get pending future IDs
      const callIds = cabi.pendingFutureCallIds(cr.handle);
      if (!callIds || callIds.length === 0) {
        return { pass: false, id, tier, name, detail: 'resolve_futures but no callIds', elapsed: performance.now() - t0 };
      }

      // Build results and errors from fixture maps
      const results = {};
      const errors = {};
      for (const cid of callIds) {
        const cidStr = String(cid);
        if (asyncErrorMap && cidStr in asyncErrorMap) {
          errors[cidStr] = asyncErrorMap[cidStr];
        } else if (asyncResumeMap && cidStr in asyncResumeMap) {
          results[cidStr] = asyncResumeMap[cidStr];
        } else {
          results[cidStr] = null;
        }
      }

      progress = cabi.resumeFutures(cr.handle, results, errors);
      continue;
    }

    if (progress.state === 'error') {
      break;
    }

    break; // unknown state
  }

  cabi.free(cr.handle);

  if (progress.state === 'complete') {
    return checkCompleteResult(progress, fixture, t0);
  }
  if (progress.state === 'error' && fixture.expectError) {
    const pass = !fixture.errorContains || progress.error.includes(fixture.errorContains);
    return { pass, id, tier, name, detail: `error: ${progress.error}`, elapsed: performance.now() - t0 };
  }
  return { pass: false, id, tier, name,
    detail: `ended in state: ${progress.state}, error: ${progress.error || 'none'}`,
    elapsed: performance.now() - t0 };
}

// ---------------------------------------------------------------------------
// Result checking
// ---------------------------------------------------------------------------

function checkResult(result, fixture, t0) {
  const { id, tier, name, expected, expectedContains, expectedSorted,
    expectError, errorContains } = fixture;

  if (!result.ok) {
    // Run-level error (not a Python error in the result JSON)
    if (expectError) {
      const pass = !errorContains || (result.error && result.error.includes(errorContains));
      return { pass, id, tier, name, detail: `run error: ${result.error}`, elapsed: performance.now() - t0 };
    }
    return { pass: false, id, tier, name, detail: `run failed: ${result.error}`, elapsed: performance.now() - t0 };
  }

  // Parse the result JSON — has { value, error?, usage }
  const parsed = result.parsed;
  return _checkParsed(parsed, fixture, t0);
}

function checkCompleteResult(progress, fixture, t0) {
  const parsed = progress.parsed;
  if (!parsed) {
    if (fixture.expectError) {
      const pass = progress.isError;
      return { pass, id: fixture.id, tier: fixture.tier, name: fixture.name,
        detail: 'complete with no result JSON', elapsed: performance.now() - t0 };
    }
    return { pass: false, id: fixture.id, tier: fixture.tier, name: fixture.name,
      detail: 'complete but no result JSON', elapsed: performance.now() - t0 };
  }
  return _checkParsed(parsed, fixture, t0);
}

function _checkParsed(parsed, fixture, t0) {
  const { id, tier, name, expected, expectedContains, expectedSorted,
    expectError, errorContains } = fixture;

  // Check if result has an error
  if (parsed.error) {
    if (expectError) {
      const errMsg = parsed.error.message || parsed.error;
      const pass = !errorContains || String(errMsg).includes(errorContains);
      return { pass, id, tier, name, detail: `error: ${errMsg}`, elapsed: performance.now() - t0 };
    }
    const errMsg = parsed.error.message || JSON.stringify(parsed.error);
    return { pass: false, id, tier, name, detail: `unexpected error: ${errMsg}`, elapsed: performance.now() - t0 };
  }

  if (expectError) {
    return { pass: false, id, tier, name, detail: `expected error but got value: ${JSON.stringify(parsed.value)}`,
      elapsed: performance.now() - t0 };
  }

  const value = parsed.value;

  // expectedContains check
  if (expectedContains != null) {
    const valStr = typeof value === 'string' ? value : JSON.stringify(value);
    const pass = valStr.includes(expectedContains);
    return { pass, id, tier, name,
      detail: pass ? undefined : `expected "${expectedContains}" in "${valStr}"`,
      elapsed: performance.now() - t0 };
  }

  // expectedSorted check
  if (expectedSorted && Array.isArray(expected) && Array.isArray(value)) {
    const sortedExpected = [...expected].sort();
    const sortedValue = [...value].sort();
    const pass = JSON.stringify(sortedExpected) === JSON.stringify(sortedValue);
    return { pass, id, tier, name,
      detail: pass ? undefined : `sorted mismatch: ${JSON.stringify(sortedValue)} vs ${JSON.stringify(sortedExpected)}`,
      elapsed: performance.now() - t0 };
  }

  // Exact match
  if (expected != null) {
    const pass = JSON.stringify(value) === JSON.stringify(expected);
    return { pass, id, tier, name,
      detail: pass ? undefined : `expected ${JSON.stringify(expected)}, got ${JSON.stringify(value)}`,
      elapsed: performance.now() - t0 };
  }

  // No expected value — just check no error
  return { pass: true, id, tier, name, elapsed: performance.now() - t0 };
}

// ---------------------------------------------------------------------------
// Pressure tests
// ---------------------------------------------------------------------------

function runPressureTests() {
  const results = [];

  // ST-1: Multi-instance — create N handles concurrently
  {
    const t0 = performance.now();
    const N = 10;
    const handles = [];
    let ok = true;
    for (let i = 0; i < N; i++) {
      const cr = cabi.create(`${i} + ${i}`, null, null);
      if (cr.error) { ok = false; break; }
      handles.push(cr.handle);
    }
    // Run each
    const values = [];
    for (const h of handles) {
      const r = cabi.run(h);
      if (r.ok) values.push(r.parsed.value);
      cabi.free(h);
    }
    const expected = Array.from({ length: N }, (_, i) => i + i);
    const pass = ok && JSON.stringify(values) === JSON.stringify(expected);
    results.push({
      name: `ST-1: ${N} concurrent handles`,
      pass,
      detail: pass ? `${N} handles, all correct` : `values: ${JSON.stringify(values)}`,
      elapsed: performance.now() - t0,
    });
  }

  // ST-2: Rapid create/free cycle (leak test)
  {
    const t0 = performance.now();
    const N = 100;
    let ok = true;
    for (let i = 0; i < N; i++) {
      const cr = cabi.create(`${i}`, null, null);
      if (cr.error) { ok = false; break; }
      const r = cabi.run(cr.handle);
      if (!r.ok || r.parsed.value !== i) { ok = false; }
      cabi.free(cr.handle);
    }
    results.push({
      name: `ST-2: ${N} rapid create/run/free cycles`,
      pass: ok,
      elapsed: performance.now() - t0,
    });
  }

  // ST-3: OOM behavior — allocate impossible amount
  {
    const t0 = performance.now();
    const cr = cabi.create('x = [0] * 999999999999', null, null);
    let pass = false;
    let detail;
    if (cr.error) {
      pass = true;
      detail = `create-time OOM: ${cr.error}`;
    } else {
      const r = cabi.run(cr.handle);
      cabi.free(cr.handle);
      // Either an error result or a trap is acceptable
      pass = !r.ok || (r.parsed && r.parsed.error);
      detail = r.ok ? `value: ${JSON.stringify(r.parsed?.value)}` : `error: ${r.error}`;
    }
    results.push({
      name: 'ST-3: OOM behavior (huge allocation)',
      pass,
      detail,
      elapsed: performance.now() - t0,
    });
  }

  // ST-4: Empty code
  {
    const t0 = performance.now();
    const cr = cabi.create('', null, null);
    let pass;
    let detail;
    if (cr.error) {
      pass = true;
      detail = `create error: ${cr.error}`;
    } else {
      const r = cabi.run(cr.handle);
      cabi.free(cr.handle);
      pass = r.ok;
      detail = `result: ${r.json}`;
    }
    results.push({
      name: 'ST-4: Empty code',
      pass,
      detail,
      elapsed: performance.now() - t0,
    });
  }

  // ST-5: Syntax error
  {
    const t0 = performance.now();
    const cr = cabi.create('def (broken', null, null);
    let pass = false;
    let detail;
    if (cr.error) {
      pass = true;
      detail = `create error: ${cr.error}`;
    } else {
      const r = cabi.run(cr.handle);
      cabi.free(cr.handle);
      pass = !r.ok || (r.parsed && r.parsed.error);
      detail = r.ok ? `unexpected success: ${r.json}` : `error: ${r.error}`;
    }
    results.push({
      name: 'ST-5: Syntax error handling',
      pass,
      detail,
      elapsed: performance.now() - t0,
    });
  }

  // ST-6: BigInt u64 — handle ID should be non-zero
  {
    const t0 = performance.now();
    const cr = cabi.create('42', null, null);
    let pass = false;
    let detail;
    if (!cr.error) {
      const handleId = wasm.monty_get_handle_id(cr.handle);
      // WASM i64 returns BigInt in JS
      pass = handleId > 0n || handleId > 0;
      detail = `handleId = ${handleId} (type: ${typeof handleId})`;
      cabi.free(cr.handle);
    } else {
      detail = cr.error;
    }
    results.push({
      name: 'ST-6: BigInt u64 handle ID',
      pass,
      detail,
      elapsed: performance.now() - t0,
    });
  }

  // ST-7: Cancel flag (set and check)
  {
    const t0 = performance.now();
    const cr = cabi.create('42', null, null);
    let pass = false;
    let detail;
    if (!cr.error) {
      const before = wasm.monty_is_cancelled(cr.handle);
      wasm.monty_cancel(cr.handle);
      const after = wasm.monty_is_cancelled(cr.handle);
      wasm.monty_reset_cancel(cr.handle);
      const reset = wasm.monty_is_cancelled(cr.handle);
      pass = before === 0 && after === 1 && reset === 0;
      detail = `before=${before}, after=${after}, reset=${reset}`;
      cabi.free(cr.handle);
    } else {
      detail = cr.error;
    }
    results.push({
      name: 'ST-7: Cancel flag set/check/reset',
      pass,
      detail,
      elapsed: performance.now() - t0,
    });
  }

  return results;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

let wasm; // reference for pressure tests that need raw exports

async function main() {
  self.postMessage({ type: 'status', message: 'Loading WASM...' });
  const wasmUrl = new URL('./dart_monty_native.wasm', import.meta.url);
  wasm = await cabi.loadWasm(wasmUrl);
  self.postMessage({ type: 'status', message: `WASM loaded. ${Object.keys(wasm).length} exports.` });

  // Load all fixture files
  const tierFiles = [
    'tier_01_expressions.json',
    'tier_02_variables.json',
    'tier_03_control_flow.json',
    'tier_04_functions.json',
    'tier_05_errors.json',
    'tier_06_external_fns.json',
    'tier_07_advanced.json',
    'tier_08_kwargs.json',
    'tier_09_exceptions.json',
    'tier_13_async.json',
    'tier_15_script_name.json',
    'tier_16_memory_growth.json',
  ];

  const fixturesUrl = new URL('../../test/fixtures/python_ladder/', import.meta.url);
  const allFixtures = [];

  for (const file of tierFiles) {
    try {
      const resp = await fetch(new URL(file, fixturesUrl));
      if (resp.ok) {
        const fixtures = await resp.json();
        allFixtures.push(...fixtures);
      } else {
        self.postMessage({ type: 'status', message: `Skip ${file}: ${resp.status}` });
      }
    } catch (e) {
      self.postMessage({ type: 'status', message: `Error loading ${file}: ${e.message}` });
    }
  }

  self.postMessage({ type: 'status', message: `Loaded ${allFixtures.length} fixtures from ${tierFiles.length} tiers.` });

  // Run ladder
  const ladderResults = [];
  for (const fixture of allFixtures) {
    const result = runFixture(fixture);

    // Mark xfail
    if (fixture.xfail) {
      result.xfail = fixture.xfail;
      if (!result.pass) result.pass = 'xfail'; // expected failure
    }

    ladderResults.push(result);
    self.postMessage({ type: 'fixture', result });
  }

  // Summarize ladder
  const pass = ladderResults.filter(r => r.pass === true).length;
  const fail = ladderResults.filter(r => r.pass === false).length;
  const xfail = ladderResults.filter(r => r.pass === 'xfail').length;
  const total = ladderResults.length;

  self.postMessage({
    type: 'ladder_summary',
    pass, fail, xfail, total,
    failures: ladderResults.filter(r => r.pass === false),
  });

  // Run pressure tests
  self.postMessage({ type: 'status', message: '\nRunning pressure tests...' });
  const pressureResults = runPressureTests();
  for (const r of pressureResults) {
    self.postMessage({ type: 'pressure', result: r });
  }

  self.postMessage({
    type: 'pressure_summary',
    pass: pressureResults.filter(r => r.pass).length,
    fail: pressureResults.filter(r => !r.pass).length,
    total: pressureResults.length,
    failures: pressureResults.filter(r => !r.pass),
  });

  self.postMessage({ type: 'done' });
}

main().catch((e) => {
  self.postMessage({ type: 'error', message: `Worker crash: ${e.message}\n${e.stack}` });
});
