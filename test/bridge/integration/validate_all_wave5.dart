// ignore_for_file: avoid_print
/// Run all 4 wave5 experiments — generate code, show it, execute, validate.
import 'dart:io';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:fe_plugin_soliplex/fe_plugin_soliplex.dart';
import 'package:soliplex_client/soliplex_client.dart';

Future<void> main() async {
  final transport = HttpTransport(client: DartHttpClient());
  final localUrl = UrlBuilder('http://localhost:8000/api/v1');

  final session = AgentSession(
    os: OsProvider.compose({'Path.': MemoryFsProvider()}),
    plugins: [
      SoliplexPlugin(
        connections: {
          'local': SoliplexConnection(
            api: SoliplexApi(transport: transport, urlBuilder: localUrl),
            streamClient: AgUiStreamClient(
              httpTransport: transport,
              urlBuilder: localUrl,
            ),
          ),
        },
      ),
      MessageBusPlugin(),
      DinjaTemplatePlugin(),
    ],
  );

  // Read files
  const base =
      '/Users/runyaga/dev/soliplex-plans/tui-experiments/ioi-experiments';
  final rules = File(
    '/Users/runyaga/dev/dart_monty/main/docs/monty-prompt-rules.md',
  ).readAsStringSync();
  final experiments = {
    'baseline': File('$base/wave5-construction-baseline.txt')
        .readAsStringSync(),
    'schedule': File('$base/wave5-construction-schedule.txt')
        .readAsStringSync(),
    'disruption': File('$base/wave5-construction-disruption.txt')
        .readAsStringSync(),
    'infeasible': File('$base/wave5-construction-infeasible.txt')
        .readAsStringSync(),
  };

  // Setup thread + uploads
  print('=== SETUP ===');
  var r = await session.execute('''
import json
t = json.loads(soliplex_new_thread("local", "bwrap_sandbox", "Wave5 construction experiments."))
thread = t["thread_id"]
thread
''');
  print('Thread: ${r.value?.dartValue}');

  await _upload(session, 'monty-rules.md', rules);
  for (final e in experiments.entries) {
    await _upload(session, '${e.key}.txt', e.value);
  }
  print('All files uploaded.\n');

  // === Experiment 1: Baseline ===
  await _runExperiment(
    session,
    '1. BASELINE',
    'Read monty-rules.md for coding rules. Read baseline.txt for the problem. '
        'Write a monty program that solves the construction scheduling. '
        'Rules: use = not :=, use enumerate(x) not enumerate(x, start=N), '
        'use d["key"] not d.key. '
        'Track jobs as dict, loop day by day, check weather/deps/workers. '
        'Last expression = the schedule dict.',
  );

  // === Experiment 2: Optimal Schedule ===
  await _runExperiment(
    session,
    '2. OPTIMAL SCHEDULE',
    'Read schedule.txt. Write monty code for OPTIMAL scheduling — finish ASAP. '
        'Same rules. Greedy: each day assign max ready jobs. '
        'Remember: = not :=, enumerate(x) not enumerate(x, start=1), d["key"] not d.key. '
        'Last expression = schedule dict.',
  );

  // === Experiment 3: Disruption ===
  await _runExperiment(
    session,
    '3. DISRUPTION',
    'Read disruption.txt. Simulate day-by-day with disruptions. '
        'Alice the framer is sick on day 2 — skip her jobs that day. '
        'Same rules: = not :=, enumerate(x), d["key"]. '
        'Track executed_schedule and disruptions list. '
        'Last expression = {"executed_schedule": ..., "disruptions": [...]}.',
  );

  // === Experiment 4: Infeasible ===
  await _runExperiment(
    session,
    '4. INFEASIBLE ANALYSIS',
    'Read infeasible.txt. 5 houses x 3 jobs = 15 jobs, 3 workers, 3-day deadline, day 1 rain. '
        'Do NOT try to schedule — analyze feasibility mathematically. '
        'Count: max worker-days = 3 workers x 3 days = 9 slots. '
        'But 15 jobs needed. 9 < 15, so infeasible. '
        'Same rules: = not :=, d["key"]. '
        'Last expression = {"status": "infeasible"/"feasible", "reason": "...", "analysis": {...}}.',
  );

  await session.dispose();
  transport.close();
  print('\n=== ALL DONE ===');
}

Future<void> _upload(AgentSession session, String name, String content) async {
  final escaped =
      content.replaceAll('\\', '\\\\').replaceAll("'''", "\\'\\'\\'");
  await session.execute("""
import json
soliplex_upload_to_thread("local", "bwrap_sandbox", thread, "$name", '''$escaped''')
"ok"
""");
  print('  Uploaded $name');
}

Future<void> _runExperiment(
  AgentSession session,
  String title,
  String prompt,
) async {
  print('=== $title ===');

  // Ask bwrap to generate code
  final gen = await session.execute('''
import json
resp = json.loads(soliplex_reply_thread(
    "local", "bwrap_sandbox", thread,
    ${_pyQuote(prompt + ' Return ONLY code in a ```monty``` block.')}
))
gen_response = resp["response"]
gen_response
''');

  if (gen.value?.dartValue == null) {
    print('  null response — server may be slow\n');

    return;
  }

  // Extract code
  final extract = await session.execute(r'''
import re
pattern = r"```(?:monty|python)\s*\n(.*?)```"
match = re.search(pattern, gen_response, re.DOTALL)
if match:
    code = match.group(1).strip()
elif gen_response.strip().startswith("```"):
    lines = gen_response.strip().split("\n")
    cl = []
    started = False
    for line in lines:
        if not started and line.strip().startswith("```"):
            started = True
            continue
        if started and line.strip() == "```":
            break
        if started:
            cl.append(line)
    code = "\n".join(cl) if cl else None
elif "schedule" in gen_response or "jobs" in gen_response:
    code = gen_response.strip()
else:
    code = None
code
''');

  final code = extract.value?.dartValue as String?;
  if (code == null) {
    print('  No code extracted\n');

    return;
  }

  print('--- GENERATED CODE (${code.length} chars) ---');
  print(code);
  print('--- END CODE ---\n');

  // Execute
  final result = await session.execute(code);
  if (result.error != null) {
    print('  EXECUTION ERROR: ${result.error}');
    print('  (This is a monty limitation or code bug)\n');

    return;
  }

  print('--- RESULT ---');
  print(result.value?.dartValue);
  if (result.printOutput?.isNotEmpty ?? false) {
    print('--- PRINT OUTPUT ---');
    print(result.printOutput);
  }
  print('--- END ---\n');
}

String _pyQuote(String s) {
  final escaped = s.replaceAll('\\', '\\\\').replaceAll('"', '\\"');

  return '"$escaped"';
}
