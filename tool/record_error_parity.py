#!/usr/bin/env python3
"""Re-record test/fixtures/error_parity/cases.json from pydantic-monty 1.1.0.

Usage: python tool/record_error_parity.py [--check]
"""

from __future__ import annotations

import builtins
import collections
import datetime as dt
import json
import re
import struct
import sys
from pathlib import Path, PurePath, PurePosixPath
from typing import Any

import pydantic_monty as pm

CASES_PATH = Path(__file__).resolve().parent.parent / 'test' / 'fixtures' / 'error_parity' / 'cases.json'
CONTAINERS = (list, tuple, dict, set, frozenset)
ID_FIELDS = ('instance_id', 'class_id')
BAD_DISPLAY_FORMAT = 'nope'
DIGITS_RE = re.compile(r'\d+')


# ---------------------------------------------------------------- canonical
def float_c(x: float) -> dict[str, Any]:
    return {'t': 'float', 'v': repr(x), 'bits': struct.pack('>d', x).hex()}


def _proxy(v: Any) -> bool:
    return isinstance(v, (pm.MontyClassProxy, pm.MontyClassTypeProxy))


def _children(v: Any) -> list[Any]:
    if isinstance(v, dict):
        return [x for kv in v.items() for x in kv]
    if _proxy(v):
        return list(v.attributes.values())
    return list(v)


def canon(value: Any) -> Any:
    """Python value -> canonical JSON form (identity-aware: shared containers get id/ref)."""
    return canon_batch([value])[0]


def canon_batch(values: list[Any], _keys: dict[int, str] | None = None) -> list[Any]:
    counts: dict[int, int] = {}
    keep: list[Any] = []

    def shareable(v: Any) -> bool:
        return isinstance(v, CONTAINERS) or _proxy(v)

    def count(v: Any, stack: set[int]) -> None:
        if not shareable(v):
            return
        i = id(v)
        counts[i] = counts.get(i, 0) + 1
        keep.append(v)
        if counts[i] > 1 or i in stack:
            return
        stack.add(i)
        for x in _children(v):
            count(x, stack)
        stack.discard(i)

    for v in values:
        count(v, set())

    standalone: dict[int, str] = {} if _keys is None else _keys

    def key_of(x: Any) -> str:
        if id(x) not in standalone:
            standalone[id(x)] = _label_free(canon_batch([x], standalone)[0])
        return standalone[id(x)]

    ids: dict[int, int] = {}
    seen: set[int] = set()
    sets: collections.deque[Any] = collections.deque()

    def number(v: Any) -> None:
        if not shareable(v) or id(v) in seen:
            return
        seen.add(id(v))
        if counts.get(id(v), 0) > 1:
            ids[id(v)] = len(ids) + 1
        if isinstance(v, (set, frozenset)):
            sets.append(v)
            return
        for x in _children(v):
            number(x)

    for v in values:
        number(v)

    def unnumbered_shared(x: Any) -> bool:
        stack, walked = [x], set()
        while stack:
            y = stack.pop()
            if not shareable(y) or id(y) in walked:
                continue
            walked.add(id(y))
            if id(y) not in ids and counts.get(id(y), 0) > 1:
                return True
            stack.extend(_children(y))
        return False

    while sets:
        members = sorted(sets.popleft(), key=key_of)
        for k, m in enumerate(members):
            tied = (k > 0 and key_of(members[k - 1]) == key_of(m)) or (
                k + 1 < len(members) and key_of(members[k + 1]) == key_of(m)
            )
            if tied and unnumbered_shared(m):
                raise RuntimeError(
                    'set members that tie in label-free form would be numbered in '
                    'iteration order: no stable encoding'
                )
            number(m)

    def signature(x: Any) -> str:
        def rend(y: Any) -> Any:
            if shareable(y) and id(y) in ids:
                return f'#{ids[id(y)]}'
            if isinstance(y, (set, frozenset)):
                return sorted((rend(z) for z in y), key=lambda q: json.dumps(q, sort_keys=True))
            if isinstance(y, dict):
                return [[rend(k), rend(z)] for k, z in y.items()]
            if shareable(y):
                return [type(y).__name__, *(rend(z) for z in _children(y))]
            return canon_batch([y])[0]

        return json.dumps(rend(x), sort_keys=True)

    emitted: set[int] = set()

    def enc(v: Any) -> Any:
        if v is None:
            return {'t': 'none'}
        if isinstance(v, bool):
            return {'t': 'bool', 'v': v}
        if isinstance(v, int):
            return {'t': 'int', 'v': str(v)}
        if isinstance(v, float):
            return float_c(v)
        if isinstance(v, str):
            return {'t': 'str', 'v': v}
        if isinstance(v, (bytes, bytearray)):
            return {'t': 'bytes', 'hex': bytes(v).hex()}
        if isinstance(v, complex):
            return {'t': 'complex', 're': float_c(v.real), 'im': float_c(v.imag)}
        if isinstance(v, PurePath):
            return {'t': 'path', 'v': v.as_posix()}
        if isinstance(v, pm.MontyFileHandle):
            return {'t': 'filehandle', 'path': v.path, 'mode': v.mode, 'position': str(v.position)}
        if not shareable(v):
            x = canon_extra(v, enc)
            return x if x is not None else {'t': 'other', 'kind': type(v).__name__, 'repr': repr(v)}
        i = id(v)
        if i in emitted:
            return {'t': 'ref', 'id': ids[i]}
        emitted.add(i)
        out: dict[str, Any] = {}
        if i in ids:
            out['id'] = ids[i]
        if _proxy(v):
            out.update(canon_extra(v, enc))
        elif isinstance(v, dict):
            out['t'] = 'dict'
            out['items'] = [[enc(k), enc(x)] for k, x in v.items()]
        elif isinstance(v, (set, frozenset)):
            out['t'] = 'set' if isinstance(v, set) else 'frozenset'
            out['items'] = [enc(x) for x in sorted(v, key=lambda x: (key_of(x), signature(x)))]
        elif isinstance(v, tuple) and hasattr(v, '_fields'):
            out['t'] = 'namedtuple'
            m = type(v).__module__
            out['type'] = type(v).__name__ if m in ('', '__main__', 'builtins') else f'{m}.{type(v).__name__}'
            out['fields'] = list(v._fields)
            out['items'] = [enc(x) for x in v]
        else:
            out['t'] = 'list' if isinstance(v, list) else 'tuple'
            out['items'] = [enc(x) for x in v]
        return out

    return [enc(v) for v in values]


