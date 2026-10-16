"""Regression checks for the API gate's embedded declaration scanner."""
import ast
from pathlib import Path
import re
import unittest


source = Path(__file__).with_name('check_api_exercised.sh').read_text()
embedded = source.split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
tree = ast.parse(embedded)
scanner = ast.Module(body=[
    node for node in tree.body
    if (isinstance(node, ast.Assign)
        and any(isinstance(t, ast.Name) and t.id in ('DECL', 'TYPE_START')
                for t in node.targets))
    or (isinstance(node, ast.FunctionDef) and node.name == '_methods_in_types')
], type_ignores=[])
namespace = {'re': re}
exec(compile(scanner, source, 'exec'), namespace)
methods = namespace['_methods_in_types']


class ApiScannerTest(unittest.TestCase):
    def test_private_types_are_not_entry_points(self):
        self.assertEqual(methods('''
final class _ChildContext {
  void finish() {}
  Future<MontyValue> subExecute(String code) {}
}
class PublicRuntime {
  void execute() {}
  void _internal() {}
}
'''), ['execute'])

    def test_public_types_and_extensions_remain_checked(self):
        self.assertEqual(methods('''
abstract class Runtime {
  void close();
}
extension Tools on Runtime {
  void invoke() {}
}
void helper() {
  void local() {}
}
'''), ['close', 'invoke'])


if __name__ == '__main__':
    unittest.main()
