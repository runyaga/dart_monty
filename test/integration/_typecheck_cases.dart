import 'package:dart_monty/dart_monty.dart';

const typecheckStubs = '''
from typing import Literal, TypedDict

AssetKind = Literal['courier_drone', 'relay_balloon', 'cargo_glider', 'hopper_skiff']
RoleKind = Literal['pilot', 'rigger', 'navigator', 'loader']
TaskKind = Literal['asset', 'crew', 'cert', 'fuel', 'weather', 'conflict']

class Trip(TypedDict):
    trip_id: str
    day: int
    origin_cell: str
    dest_cell: str
    asset_kind: AssetKind
    roles: list[RoleKind]
    window_start_hr: int
    window_end_hr: int

class Asset(TypedDict):
    asset_id: str
    kind: AssetKind
    home_cell: str
    max_leg_steps: int
    burn_per_step: int
    tank_sparks: int
    available_days: list[int]

class CrewSlot(TypedDict):
    role: RoleKind
    staff_id: str

class Assignment(TypedDict):
    trip_id: str
    day: int
    asset_id: str | None
    crew: list[CrewSlot]
    window_start_hr: int
    window_end_hr: int

class OpenTask(TypedDict):
    task_id: str
    kind: TaskKind
    subject: str
    reason: str

class RouteConstraints(TypedDict):
    max_leg_steps: int
    avoid_cells: list[str]
    require_chargers: bool

class Leg(TypedDict):
    leg_index: int
    from_cell: str
    to_cell: str
    steps: int
    recharge_at_dest: bool

class Route(TypedDict):
    route_id: str
    origin_cell: str
    dest_cell: str
    legs: list[Leg]
    total_steps: int

def get_trip(trip_id: str) -> Trip: ...
def get_assignment(trip_id: str) -> Assignment: ...
def find_assets(kind: AssetKind, cell_id: str, day: int) -> list[Asset]: ...
def assign_crew(trip_id: str, role: RoleKind, staff_id: str) -> Assignment: ...
def plan_route(origin: str, dest: str, constraints: RouteConstraints) -> Route: ...
def fuel_estimate(asset: Asset, route: Route) -> int: ...
def remaining_tasks(trip_id: str) -> list[OpenTask]: ...
def report_open(trip_id: str, tasks: list[OpenTask]) -> int: ...
''';

const _trip = <String, Object?>{
  'trip_id': 'TR-10',
  'day': 10,
  'origin_cell': 'A1',
  'dest_cell': 'B2',
  'asset_kind': 'courier_drone',
  'roles': ['pilot', 'rigger'],
  'window_start_hr': 3,
  'window_end_hr': 7,
};
const _assignment = <String, Object?>{
  'trip_id': 'TR-10',
  'day': 10,
  'asset_id': null,
  'crew': <Object?>[],
  'window_start_hr': 3,
  'window_end_hr': 7,
};
const _assets = <Object?>[
  <String, Object?>{
    'asset_id': 'CD-1',
    'kind': 'courier_drone',
    'home_cell': 'A1',
    'max_leg_steps': 4,
    'burn_per_step': 5,
    'tank_sparks': 100,
    'available_days': [10],
  },
  <String, Object?>{
    'asset_id': 'CD-2',
    'kind': 'courier_drone',
    'home_cell': 'A1',
    'max_leg_steps': 4,
    'burn_per_step': 5,
    'tank_sparks': 100,
    'available_days': [10],
  },
];
const _route = <String, Object?>{
  'route_id': 'A1-B2',
  'origin_cell': 'A1',
  'dest_cell': 'B2',
  'legs': <Object?>[
    <String, Object?>{
      'leg_index': 0,
      'from_cell': 'A1',
      'to_cell': 'X1',
      'steps': 3,
      'recharge_at_dest': true,
    },
    <String, Object?>{
      'leg_index': 1,
      'from_cell': 'X1',
      'to_cell': 'B2',
      'steps': 4,
      'recharge_at_dest': false,
    },
  ],
  'total_steps': 7,
};
const _tasks = <Object?>[
  <String, Object?>{
    'task_id': 'T1',
    'kind': 'crew',
    'subject': 'pilot',
    'reason': 'none',
  },
  <String, Object?>{
    'task_id': 'T2',
    'kind': 'asset',
    'subject': 'courier_drone',
    'reason': 'none',
  },
];