def _label_free(e: Any) -> str:
    def strip(x: Any) -> Any:
        if isinstance(x, dict):
            return {k: strip(y) for k, y in x.items() if k not in ID_FIELDS and k != 'id'}
        if isinstance(x, list):
            return [strip(y) for y in x]
        return x

    return json.dumps(strip(e), sort_keys=True)


def canon_call(args: Any, kwargs: Any) -> tuple[list[Any], dict[str, Any]]:
    keys = list(kwargs)
    c = canon_batch([*args, *(kwargs[k] for k in keys)])
    return c[:len(args)], dict(zip(keys, c[len(args):]))


def _tz_name(tz: Any) -> str | None:
    if tz is dt.timezone.utc:
        return None
    if isinstance(tz, dt.timezone):
        args = tz.__getinitargs__()
        return args[1] if len(args) > 1 and isinstance(args[1], str) else None
    return tz.tzname(None)


def _dt_off(t: Any) -> tuple[int | None, str | None]:
    tz = t.tzinfo
    if tz is None:
        return None, None
    off = tz.utcoffset(None) if isinstance(t, dt.time) else tz.utcoffset(t)
    return int(off.total_seconds()), _tz_name(tz)


def _type_name(t: type) -> str:
    m = t.__module__
    return t.__qualname__ if m == 'builtins' else f'{m}.{t.__qualname__}'


