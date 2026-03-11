#!/usr/bin/env python3
"""Generate a Monty integration smoke test from a generated MontyPlugin.

Usage:
    python3 tool/generate_smoke_test.py <plugin_dart_file> <package_name> <output_test_file>

Parses the generated plugin to extract:
  - Class name (e.g., UuidPlugin)
  - pythonPrelude wrapper function definitions
  - HostFunctionSchema param types (for generating test arg values)

Produces a Dart test file that:
  1. Creates MontyFfi + DefaultMontyBridge
  2. Registers the plugin via PluginRegistry
  3. Runs the pythonPrelude through Monty
  4. Calls each wrapper function through Monty
  5. Verifies no BridgeRunError for each call

Exit codes:
    0 — Test file generated successfully
    1 — Could not parse plugin file
"""

import re
import sys


def extract_class_name(dart_src: str) -> str | None:
    """Find the MontyPlugin subclass name."""
    match = re.search(r'class\s+(\w+)\s+extends\s+MontyPlugin', dart_src)
    return match.group(1) if match else None


def extract_prelude(dart_src: str) -> str | None:
    """Extract pythonPrelude string content."""
    pattern = r"get\s+pythonPrelude\s*=>\s*'''(.*?)'''"
    match = re.search(pattern, dart_src, re.DOTALL)
    if match:
        return match.group(1)
    pattern = r'get\s+pythonPrelude\s*=>\s*"""(.*?)"""'
    match = re.search(pattern, dart_src, re.DOTALL)
    return match.group(1) if match else None


def extract_prelude_functions(prelude: str) -> list[tuple[str, list[str]]]:
    """Extract function defs from prelude: [(name, [arg_names])]."""
    funcs = []
    for match in re.finditer(r'^def\s+(\w+)\s*\(([^)]*)\)\s*:', prelude, re.MULTILINE):
        name = match.group(1)
        args_str = match.group(2).strip()
        if args_str:
            args = [a.strip().split('=')[0].strip() for a in args_str.split(',')]
        else:
            args = []
        funcs.append((name, args))
    return funcs


def extract_host_params(dart_src: str) -> dict[str, list[tuple[str, str]]]:
    """Extract HostFunctionSchema params: {func_name: [(param_name, param_type)]}."""
    result = {}
    # Find each HostFunctionSchema block.
    schema_pattern = re.compile(
        r"HostFunctionSchema\(\s*name:\s*'(\w+)'.*?params:\s*\[(.*?)\]",
        re.DOTALL,
    )
    param_pattern = re.compile(
        r"HostParam\(\s*name:\s*'(\w+)'.*?type:\s*HostParamType\.(\w+)",
        re.DOTALL,
    )
    for schema_match in schema_pattern.finditer(dart_src):
        func_name = schema_match.group(1)
        params_block = schema_match.group(2)
        params = []
        for param_match in param_pattern.finditer(params_block):
            params.append((param_match.group(1), param_match.group(2)))
        result[func_name] = params
    return result


def python_test_value(param_name: str, param_type: str) -> str:
    """Generate a sensible Python test value based on param name and type."""
    # Name-based heuristics first.
    name_lower = param_name.lower()
    if 'uuid' in name_lower:
        return '"110ec58a-a0f2-4ac4-8393-c866d813b8d1"'
    if 'namespace' in name_lower:
        return '"6ba7b811-9dad-11d1-80b4-00c04fd430c8"'
    if 'url' in name_lower:
        return '"https://example.com"'
    if 'path' in name_lower or 'file' in name_lower:
        return '"/tmp/test.txt"'
    if 'phone' in name_lower or 'number' in name_lower and param_type == 'string':
        return '"+1234567890"'
    if 'email' in name_lower:
        return '"test@example.com"'

    # Type-based fallback.
    type_defaults = {
        'string': '"test"',
        'integer': '42',
        'number': '3.14',
        'boolean': 'True',
        'list': '[1, 2, 3]',
        'map': '{"key": "value"}',
        'any': '"test"',
    }
    return type_defaults.get(param_type, '"test"')