List<HostFunction> typecheckHostFunctions(List<String> calls) => [
  _host('get_trip', ['trip_id'], calls, (_) => _trip),
  _host('get_assignment', ['trip_id'], calls, (_) => _assignment),
  _host('find_assets', ['kind', 'cell_id', 'day'], calls, (args) {
    if (args['day'] is! MontyInt) {
      throw const ExternalException('TypeError', 'day must be int');
    }

    return _assets;
  }),
  _host('assign_crew', ['trip_id', 'role', 'staff_id'], calls, (args) {
    const roles = {'pilot', 'rigger', 'navigator', 'loader'};
    if (!roles.contains(args['role']?.dartValue)) {
      throw const ExternalException('ValueError', 'unknown role');
    }

    return _assignment;
  }),
  _host('plan_route', ['origin', 'dest', 'constraints'], calls, (_) => _route),
  _host('fuel_estimate', ['asset', 'route'], calls, (_) => 40),
  _host('remaining_tasks', ['trip_id'], calls, (_) => _tasks),
  _host('report_open', ['trip_id', 'tasks'], calls, (args) {
    return (args['tasks']!.dartValue! as List<Object?>).length;
  }),
];

HostFunction _host(
  String name,
  List<String> params,
  List<String> calls,
  Object? Function(Map<String, MontyValue>) body,
) => HostFunction(
  schema: HostFunctionSchema(
    name: name,
    params: [
      for (final param in params)
        HostParam(name: param, type: HostParamType.any),
    ],
  ),
  handler: (args, _) async {
    calls.add(name);

    return MontyValue.fromDart(body(args));
  },
);

enum Verdict { pass, reject }

enum CaseClass {
  accept,
  catchError,
  knownFalsePositive,
  knownMiss,
  builtin,
  module,
}

class TypecheckCase {
  const TypecheckCase({
    required this.id,
    required this.title,
    required this.source,
    required this.cls,
    required this.program,
    required this.verdict,
    required this.codes,
    required this.checkedOutcome,
    required this.uncheckedOutcome,
    this.setup = const [],
    this.skipSetup = false,
  });

  final String id;
  final String title;
  final String source;
  final CaseClass cls;
  final String program;
  final List<String> setup;
  final bool skipSetup;
  final Verdict verdict;
  final Set<String> codes;
  final String checkedOutcome;
  final String uncheckedOutcome;
}