def canon_extra(v: Any, enc: Any) -> Any:
    if v is Ellipsis:
        return {'t': 'ellipsis'}
    if v is NotImplemented:
        return {'t': 'notimpl'}
    if isinstance(v, dt.datetime):
        o, n = _dt_off(v)
        return {
            't': 'datetime',
            'v': v.replace(tzinfo=None).isoformat(timespec='microseconds'),
            'offset': o,
            'tzname': n,
        }
    if isinstance(v, dt.date):
        return {'t': 'date', 'v': v.isoformat()}
    if isinstance(v, dt.time):
        o, n = _dt_off(v)
        return {
            't': 'time',
            'v': v.replace(tzinfo=None).isoformat(timespec='microseconds'),
            'offset': o,
            'tzname': n,
            'fold': v.fold,
        }
    if isinstance(v, dt.timedelta):
        return {'t': 'timedelta', 'days': v.days, 'seconds': v.seconds, 'us': v.microseconds}
    if isinstance(v, dt.timezone):
        return {'t': 'timezone', 'offset': int(v.utcoffset(None).total_seconds()), 'name': _tz_name(v)}
    if isinstance(v, BaseException):
        return {'t': 'exception', 'type': type(v).__name__, 'arg': (str(v.args[0]) if v.args else None)}
    if isinstance(v, pm.MontyStdTypeProxy):
        return {'t': 'builtin' if v.kind == 'function' else 'type', 'name': v.name, '_proxy': 'std'}
    if isinstance(v, pm.MontyClassProxy):
        return {
            't': 'proxy',
            'class': v.name,
            'dataclass': v.is_dataclass,
            'instance_id': str(v.id),
            'attrs': [[k, enc(x)] for k, x in v.attributes.items()],
            '_raw': True,
        }
    if isinstance(v, pm.MontyClassTypeProxy):
        return {
            't': 'typeproxy',
            'name': v.name,
            'dataclass': v.is_dataclass,
            'class_id': str(v.id),
            'attrs': [[k, enc(x)] for k, x in v.attributes.items()],
        }
    if isinstance(v, type):
        return {'t': 'type', 'name': _type_name(v)}
    if isinstance(v, (pm.ClassInstance, pm.ClassType)):
        return {'t': 'wrapper?', 'repr': repr(v)}
    return None


def decode(c: dict[str, Any], memo: dict[int, Any] | None = None) -> Any:
    """Canonical JSON form -> Python value (the inverse of `canon`)."""
    memo = {} if memo is None else memo
    t = c['t']
    if t == 'ref':
        return memo[c['id']]

    def done(obj: Any) -> Any:
        if 'id' in c:
            memo[c['id']] = obj
        return obj

    def items() -> list[Any]:
        return [decode(x, memo) for x in c['items']]

    if t == 'none':
        return None
    if t in ('bool', 'str'):
        return c['v']
    if t == 'int':
        return int(c['v'])
    if t == 'float':
        if 'bits' in c:
            return struct.unpack('>d', bytes.fromhex(c['bits']))[0]
        return float(c['v'])
    if t == 'bytes':
        return bytes.fromhex(c['hex'])
    if t == 'list':
        out: list[Any] = done([])
        out.extend(items())
        return out
    if t == 'tuple':
        return done(tuple(items()))
    if t == 'set':
        return done(set(items()))
    if t == 'frozenset':
        return done(frozenset(items()))
    if t == 'dict':
        d: dict[Any, Any] = done({})
        for k, v in c['items']:
            d[decode(k, memo)] = decode(v, memo)
        return d
    if t == 'complex':
        return complex(decode(c['re']), decode(c['im']))
    if t == 'path':
        return PurePosixPath(c['v'])
    if t == 'filehandle':
        return pm.MontyFileHandle(c['path'], c['mode'], position=int(c.get('position', '0')))
    if t == 'ellipsis':
        return Ellipsis
    if t == 'notimpl':
        return NotImplemented
    if t == 'namedtuple':
        mod, _, nm = c['type'].rpartition('.')
        nt = collections.namedtuple(nm, c['fields'], module=mod or None)
        return done(nt._make(items()))
    if t == 'date':
        return dt.date.fromisoformat(c['v'])
    if t in ('datetime', 'time'):
        cls = dt.datetime if t == 'datetime' else dt.time
        v = cls.fromisoformat(c['v'])
        if c.get('offset') is not None:
            off = dt.timedelta(seconds=c['offset'])
            tz = dt.timezone(off, c['tzname']) if c.get('tzname') is not None else dt.timezone(off)
            v = v.replace(tzinfo=tz)
        if t == 'time' and c.get('fold'):
            v = v.replace(fold=c['fold'])
        return v
    if t == 'timedelta':
        return dt.timedelta(days=c['days'], seconds=c['seconds'], microseconds=c['us'])
    if t == 'timezone':
        off = dt.timedelta(seconds=c['offset'])
        return dt.timezone(off, c['name']) if c.get('name') is not None else dt.timezone(off)
    if t == 'exception':
        cls = _lookup_exc_class(c['type'])
        return cls(c['arg']) if c.get('arg') is not None else cls()
    if t == 'type':
        n = c['name']
        if '.' in n:
            mod, _, nm = n.rpartition('.')
            return getattr(__import__(mod), nm)
        return getattr(builtins, n)
    if t == 'proxy':
        return pm.MontyClassProxy()
    if t == 'opaque':
        return object()
    if t == 'str_repeat':
        return c['v'] * c['n']
    raise ValueError(f'cannot decode canonical {t}')


