import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'script'))
from probe_shader_libraries import samples, rename_entry


class LibraryProbeTests(unittest.TestCase):
    def test_sampling_is_bounded_deduplicated_and_requires_each_stage(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'work/tmp') as temporary:
            root = Path(temporary)
            records = []
            for stage in (0, 1, 5):
                for i in range(20):
                    key = f'{stage * 100 + i:016x}_b'
                    (root / (key + '.metallib')).write_bytes(b'x' * (i + 1))
                    records.extend([f'S\t{key}\t{stage}'] * 2)
            selected = samples(root, '\n'.join(records))
            self.assertEqual(len(selected), 9)
            self.assertEqual(len(set(selected)), 9)
            for offset in range(0, 9, 3):
                self.assertEqual([(root / (key + '.metallib')).stat().st_size for key, _, _ in selected[offset:offset + 3]], [1, 10, 19])
            with self.assertRaises(ValueError): samples(root, '')
            with self.assertRaises(ValueError): samples(root, 'S\t../outside\t0')

    def test_isolated_entry_does_not_rename_similar_identifiers(self):
        source = 'struct main0_out {}; main0_out main0() { return main0_out(); }'
        result = rename_entry(source, 'main0', 'a' * 32)
        self.assertIn('main0_' + 'a' * 32 + '()', result)
        self.assertEqual(result.count('main0_out'), 3)
        for entry, suffix in [('main0', 'bad-token'), ('missing', 'a' * 32), ('main.*', 'a' * 32)]:
            with self.assertRaises(ValueError): rename_entry(source, entry, suffix)
