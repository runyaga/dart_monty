"""Regression checks for tool/core_root.py, on the OS it runs on.

On Windows the bare URL path of a file URI is `/C:/...`, which is not a usable
path; CI runs this on windows-2025 as well as Linux.
"""
import json
import os
from pathlib import Path
import tempfile
import unittest

from core_root import core_root


class CoreRootTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.core = self.tmp / 'pub cache' / 'dart_monty_core-1.0.0'
        (self.core / 'lib').mkdir(parents=True)
        self.app = self.tmp / 'app'
        (self.app / '.dart_tool').mkdir(parents=True)
        self.config = self.app / '.dart_tool' / 'package_config.json'

    def write(self, root_uri):
        self.config.write_text(json.dumps({'packages': [
            {'name': 'other', 'rootUri': '../'},
            {'name': 'dart_monty_core', 'rootUri': root_uri},
        ]}))

    def test_hosted_absolute_file_uri_is_a_native_existing_path(self):
        self.write(self.core.as_uri() + '/')
        root = core_root(self.config)
        self.assertTrue((root / 'lib').is_dir(), root)
        self.assertEqual(root.resolve(), self.core.resolve())
        if os.name == 'nt':
            self.assertFalse(str(root).startswith(('/', '\\')), root)

    def test_path_dependency_resolves_against_the_config_file(self):
        # pub writes a path dependency relative to .dart_tool/.
        self.write('../../pub%20cache/dart_monty_core-1.0.0/')
        root = core_root(self.config)
        self.assertEqual(root.resolve(), self.core.resolve())

    def test_missing_package_or_config_is_none(self):
        self.config.write_text(json.dumps({'packages': []}))
        self.assertIsNone(core_root(self.config))
        self.assertIsNone(core_root(self.app / 'missing.json'))


if __name__ == '__main__':
    unittest.main()