def _lookup_exc_class(type_name: str) -> type[BaseException]:
    if '.' in type_name:
        mod_name, _, attr = type_name.rpartition('.')
        return getattr(__import__(mod_name, fromlist=[attr]), attr)
    return getattr(builtins, type_name)


def _instantiate_exc(type_name: str, message: str) -> BaseException:
    cls = _lookup_exc_class(type_name)
    if issubclass(cls, json.JSONDecodeError):
        return cls(message, '', 0)
    return cls(message)


# ---------------------------------------------------------------- output helpers
def frame_c(f: Any) -> dict[str, Any]:
    d = f.dict()
    return {
        'filename': d.get('filename'),
        'line': d.get('line'),
        'column': d.get('column'),
        'end_line': d.get('end_line'),
        'end_column': d.get('end_column'),
        'function': d.get('function_name'),
        'source_line': d.get('source_line'),
    }


def merge_prints(raw: list[tuple[str, str]]) -> list[dict[str, str]]:
    out: list[dict[str, str]] = []
    for stream, text in raw:
        if out and out[-1]['stream'] == stream:
            out[-1]['text'] += text
        else:
            out.append({'stream': stream, 'text': text})
    return out


def answer(script: list[dict[str, Any]] | None, idx: int) -> dict[str, Any] | None:
    if script is None or idx >= len(script):
        return None
    return script[idx]


def exc_data(inner: BaseException) -> dict[str, Any] | None:
    """The structured payload pydantic_monty's exception() object carries."""
    if isinstance(inner, UnicodeError) and hasattr(inner, 'start'):
        obj = inner.object
        return {
            'kind': 'unicode',
            'encoding': inner.encoding,
            'object': (
                {'t': 'bytes', 'hex': bytes(obj).hex()}
                if isinstance(obj, (bytes, bytearray))
                else {'t': 'str', 'v': obj}
            ),
            'start': inner.start,
            'end': inner.end,
            'reason': inner.reason,
        }
    if isinstance(inner, json.JSONDecodeError):
        return {
            'kind': 'json',
            'msg': inner.msg,
            'doc': inner.doc,
            'pos': inner.pos,
            'lineno': inner.lineno,
            'colno': inner.colno,
        }
    return None


def exc_fields(e: Any) -> dict[str, Any]:
    msg = e.display('msg')
    tm = e.display('type-msg')
    typ = tm[: -(len(msg) + 2)] if msg and tm.endswith(': ' + msg) else tm.split(':', 1)[0]
    inner = e.exception() if hasattr(e, 'exception') else None
    data = exc_data(inner) if isinstance(inner, BaseException) else None
    out: dict[str, Any] = {
        'type': typ,
        'message': msg,
        'traceback': [frame_c(f) for f in e.traceback()],
    }
    if data is not None:
        out['data'] = data
    return out


