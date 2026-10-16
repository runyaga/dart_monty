"""Verifier unit tests; synthetic runner records are not execution evidence."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('resolution', Path(__file__).with_name('check_d1_resolution.py'))
resolution = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resolution)


class ResolutionTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.manifest = json.loads(Path(__file__).with_name('d1-pending-resolution.json').read_text())
        for entry in self.manifest['tests']:
            entry['assertions'] = [entry['id']]
        self.events = []
        for index, entry in enumerate(self.manifest['tests']):
            self.events.extend([
                {'type': 'suite', 'suite': {'id': index, 'path': entry['file']}},
                {'type': 'testStart', 'test': {'id': index, 'suiteID': index, 'name': entry['name']}},
                {'type': 'testDone', 'testID': index, 'result': 'success', 'skipped': False, 'hidden': False},
            ])
        for backend in ['vm', 'dart2js', 'dart2wasm']:
            self.write_cell(backend, self.events)

    def write_cell(self, backend, events):
        cell = self.root / backend
        cell.mkdir(exist_ok=True)
        (cell / 'results.jsonl').write_text('\n'.join(json.dumps(event) for event in events))

    def test_complete(self):
        self.assertEqual(resolution.verify(self.manifest, self.root), [])

    def test_removed_id(self):
        self.manifest['tests'].pop()
        with self.assertRaises(AssertionError):
            resolution.verify(self.manifest, self.root)

    def test_wrong_id_equal_count(self):
        self.manifest['tests'][0]['id'] += '-wrong'
        with self.assertRaises(AssertionError):
            resolution.verify(self.manifest, self.root)

    def test_skipped(self):
        events = copy.deepcopy(self.events)
        events[2]['skipped'] = True
        self.write_cell('dart2wasm', events)
        with self.assertRaises(AssertionError):
            resolution.verify(self.manifest, self.root)

    def test_empty_cell(self):
        self.write_cell('dart2js', [])
        with self.assertRaises(AssertionError):
            resolution.verify(self.manifest, self.root)

    def test_unmapped(self):
        self.manifest['tests'][0]['assertions'] = []
        with self.assertRaises(AssertionError):
            resolution.verify(self.manifest, self.root)


if __name__ == '__main__':
    unittest.main()