const typecheckCases = [
  TypecheckCase(
    id: 'A1',
    title: 'plain code',
    source: 'new',
    cls: CaseClass.accept,
    program:
        'def twice(n: int) -> int:\n    return n * 2\n'
        'xs = [twice(i) for i in range(3)]\ns = f"{1 + 2}:{xs}"',
    verdict: Verdict.pass,
    codes: {},
    checkedOutcome: 'ok',
    uncheckedOutcome: 'ok',
  ),
  TypecheckCase(
    id: 'A2',
    title: 'host calls match stubs',
    source: 'new',
    cls: CaseClass.accept,
    program:
        't = get_trip("TR-10")\n'
        'a = find_assets(t["asset_kind"], t["origin_cell"], t["day"])\n'
        'n = len(a)',
    verdict: Verdict.pass,
    codes: {},
    checkedOutcome: 'ok',
    uncheckedOutcome: 'ok',
  ),
  TypecheckCase(
    id: 'A3',
    title: 'inline record literal',
    source: 'x50 T23',
    cls: CaseClass.accept,
    program:
        'plan_route("A1", "B2", {"max_leg_steps": 4, '
        '"avoid_cells": [], "require_chargers": True})',
    verdict: Verdict.pass,
    codes: {},
    checkedOutcome: 'ok',
    uncheckedOutcome: 'ok',
  ),
  TypecheckCase(
    id: 'A4',
    title: 'annotated record variable',
    source: 'x50 T21',
    cls: CaseClass.accept,
    program:
        'c: RouteConstraints = {"max_leg_steps": 4, '
        '"avoid_cells": [], "require_chargers": True}\n'
        'plan_route("A1", "B2", c)',
    verdict: Verdict.pass,
    codes: {},
    checkedOutcome: 'ok',
    uncheckedOutcome: 'ok',
  ),
  TypecheckCase(
    id: 'A5',
    title: 'enum field into literal parameter',
    source: 'x50 T11',
    cls: CaseClass.accept,
    program:
        't = get_trip("TR-10")\nassign_crew("TR-10", t["roles"][0], "S-1")',
    verdict: Verdict.pass,
    codes: {},
    checkedOutcome: 'ok',
    uncheckedOutcome: 'ok',
  ),
  TypecheckCase(
    id: 'A6',
    title: 'optional is handled',
    source: 'new',
    cls: CaseClass.accept,
    program:
        'a = get_assignment("TR-10")\n'
        'if a["asset_id"] is None:\n    x = "none"\n'
        'else:\n    x = a["asset_id"]',
    verdict: Verdict.pass,
    codes: {},
    checkedOutcome: 'ok',
    uncheckedOutcome: 'ok',
  ),
  TypecheckCase(
    id: 'A7',
    title: 'optional local is narrowed',
    source: 'new',
    cls: CaseClass.accept,
    program:
        'def pick(assets: list[Asset]) -> Asset | None:\n'
        '    best: Asset | None = None\n'
        '    for item in assets:\n        best = item\n'
        '    return best\n'
        'best = pick(find_assets("courier_drone", "A1", 10))\n'
        'if best is not None:\n'
        '    f = fuel_estimate(best, plan_route("A1", "B2", '
        '{"max_leg_steps": 4, "avoid_cells": [], '
        '"require_chargers": True}))',
    verdict: Verdict.pass,
    codes: {},
    checkedOutcome: 'ok',
    uncheckedOutcome: 'ok',
  ),
  TypecheckCase(
    id: 'A8',
    title: 'annotated rebinding across turns',
    source: 'x50 T32',
    cls: CaseClass.accept,
    setup: ['trip: str = "TR-10"'],
    program: 'trip = "TR-11"',
    verdict: Verdict.pass,
    codes: {},
    checkedOutcome: 'ok',
    uncheckedOutcome: 'ok',
  ),
  TypecheckCase(
    id: 'A9',
    title: 'valid enum literal',
    source: 'x50 T1',
    cls: CaseClass.accept,
    program: 'assign_crew("TR-10", "pilot", "S-1")',
    verdict: Verdict.pass,
    codes: {},
    checkedOutcome: 'ok',
    uncheckedOutcome: 'ok',
  ),
  TypecheckCase(
    id: 'C1',
    title: 'wrong enum literal',
    source: 'x50 T2, precheck gate-reject-true-catch',
    cls: CaseClass.catchError,
    program: 'assign_crew("TR-10", "Pilot", "S-1")',
    verdict: Verdict.reject,
    codes: {'invalid-argument-type'},
    checkedOutcome: 'not-run',
    uncheckedOutcome: 'error:ValueError',
  ),
  TypecheckCase(
    id: 'C2',
    title: 'wrong record key',
    source: 'x50 T5',
    cls: CaseClass.catchError,
    program: 't = get_trip("TR-10")\nx = t["trip"]',
    verdict: Verdict.reject,
    codes: {'invalid-key'},
    checkedOutcome: 'not-run',
    uncheckedOutcome: 'error:KeyError',
  ),
  TypecheckCase(
    id: 'C3',
    title: 'missing argument',
    source: 'x50 T3',
    cls: CaseClass.catchError,
    program: 'get_trip()',
    verdict: Verdict.reject,
    codes: {'missing-argument'},
    checkedOutcome: 'not-run',
    uncheckedOutcome: 'error:TypeError',
  ),
  TypecheckCase(
    id: 'C4',
    title: 'unknown keyword',
    source: 'x50 T4',
    cls: CaseClass.catchError,
    program: 'get_trip(trip="TR-10")',
    verdict: Verdict.reject,
    codes: {'unknown-argument', 'missing-argument'},
    checkedOutcome: 'not-run',
    uncheckedOutcome: 'error:TypeError',
  ),
  TypecheckCase(
    id: 'C5',
    title: 'wrong argument type',
    source: 'new',
    cls: CaseClass.catchError,
    program: 'find_assets("courier_drone", "A1", "10")',
    verdict: Verdict.reject,
    codes: {'invalid-argument-type'},
    checkedOutcome: 'not-run',
    uncheckedOutcome: 'error:TypeError',
  ),
  TypecheckCase(
    id: 'C6',
    title: 'integer used as iterable',
    source: 'smoke gemma4-e2b U1-a',
    cls: CaseClass.catchError,
    program:
        'n = report_open("TR-10", remaining_tasks("TR-10"))\n'
        'for t in n:\n    print(t)',
    verdict: Verdict.reject,
    codes: {'not-iterable'},
    checkedOutcome: 'not-run',
    uncheckedOutcome: 'error:TypeError',
  ),
  TypecheckCase(
    id: 'C7',
    title: 'wrong model return type',
    source: 'x50 T16',
    cls: CaseClass.catchError,
    program:
        'def total(r: Route) -> int:\n    return {"steps": 3}\n'
        'r = plan_route("A1", "B2", {"max_leg_steps": 4, '
        '"avoid_cells": [], "require_chargers": True})\n'
        'total(r) + 1',
    verdict: Verdict.reject,
    codes: {'invalid-return-type'},
    checkedOutcome: 'not-run',
    uncheckedOutcome: 'error:TypeError',
  ),
  TypecheckCase(
    id: 'C8',
    title: 'none misuse',
    source: 'new',
    cls: CaseClass.catchError,
    program: 'a = get_assignment("TR-10")\nn = len(a["asset_id"])',
    verdict: Verdict.reject,
    codes: {'invalid-argument-type'},
    checkedOutcome: 'not-run',
    uncheckedOutcome: 'error:TypeError',
  ),
  TypecheckCase(
    id: 'F1',
    title: 'cross-turn literal rebinding',
    source: 'x50 T25, precheck gate-literal-rebinding',
    cls: CaseClass.knownFalsePositive,
    setup: ['trip = "TR-10"'],
    program: 'trip = "TR-11"',
    verdict: Verdict.reject,
    codes: {'invalid-assignment'},
    checkedOutcome: 'not-run',
    uncheckedOutcome: 'ok',
  ),
  TypecheckCase(
    id: 'F2',
    title: 'cross-turn integer rebinding',
    source: 'x50 T26',
    cls: CaseClass.knownFalsePositive,
    setup: ['n = 1'],
    program: 'n = 2',
    verdict: Verdict.reject,
    codes: {'invalid-assignment'},
    checkedOutcome: 'not-run',
    uncheckedOutcome: 'ok',
  ),
  TypecheckCase(
    id: 'F3',
    title: 'unannotated record variable',
    source: 'precheck gate-reject-false-positive',
    cls: CaseClass.knownFalsePositive,
    program:
        'c = {"max_leg_steps": 4, "avoid_cells": [], '
        '"require_chargers": True}\nplan_route("A1", "B2", c)',
    verdict: Verdict.reject,
    codes: {'invalid-argument-type'},
    checkedOutcome: 'not-run',
    uncheckedOutcome: 'ok',
  ),
  TypecheckCase(
    id: 'F4',
    title: 'unannotated record list',
    source: 'smoke glimmer U1-a#13',
    cls: CaseClass.knownFalsePositive,
    program:
        'tasks = [{"task_id": "T1", "kind": "crew", '
        '"subject": "rigger", "reason": "none"}]\n'
        'report_open("TR-10", tasks)',
    verdict: Verdict.reject,
    codes: {'invalid-argument-type'},
    checkedOutcome: 'not-run',
    uncheckedOutcome: 'ok',
  ),
  TypecheckCase(
    id: 'F5',
    title: 'optional asset across turns',
    source: 'smoke glimmer U1-a#12',
    cls: CaseClass.knownFalsePositive,
    setup: ['asset = find_assets("courier_drone", "A1", 10)[0]'],
    program:
        'asset = None\n'
        'for a in find_assets("courier_drone", "A1", 10):\n'
        '    if a["asset_id"] == "CD-2":\n        asset = a',
    verdict: Verdict.reject,
    codes: {'invalid-assignment'},
    checkedOutcome: 'not-run',
    uncheckedOutcome: 'ok',
  ),
  TypecheckCase(
    id: 'F6',
    title: 'loop variable reused across turns for another record',
    source: 'smoke gemma4 U1-a#12..20',
    cls: CaseClass.knownFalsePositive,
    setup: ['for t in [get_trip("TR-10")]:\n    pass'],
    program: 'for t in remaining_tasks("TR-10"):\n    print(t["kind"])',
    verdict: Verdict.reject,
    codes: {'invalid-assignment', 'invalid-key'},
    checkedOutcome: 'not-run',
    uncheckedOutcome: 'ok',
  ),
  TypecheckCase(
    id: 'F7',
    title: 'bare dict annotation',
    source: 'smoke gemma4 U2-a#1',
    cls: CaseClass.knownFalsePositive,
    program: 'trip: dict = get_trip("TR-10")',
    verdict: Verdict.reject,
    codes: {'invalid-assignment'},
    checkedOutcome: 'not-run',
    uncheckedOutcome: 'ok',
  ),
  TypecheckCase(
    id: 'F8',
    title: 'mixed record literal arithmetic',
    source: 'E1',
    cls: CaseClass.knownFalsePositive,
    program:
        'items = [{"sku": "K-11", "on_hand": 140, '
        '"min_qty": 200}]\n'
        'below = [i["min_qty"] - i["on_hand"] for i in items '
        'if i["on_hand"] < i["min_qty"]]',
    verdict: Verdict.reject,
    codes: {'unsupported-operator'},
    checkedOutcome: 'not-run',
    uncheckedOutcome: 'ok',
  ),
  TypecheckCase(
    id: 'F9',
    title: 'skipped setup is absent from context',
    source: 'x50 T19',
    cls: CaseClass.knownFalsePositive,
    setup: ['helper = lambda n: n * 2'],
    skipSetup: true,
    program: 'y = helper(3)',
    verdict: Verdict.reject,
    codes: {'unresolved-reference'},
    checkedOutcome: 'not-run',
    uncheckedOutcome: 'ok',
  ),
  TypecheckCase(
    id: 'M1',
    title: 'case-mismatched enum comparison',
    source: 'x50 T30',
    cls: CaseClass.knownMiss,
    program:
        't = get_trip("TR-10")\n'
        'ok = t["asset_kind"] == "Courier_drone"\n'
        'if not ok:\n    raise ValueError("kind")',
    verdict: Verdict.pass,
    codes: {},
    checkedOutcome: 'error:ValueError',
    uncheckedOutcome: 'error:ValueError',
  ),
  TypecheckCase(
    id: 'M2',
    title: 'copied TypedDict',
    source: 'x50 T20',
    cls: CaseClass.knownMiss,
    program:
        'from typing import TypedDict\n'
        'class Leg2(TypedDict):\n    id: str\n'
        'l: Leg2 = {"id": "a"}',
    verdict: Verdict.pass,
    codes: {},
    checkedOutcome: 'error:NotImplementedError',
    uncheckedOutcome: 'error:NotImplementedError',
  ),
  TypecheckCase(
    id: 'M3',
    title: 'os listdir',
    source: 'E1',
    cls: CaseClass.knownMiss,
    program: 'import os\nos.listdir("/")',
    verdict: Verdict.pass,
    codes: {},
    checkedOutcome: 'error:PermissionError',
    uncheckedOutcome: 'error:PermissionError',
  ),
  TypecheckCase(
    id: 'M4',
    title: 'os environ',
    source: 'E1',
    cls: CaseClass.knownMiss,
    program: 'import os\nos.environ["HOME"]',
    verdict: Verdict.pass,
    codes: {},
    checkedOutcome: 'error:RuntimeError',
    uncheckedOutcome: 'error:RuntimeError',
  ),
  TypecheckCase(
    id: 'M6',
    title: 'next over a generator expression',
    source: 'smoke glimmer U1-a#12',
    cls: CaseClass.knownMiss,
    program: 'next((a for a in [1, 2] if a == 2), None)',
    verdict: Verdict.pass,
    codes: {},
    checkedOutcome: 'error:TypeError',
    uncheckedOutcome: 'error:TypeError',
  ),
  TypecheckCase(
    id: 'M5',
    title: 'open is unresolved',
    source: 'E1',
    cls: CaseClass.catchError,
    program: 'open("x.txt").read()',
    verdict: Verdict.reject,
    codes: {'unresolved-reference'},
    checkedOutcome: 'not-run',
    uncheckedOutcome: 'error:PermissionError',
  ),
  TypecheckCase(
    id: 'B1',
    title: 'map builtin',
    source: 'E1',
    cls: CaseClass.builtin,
    program: 'list(map(lambda x: x + 1, [1, 2]))',
    verdict: Verdict.reject,
    codes: {'unresolved-reference'},
    checkedOutcome: 'not-run',
    uncheckedOutcome: 'ok',
  ),
  TypecheckCase(
    id: 'B2',
    title: 'filter builtin',
    source: 'E1',
    cls: CaseClass.builtin,
    program: 'list(filter(lambda x: x > 1, [1, 2]))',
    verdict: Verdict.reject,
    codes: {'unresolved-reference'},
    checkedOutcome: 'not-run',
    uncheckedOutcome: 'ok',
  ),
  TypecheckCase(
    id: 'B3',
    title: 'getattr builtin',
    source: 'new',
    cls: CaseClass.builtin,
    program: 'getattr("a", "upper")()',
    verdict: Verdict.reject,
    codes: {'unresolved-reference'},
    checkedOutcome: 'not-run',
    uncheckedOutcome: 'error:AttributeError',
  ),
  TypecheckCase(
    id: 'B4',
    title: 'hasattr builtin',
    source: 'E1',
    cls: CaseClass.builtin,
    program: 'hasattr("a", "upper")',
    verdict: Verdict.reject,
    codes: {'unresolved-reference'},
    checkedOutcome: 'not-run',
    uncheckedOutcome: 'ok',
  ),
  TypecheckCase(
    id: 'B5',
    title: 'setattr builtin',
    source: 'new',
    cls: CaseClass.builtin,
    program: 'class A:\n    pass\na = A()\nsetattr(a, "x", 1)',
    verdict: Verdict.reject,
    codes: {'unresolved-reference'},
    checkedOutcome: 'not-run',
    uncheckedOutcome: 'ok',
  ),
  TypecheckCase(
    id: 'B6',
    title: 'format builtin',
    source: 'new',
    cls: CaseClass.builtin,
    program: 'format(12, "d")',
    verdict: Verdict.reject,
    codes: {'unresolved-reference'},
    checkedOutcome: 'not-run',
    uncheckedOutcome: 'ok',
  ),
  TypecheckCase(
    id: 'B7',
    title: 'eval builtin',
    source: 'new',
    cls: CaseClass.builtin,
    program: 'eval("1 + 1")',
    verdict: Verdict.pass,
    codes: {},
    checkedOutcome: 'ok',
    uncheckedOutcome: 'ok',
  ),
  TypecheckCase(
    id: 'B8',
    title: 'exec builtin',
    source: 'new',
    cls: CaseClass.builtin,
    program: 'exec("x = 1")',
    verdict: Verdict.pass,
    codes: {},
    checkedOutcome: 'ok',
    uncheckedOutcome: 'ok',
  ),
  TypecheckCase(
    id: 'B9',
    title: 'globals builtin',
    source: 'E1',
    cls: CaseClass.builtin,
    program: 'globals()',
    verdict: Verdict.reject,
    codes: {'unresolved-reference'},
    checkedOutcome: 'not-run',
    uncheckedOutcome: 'error:NameError',
  ),
  TypecheckCase(
    id: 'B10',
    title: 'dir builtin',
    source: 'E1',
    cls: CaseClass.builtin,
    program: 'dir("a")',
    verdict: Verdict.reject,
    codes: {'unresolved-reference'},
    checkedOutcome: 'not-run',
    uncheckedOutcome: 'error:NameError',
  ),
  TypecheckCase(
    id: 'D1',
    title: 'sqlite3 module',
    source: 'new',
    cls: CaseClass.module,
    program: 'import sqlite3',
    verdict: Verdict.reject,
    codes: {'unresolved-import'},
    checkedOutcome: 'not-run',
    uncheckedOutcome: 'error:ModuleNotFoundError',
  ),
  TypecheckCase(
    id: 'D2',
    title: 'json module',
    source: 'new',
    cls: CaseClass.module,
    program: 'import json\njson.dumps({"a": 1})',
    verdict: Verdict.pass,
    codes: {},
    checkedOutcome: 'ok',
    uncheckedOutcome: 'ok',
  ),
  TypecheckCase(
    id: 'D3',
    title: 'enum module',
    source: 'new',
    cls: CaseClass.module,
    program: 'import enum',
    verdict: Verdict.reject,
    codes: {'unresolved-import'},
    checkedOutcome: 'not-run',
    uncheckedOutcome: 'error:ModuleNotFoundError',
  ),
  TypecheckCase(
    id: 'D4',
    title: 'builtins module',
    source: 'new',
    cls: CaseClass.module,
    program: 'import builtins',
    verdict: Verdict.pass,
    codes: {},
    checkedOutcome: 'error:ModuleNotFoundError',
    uncheckedOutcome: 'error:ModuleNotFoundError',
  ),
  TypecheckCase(
    id: 'D5',
    title: 'dataclasses module',
    source: 'new',
    cls: CaseClass.module,
    program: 'from dataclasses import dataclass',
    verdict: Verdict.pass,
    codes: {},
    checkedOutcome: 'ok',
    uncheckedOutcome: 'ok',
  ),
  TypecheckCase(
    id: 'D6',
    title: 'typing module',
    source: 'new',
    cls: CaseClass.module,
    program: 'import typing',
    verdict: Verdict.pass,
    codes: {},
    checkedOutcome: 'ok',
    uncheckedOutcome: 'ok',
  ),
  TypecheckCase(
    id: 'D7',
    title: 're module',
    source: 'new',
    cls: CaseClass.module,
    program: 'import re\nre.match("a", "a") is not None',
    verdict: Verdict.pass,
    codes: {},
    checkedOutcome: 'ok',
    uncheckedOutcome: 'ok',
  ),
];