def display_fields(e: Any) -> dict[str, Any]:
    """Upstream's rendered forms of an exception: display() in each format, str(),
    the exception() object's type and arguments, structured data, and display()'s
    refusal of an unknown format."""
    inner = e.exception()
    data = exc_data(inner) if isinstance(inner, BaseException) else None
    try:
        e.display(BAD_DISPLAY_FORMAT)
        refusal = None
    except ValueError as v:
        refusal = {'format': BAD_DISPLAY_FORMAT, 'type': type(v).__name__, 'message': str(v)}
    return {
        'traceback': e.display('traceback'),
        'type-msg': e.display('type-msg'),
        'msg': e.display('msg'),
        'str': str(e),
        'exception': {'type': type(inner).__name__, 'args': canon(inner.args)},
        'data': data,
        'bad_format': refusal,
    }


def _norm_str(text: str) -> str:
    return DIGITS_RE.sub('N', text)


def _normalize_step_numbers(step: dict[str, Any]) -> None:
    exc = step.get('exception')
    if isinstance(exc, dict) and isinstance(exc.get('message'), str):
        exc['message'] = _norm_str(exc['message'])
    disp = step.get('display')
    if isinstance(disp, dict):
        for k in ('traceback', 'type-msg', 'msg', 'str'):
            if isinstance(disp.get(k), str):
                disp[k] = _norm_str(disp[k])
        exc_obj = disp.get('exception')
        if isinstance(exc_obj, dict):
            exc_obj['args'] = _norm_canon_strings(exc_obj.get('args'))


def _norm_canon_strings(node: Any) -> Any:
    if isinstance(node, dict):
        if node.get('t') == 'str' and isinstance(node.get('v'), str):
            return {**node, 'v': _norm_str(node['v'])}
        return {k: _norm_canon_strings(v) for k, v in node.items()}
    if isinstance(node, list):
        return [_norm_canon_strings(x) for x in node]
    return node


