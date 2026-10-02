"""Check an actual module ZIP against the UCP frontend's live locale registry.

Set UCP_TEST_ZIP and UCP_GUI_LANGUAGES before running this file.
Requires PyYAML for development only; nothing here is included in the module.
"""
import os
from pathlib import Path
import re
import unittest
import zipfile

import yaml


MODULE = Path(__file__).resolve().parents[1] / 'module'


class PackageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.archive = zipfile.ZipFile(os.environ['UCP_TEST_ZIP'])
        cls.languages = yaml.safe_load(
            Path(os.environ['UCP_GUI_LANGUAGES']).read_text(encoding='utf-8'))

    @classmethod
    def tearDownClass(cls):
        cls.archive.close()

    def test_package_inputs_and_metadata(self):
        archive = self.archive
        self.assertIsNone(archive.testzip())
        definition = yaml.safe_load(archive.read('definition.yml'))
        self.assertEqual(definition['meta']['version'], '1.0.0')
        self.assertEqual(definition['type'], 'module')
        self.assertEqual(definition['game'], ['SHC==1.41', 'SHCE==1.41'])
        self.assertEqual(set(definition['dependencies']), {'framework', 'frontend'})
        self.assertNotIn('family', definition)
        expected = set()
        for item in yaml.safe_load((MODULE / 'files.yml').read_text(encoding='utf-8'))['files']:
            path = MODULE / item['src']
            for source in path.rglob('*') if path.is_dir() else [path]:
                if source.is_file():
                    name = source.relative_to(MODULE).as_posix()
                    expected.add(name)
                    packaged, original = archive.read(name), source.read_bytes()
                    # The Store builds from a fresh Windows Git checkout; this
                    # review checkout can have LF files. Keep binary comparisons
                    # exact while accepting Git's ordinary text conversion.
                    if source.suffix in ('.lua', '.yml', '.md'):
                        packaged = packaged.replace(b'\r\n', b'\n')
                        original = original.replace(b'\r\n', b'\n')
                    self.assertEqual(packaged, original, name)
        self.assertEqual({n for n in archive.namelist() if not n.endswith('/')}, expected)
        self.assertFalse(any(n.endswith('.py') or n.startswith(('bench/', 'tools/', 'tests/'))
                             for n in archive.namelist()))

    def test_every_registered_language_is_available_in_zip(self):
        archive = self.archive
        self.assertIn('locale/', archive.namelist())
        keys = set(re.findall(r'{{(.*?)}}', archive.read('options.yml').decode('utf-8')))
        english = yaml.safe_load(archive.read('locale/en.yml'))
        for language in self.languages:
            with self.subTest(language=language):
                catalog = yaml.safe_load(archive.read(f'locale/{language}.yml'))
                self.assertEqual(set(catalog), set(english))
                self.assertTrue(keys <= catalog.keys())
                self.assertTrue(all(isinstance(v, str) and v.strip() for v in catalog.values()))
                # Resolved category strings are grouping keys in the existing frontend.
                self.assertEqual(catalog['bugfixes'], 'Bugfixes')
                self.assertEqual(catalog['balance_changes'], 'Balance Changes')
                self.assertTrue(archive.read(f'locale/description-{language}.md').strip())
        self.assertEqual(archive.read('description.md'), archive.read('locale/description-en.md'))

    def test_existing_switches_and_defaults_are_preserved(self):
        groups = yaml.safe_load(self.archive.read('options.yml'))['options']
        self.assertEqual([g['category'] for g in groups],
                         [['{{bugfixes}}'], ['{{bugfixes}}'], ['{{balance_changes}}']])
        controls = [c for g in groups for c in g.get('children', [g])]
        switches = {c['url']: c['contents']['value'] for c in controls}
        self.assertEqual(switches, {
            'smarter-gatehouses.pathing.enemy_gates_closed': True,
            'smarter-gatehouses.detection.centred': True,
            'smarter-gatehouses.detection.reachable_only': True,
            'smarter-gatehouses.walls.stairs_needed': False,
            'smarter-gatehouses.walls.stairs_needed_ai': False,
        })
        self.assertTrue(all(c['display'] == 'Switch' for c in controls))


if __name__ == '__main__':
    unittest.main()