def generate_smoke_test(
    class_name: str,
    package_name: str,
    prelude_funcs: list[tuple[str, list[str]]],
    host_params: dict[str, list[tuple[str, str]]],
    namespace: str,
    native_lib_path: str | None = None,
) -> str:
    """Generate the Dart smoke test source."""
    # Build the Python smoke script that combines prelude + calls.
    # We generate individual test cases for each function.
    import_path = f'package:wrap_test_{package_name}/src/plugins/{package_name}_plugin.dart'

    # Native library path for NativeBindingsFfi constructor.
    lib_path_arg = ''
    if native_lib_path:
        lib_path_arg = f"libraryPath: '{native_lib_path}'"

    # Map prelude function names to their host function names.
    # Convention: prelude func "v1" calls host func "uuid_v1".
    func_to_host = {}
    for func_name, _ in prelude_funcs:
        host_name = f'{namespace}_{func_name}'
        func_to_host[func_name] = host_name

    # Build test code for each function.
    test_cases = []

    for func_name, func_args in prelude_funcs:
        host_name = func_to_host.get(func_name, '')
        host_param_list = host_params.get(host_name, [])

        if not func_args:
            # No-arg function — just call it.
            python_call = f'{func_name}()'
        else:
            # Build args from host param types.
            call_args = []
            for i, arg_name in enumerate(func_args):
                if i < len(host_param_list):
                    _, ptype = host_param_list[i]
                else:
                    ptype = 'string'
                call_args.append(python_test_value(arg_name, ptype))
            python_call = f'{func_name}({", ".join(call_args)})'

        test_cases.append((func_name, python_call))

    # Generate the Dart test file.
    test_blocks = []
    for func_name, python_call in test_cases:
        # Escape single quotes in the Python call for Dart string.
        escaped = python_call.replace("'", r"\'")
        test_blocks.append(f"""
    test('{func_name}() executes without error', () async {{
      final result = await _run(bridge, prelude + '\\n{escaped}');
      expect(result.error, isNull,
          reason: '{func_name} failed: ${{result.error}}');
      expect(result.value, isNotNull,
          reason: '{func_name} returned null');
    }});""")

    tests_joined = '\n'.join(test_blocks)

    return f"""// Generated Monty smoke test — do not edit.
@Tags(['integration'])
library;

import 'package:dart_monty_bridge/dart_monty_bridge.dart';
import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';
import '{import_path}';

/// Result of a single Python execution.
class _PyResult {{
  _PyResult({{this.value, this.error}});
  final Object? value;
  final String? error;
}}

/// Execute Python code on the bridge, return value or error.
Future<_PyResult> _run(DefaultMontyBridge bridge, String code) async {{
  final events = await bridge.execute(code).toList();
  final err = events.whereType<BridgeRunError>().firstOrNull;
  if (err != null) {{
    return _PyResult(error: err.message);
  }}
  final fin = events.whereType<BridgeRunFinished>().firstOrNull;
  return _PyResult(value: fin?.value);
}}

void main() {{
  late MontyFfi monty;
  late DefaultMontyBridge bridge;
  late PluginRegistry registry;
  late String prelude;

  setUpAll(() async {{
    monty = MontyFfi(bindings: NativeBindingsFfi({lib_path_arg}));
    bridge = DefaultMontyBridge(platform: monty);
    registry = PluginRegistry()..register({class_name}());
    await registry.attachTo(bridge);
    // The Monty runtime normally initializes _help_docs and _help_list before
    // plugin preludes run. In this bare-bridge context, we must init them
    // ourselves so the prelude's help registration lines don't fail.
    prelude = '_help_docs = {{}}\\n_help_list = []\\n' +
        registry.combinedPythonPrelude();
  }});

  tearDownAll(() async {{
    await registry.disposeAll();
    bridge.dispose();
  }});

  test('pythonPrelude evaluates without error', () async {{
    final result = await _run(bridge, prelude);
    expect(result.error, isNull,
        reason: 'Prelude failed: ${{result.error}}');
  }});

  // help() requires full runtime initialization (not available in bare-bridge
  // mode), so we skip it in the smoke test.
{tests_joined}
}}
"""


def main():
    if len(sys.argv) < 4 or len(sys.argv) > 5:
        print(
            f'Usage: {sys.argv[0]} <plugin_dart_file> <package_name> <output_test_file> [native_lib_path]',
            file=sys.stderr,
        )
        sys.exit(1)

    plugin_file, package_name, output_file = sys.argv[1], sys.argv[2], sys.argv[3]
    native_lib_path = sys.argv[4] if len(sys.argv) == 5 else None

    with open(plugin_file) as f:
        dart_src = f.read()

    class_name = extract_class_name(dart_src)
    if not class_name:
        print('ERROR: Could not find MontyPlugin subclass.', file=sys.stderr)
        sys.exit(1)

    prelude = extract_prelude(dart_src)
    if prelude is None:
        print('WARN: No pythonPrelude found — generating minimal test.', file=sys.stderr)
        prelude = ''

    # Extract namespace from the plugin source.
    ns_match = re.search(r"get\s+namespace\s*=>\s*'(\w+)'", dart_src)
    namespace = ns_match.group(1) if ns_match else package_name

    prelude_funcs = extract_prelude_functions(prelude)
    host_params = extract_host_params(dart_src)

    test_src = generate_smoke_test(
        class_name=class_name,
        package_name=package_name,
        prelude_funcs=prelude_funcs,
        host_params=host_params,
        namespace=namespace,
        native_lib_path=native_lib_path,
    )

    with open(output_file, 'w') as f:
        f.write(test_src)

    func_names = [name for name, _ in prelude_funcs]
    print(f'OK: Generated smoke test for {class_name} ({len(prelude_funcs)} functions: {", ".join(func_names)})')
    print(f'    Output: {output_file}')


if __name__ == '__main__':
    main()
