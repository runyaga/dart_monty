// ignore_for_file: avoid_print
import 'package:dart_monty/dart_monty_bridge.dart';

Future<void> main() async {
  final session = AgentSession();
  final result = await session.execute(r'''
jobs = {
    "H1_FND": {"role":"concrete_crew","weather_type":"outdoor","dependencies":[],"status":"pending"},
    "H1_FRM": {"role":"framer","weather_type":"indoor","dependencies":["H1_FND"],"status":"pending"},
    "H1_ROF": {"role":"roofer","weather_type":"outdoor","dependencies":["H1_FRM"],"status":"pending"},
    "H2_FND": {"role":"concrete_crew","weather_type":"outdoor","dependencies":[],"status":"pending"},
    "H2_FRM": {"role":"framer","weather_type":"indoor","dependencies":["H2_FND"],"status":"pending"},
}
workers = {"Bob": "concrete_crew", "Alice": "framer", "Charlie": "roofer"}
weather = ["rain", "sunny", "sunny", "sunny"]
schedule = {}

for i, w in enumerate(weather):
    day = i + 1
    skip_outdoor = (w == "rain")
    ready = [
        name for name, job in jobs.items()
        if job["status"] == "pending" and
           all(jobs[dep]["status"] == "done" for dep in job["dependencies"])
    ]
    used = []
    assignments = []
    for job_name in ready:
        job = jobs[job_name]
        if skip_outdoor and job["weather_type"] == "outdoor":
            continue
        for worker_name, role in workers.items():
            if role == job["role"] and worker_name not in used:
                job["status"] = "done"
                used.append(worker_name)
                assignments.append({"job": job_name, "worker": worker_name})
                break
    schedule[str(day)] = assignments

schedule
''');

  print('Result: ${result.value?.dartValue}');
  if (result.error != null) {
    print('Error: ${result.error}');
    await session.dispose();
    return;
  }

  final sched = result.value?.dartValue as Map;
  print('\nSchedule:');
  for (final e in sched.entries) print('  Day ${e.key}: ${e.value}');

  final jobDays = <String, int>{};
  for (final e in sched.entries) {
    for (final a in e.value as List) {
      jobDays[(a as Map)['job'] as String] = int.parse(e.key as String);
    }
  }
  print('\nH1: FND(${jobDays["H1_FND"]}) → FRM(${jobDays["H1_FRM"]}) → ROF(${jobDays["H1_ROF"]})');
  print('H2: FND(${jobDays["H2_FND"]}) → FRM(${jobDays["H2_FRM"]})');

  final depsOk = (jobDays['H1_FND']! < jobDays['H1_FRM']!) &&
      (jobDays['H1_FRM']! < jobDays['H1_ROF']!) &&
      (jobDays['H2_FND']! < jobDays['H2_FRM']!);
  final day1 = sched['1'] as List;
  final noRainOutdoor = !day1.any((a) {
    final j = (a as Map)['job'] as String;
    return j.contains('FND') || j.contains('ROF');
  });
  final allDone = jobDays.length == 5;

  print('\nDeps valid: $depsOk | No outdoor rain: $noRainOutdoor | All done: $allDone');
  print('VERDICT: ${depsOk && noRainOutdoor && allDone ? "CORRECT ✅" : "INCORRECT ❌"}');

  await session.dispose();
}
