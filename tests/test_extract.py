from compression.zstd import compress
import hashlib
import io
import json
import struct
import tempfile
import unittest

from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from extract_exefs import exefs_from_ncz, nso_info, pfs_entries
from prepare_modules import ready, ROOT


def pfs(files):
    names, records, data = b'', b'', b''
    for name, body in files:
        records += struct.pack('<QQII', len(data), len(body), len(names), 0)
        names += name.encode() + b'\0'
        data += body
    return struct.pack('<4sIII', b'PFS0', len(files), len(names), 0) + records + names + data


class ExtractTests(unittest.TestCase):
    def test_stale_and_corrupt_outputs_are_rejected(self):
        (ROOT / 'work/tmp').mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / 'work/tmp') as tmp:
            output = Path(tmp)
            inputs = {'revision': 1}
            info = {'inputs': inputs, 'outputs': {'main.patched.bin': hashlib.sha256(b'ok').hexdigest()}}
            (output / 'build.json').write_text(json.dumps(info))
            self.assertFalse(ready(output, inputs))
            (output / 'main.patched.bin').write_bytes(b'ok')
            self.assertTrue(ready(output, inputs))
            self.assertFalse(ready(output, {'revision': 2}))
            (output / 'main.patched.bin').write_bytes(b'bad')
            self.assertFalse(ready(output, inputs))

    def test_solid_ncz_without_keys(self):
        files = [('main', b'NSO0test'), ('sdk', b'NSO0sdk'), ('main.npdm', b'META')]
        raw = bytes(0x8000) + pfs(files)
        ncz = bytes(0x4000) + struct.pack('<8sQ', b'NCZSECTN', 1)
        ncz += struct.pack('<QQQQ', 0x4000, len(raw), 3, 0) + bytes(32) + compress(raw)
        self.assertEqual(exefs_from_ncz(io.BytesIO(ncz), 0, len(ncz)), dict(files))
        with self.assertRaises(Exception):
            exefs_from_ncz(io.BytesIO(ncz[:-4]), 0, len(ncz) - 4)

    def test_rejects_traversal_duplicates_and_bad_bounds(self):
        for files in ([('../main', b'x')], [('main', b'x'), ('main', b'y')]):
            data = pfs(files)
            with self.assertRaises(ValueError):
                pfs_entries(io.BytesIO(data), 0, len(data))
        data = bytearray(pfs([('main', b'x')]))
        struct.pack_into('<Q', data, 16, 1 << 40)
        with self.assertRaises(ValueError):
            pfs_entries(io.BytesIO(data), 0, len(data))

    def test_nso_hash_validation(self):
        data = bytearray(0x100)
        data[:4] = b'NSO0'
        struct.pack_into('<I', data, 0xc, 0x38)
        for i in range(3):
            body = bytes([i + 1]) * 16
            struct.pack_into('<III', data, 0x10 + 16 * i, len(data), i * 0x1000, len(body))
            data[0xa0 + 32 * i:0xc0 + 32 * i] = hashlib.sha256(body).digest()
            data.extend(body)
        self.assertEqual(len(nso_info(data)['segments']), 3)
        data[-1] ^= 1
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            nso_info(data)


if __name__ == '__main__':
    unittest.main()
