import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'script'))
from index_shaders import archive
from shader_pairs import name, programs, request


def section(items):
    return struct.pack('<II', 8 + sum(map(len, items)), len(items)) + b''.join(items)


def fixture():
    # Four declared graphics variations (one duplicate), then a compute program; controls use backward references.
    start = 0x950
    records, code, controls = [], bytearray(), {}
    for kind, identity in ((0, 0), (1, 0), (0, 0), (1, 1), (0, 2), (1, 2), (0, 0), (1, 0), (5, 0)):
        payload_start = start + 8 + sum(map(len, records)) + 16
        control = bytearray()
        if kind not in controls:
            controls[kind] = payload_start + 0x60
            control = bytearray(0x880)
            struct.pack_into('<3I', control, 0, 0x98761234, 1, 16)
            struct.pack_into('<I', control, 0x20, len(control))
            struct.pack_into('<8I', control, 0x6f8, 0x100, 0, 0x200, 0x200, 0x100 if kind == 5 else 0x30, 6, 0, kind)
            if kind == 5:
                struct.pack_into('<4I', control, 0x748, 4, 1, 1, 0)
        payload = struct.pack('<iIIiI', len(code), 0, 0x880, controls[kind] - payload_start, 0) + bytes(0x60 - 20) + control
        records.append(struct.pack('<4I', len(payload) + 16, 3 if kind == 5 else kind, 0, len(payload)) + payload)
        binary = bytearray(0x200)
        struct.pack_into('<I', binary, 0, 0x12345679 if kind == 5 else 0x12345678)
        binary[0x110] = identity
        code += binary

    macros = [struct.pack('<4I', 23, 2, 2, 1) + b'A\0' + b'0\0' + b'1\0' + b'\0'] * 2
    surface = b'surface\0'
    body = surface + section(macros) + section([]) * 2
    graphics = struct.pack('<4I', 16 + len(body), len(surface), 3, 0) + body
    body = b'compute\0' + section([]) * 3
    compute = struct.pack('<4I', 16 + len(body), 8, 8, 8) + body
    binaries = section(records)
    program_start = start + len(binaries)
    table = section([graphics, compute])
    code_start = (program_start + len(table) + 0x7ff) & ~0x7ff
    data = bytearray(code_start + len(code))
    struct.pack_into('<4s7I', data, 0, b'BAHS', 9, len(data), 5, 0, 0x800, len(code), code_start)
    data[start:start + len(binaries)] = binaries
    data[program_start:program_start + len(table)] = table
    data[code_start:] = code
    return data, program_start


class ShaderPairTests(unittest.TestCase):
    def test_bahs_declared_variations_and_compute_stage(self):
        data, _ = fixture()
        entries = [entry for entry, _ in archive(data)]
        expected = [{'vs': entries[i]['key'], 'ps': entries[i + 1]['key']} for i in range(0, 8, 2)]
        expected.append({'cs': entries[8]['key']})
        self.assertEqual(list(programs(data)), expected)
        self.assertEqual(expected[0], expected[3])
        self.assertNotEqual(expected[0], expected[1])

    def test_bahs_rejects_invalid_program_ranges_and_variations(self):
        data, table = fixture()
        program = table + 8
        macro_section = program + 16 + 8
        macro = macro_section + 8
        mutations = [
            (0, 0), (4, 8), (8, len(data) - 1), (table, 7), (table + 4, 3),
            (program, 15), (program + 4, 0), (program + 4, 0xffffffff),
            (program + 8, 0), (program + 8, 16), (program + 8, 8), (program + 12, 9),
            (macro_section, 7), (macro_section + 4, 3), (macro, 15),
            (macro + 4, 100), (macro + 8, 0), (macro + 8, 0xffffffff), (macro + 12, 100),
        ]
        for offset, value in mutations:
            with self.subTest(offset=offset, value=value):
                broken = bytearray(data)
                struct.pack_into('<I', broken, offset, value)
                with self.assertRaises(ValueError):
                    list(programs(broken))
        for offset in (program + 23, macro + 17, macro + 19, macro + 22):
            with self.subTest(unterminated=offset):
                broken = bytearray(data); broken[offset] = ord('x')
                with self.assertRaises(ValueError):
                    list(programs(broken))

    def test_bahs_requests_only_declared_pairs_and_preserves_existing_requests(self):
        data, _ = fixture()
        entries = {entry['key']: dict(entry, source='fixture.sharcb') for entry, _ in archive(data)}
        expected = {name(p['vs'], 0, p['ps']): {'base': p['vs'], 'mask': 0, 'next': p['ps']}
                    for p in programs(data) if 'vs' in p and 'ps' in p}
        self.assertEqual(len(expected), 3)
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(dir=root / 'work/tmp') as directory, patch('shader_pairs.chain', return_value='test'):
            path = Path(directory)
            (path / 'source').mkdir(); (path / 'variants').mkdir()
            (path / 'source/fixture.sharcb').write_bytes(data)
            (path / 'index.json').write_text(json.dumps(list(entries.values())))
            key = next(iter(expected))
            old = path / 'variants' / (key + '.json')
            old.write_text(json.dumps(expected[key], indent=2) + '\n')
            contents, timestamp = old.read_bytes(), old.stat().st_mtime_ns
            self.assertEqual(request(path), 2)
            self.assertEqual(request(path), 0)
            self.assertEqual(old.read_bytes(), contents)
            self.assertEqual(old.stat().st_mtime_ns, timestamp)
            self.assertEqual({p.stem: json.loads(p.read_text()) for p in (path / 'variants').iterdir()}, expected)


if __name__ == '__main__':
    unittest.main()