# ---------------------------------------------------------------- running
def record_case(case: dict[str, Any]) -> list[dict[str, Any]]:
    limits: dict[str, Any] = {}
    for k, v in (case.get('limits') or {}).items():
        limits['max_feed_duration_secs' if k == 'max_duration_secs' else k] = v
    checkout_kw: dict[str, Any] = {}
    if case.get('type_check'):
        checkout_kw['type_check'] = True
    if limits:
        checkout_kw['limits'] = limits

    feeds: list[str] = case.get('feeds') or [case['code']]
    used: dict[str, int] = {}
    steps: list[dict[str, Any]] = []

    with pm.Monty() as pool, pool.checkout(**checkout_kw) as session:
        for n, feed in enumerate(feeds):
            code = feed['code'] if isinstance(feed, dict) else feed
            raw_prints: list[tuple[str, str]] = []
            step: dict[str, Any] = {
                'value': None,
                'exception': None,
                'prints': [],
                'ext_calls': [],
                'error_class': None,
                'display': None,
            }
            kw: dict[str, Any] = {'print_callback': lambda s, t, rp=raw_prints: rp.append((s, t))}
            if n == 0 and case.get('inputs'):
                memo: dict[int, Any] = {}
                kw['inputs'] = {k: decode(v, memo) for k, v in case['inputs'].items()}
            if case.get('auto_externals'):
                def make_ext(name: str, st: dict[str, Any] = step) -> Any:
                    def ext(*args: Any, **kwargs: Any) -> Any:
                        c_args, c_kwargs = canon_call(args, kwargs)
                        st['ext_calls'].append({'name': name, 'args': c_args, 'kwargs': c_kwargs})
                        a = answer((case.get('externals') or {}).get(name), used.get('ext:' + name, 0))
                        used['ext:' + name] = used.get('ext:' + name, 0) + 1
                        if a is None:
                            raise NameError(f"name '{name}' is not defined")
                        if 'return' in a:
                            return decode(a['return'])
                        raise _instantiate_exc(a['raise']['type'], a['raise'].get('message', ''))

                    return ext

                kw['external_lookup'] = {name: make_ext(name) for name in (case.get('externals') or {})}

            try:
                snap = session.feed_start(code, **kw)
                guard = 0
                while not isinstance(snap, pm.MontyComplete):
                    guard += 1
                    if guard > 1000:
                        raise RuntimeError('more than 1000 suspensions')
                    if isinstance(snap, pm.FunctionSnapshot) and (
                        snap.object_id is not None
                        or (case.get('auto_externals') and not snap.is_os_function)
                    ):
                        snap = snap.resume_auto()
                        continue
                    if isinstance(snap, pm.FunctionSnapshot):
                        name = str(snap.function_name)
                        c_args, c_kwargs = canon_call(snap.args, snap.kwargs)
                        rec = {'name': name, 'args': c_args, 'kwargs': c_kwargs}
                        table = case.get('os') if snap.is_os_function else case.get('externals')
                        if not snap.is_os_function:
                            step['ext_calls'].append(rec)
                        key = ('os:' if snap.is_os_function else 'ext:') + name
                        a = answer((table or {}).get(name), used.get(key, 0))
                        used[key] = used.get(key, 0) + 1
                        if a is None:
                            if snap.is_os_function:
                                snap = snap.resume_not_handled()
                            else:
                                snap = snap.resume({
                                    'exc_type': 'NameError',
                                    'message': f"name '{name}' is not defined",
                                })
                        elif 'return' in a:
                            snap = snap.resume({'return_value': decode(a['return'])})
                        else:
                            snap = snap.resume({
                                'exc_type': a['raise']['type'],
                                'message': a['raise'].get('message', ''),
                            })
                    elif isinstance(snap, pm.NameLookupSnapshot) and snap.object_id is not None:
                        snap = snap.resume_auto()
                    elif isinstance(snap, pm.NameLookupSnapshot):
                        snap = snap.resume()
                    else:
                        raise RuntimeError(f'unexpected snapshot {type(snap).__name__}')
                step['value'] = canon(snap.output)
            except (pm.MontyRuntimeError, pm.MontySyntaxError) as e:
                step['exception'] = exc_fields(e)
                step['error_class'] = type(e).__name__
                step['display'] = display_fields(e)
            except pm.MontyTypingError as e:
                step['exception'] = {'type': 'MontyTypingError', 'message': e.display(), 'traceback': []}
                step['error_class'] = 'MontyTypingError'
                step['display'] = {
                    'traceback': e.display('full'),
                    'type-msg': e.display('concise'),
                    'msg': e.display('concise'),
                    'str': str(e),
                    'exception': {'type': 'MontyTypingError', 'args': canon(e.args)},
                    'data': None,
                    'bad_format': None,
                }
            except pm.MontyCrashedError as e:
                step['exception'] = {'type': 'MontyCrashedError', 'message': str(e), 'traceback': []}
                step['error_class'] = 'MontyCrashedError'
                step['display'] = {
                    'traceback': str(e),
                    'type-msg': str(e),
                    'msg': str(e),
                    'str': str(e),
                    'exception': {'type': 'MontyCrashedError', 'args': canon(e.args)},
                    'data': None,
                    'bad_format': None,
                }

            step['prints'] = merge_prints(raw_prints)
            if case.get('normalize_numbers'):
                _normalize_step_numbers(step)
            steps.append(step)

    return steps


def build_case_output(case: dict[str, Any], expected: list[dict[str, Any]]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for k, v in case.items():
        if k == 'expected':
            out['expected'] = expected
        else:
            out[k] = v
    if 'expected' not in out:
        out['expected'] = expected
    return out


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    check_only = '--check' in args

    raw_existing = CASES_PATH.read_text(encoding='utf-8')
    doc = json.loads(raw_existing)
    cases = doc.get('cases', [])

    updated_cases = [build_case_output(case, record_case(case)) for case in cases]
    new_doc = {
        'oracle': f'pydantic-monty {pm.__version__}',
        'cases': updated_cases,
    }
    rendered = json.dumps(new_doc, indent=1, ensure_ascii=False) + '\n'

    if check_only:
        if rendered != raw_existing:
            sys.stderr.write(
                f'{CASES_PATH} is out of date; re-record with python tool/record_error_parity.py.\n'
            )
            return 1
        return 0

    CASES_PATH.write_text(rendered, encoding='utf-8')
    return 0


if __name__ == '__main__':
    sys.exit(main())
