from pathlib import Path
import hashlib
import json
import re
import struct
import unittest

import lz4.block


ROOT = Path(__file__).resolve().parents[1]


class LocalImageTests(unittest.TestCase):
    @unittest.skipUnless((ROOT / 'work/exefs/main.npdm').is_file(), 'requires local NPDM')
    def test_kernel_profile_matches_npdm(self):
        data = (ROOT / 'work/exefs/main.npdm').read_bytes()
        self.assertEqual(data[:4], b'META')
        self.assertEqual((data[0xe], data[0xf]), (44, 0))
        self.assertEqual(struct.unpack_from('<I', data, 0x14)[0], 0x1800000)
        aci = struct.unpack_from('<I', data, 0x70)[0]
        self.assertEqual(data[aci:aci + 4], b'ACI0')
        offset, size = struct.unpack_from('<II', data, aci + 0x30)
        flags = [v for (v,) in struct.iter_unpack('<I', data[aci + offset:aci + offset + size]) if v & 15 == 7]
        self.assertEqual(len(flags), 1)
        value = flags[0]
        self.assertEqual(((value >> 4) & 63, (value >> 10) & 63, (value >> 16) & 255, value >> 24), (59, 28, 0, 2))
        offset, size = struct.unpack_from('<II', data, aci + 0x28)
        access = data[aci + offset:aci + offset + size]
        names = set()
        while access:
            length = (access[0] & 7) + 1
            self.assertFalse(access[0] & 0x80)
            names.add(access[1:1 + length].decode('ascii'))
            access = access[1 + length:]
        source = (ROOT / 'host/services.c').read_text().split('allowed_services[] = {', 1)[1].split('};', 1)[0]
        self.assertEqual(set(re.findall(r'"([^"]+)"', source)), names)

    @unittest.skipUnless((ROOT / 'work/patched/build.json').is_file(), 'requires locally prepared game files')
    def test_data_unchanged_and_code_changes_declared(self):
        for name in ('main', 'sdk', 'subsdk0'):
            with self.subTest(module=name):
                raw = (ROOT / 'work/exefs' / name).read_bytes()
                flags = struct.unpack_from('<I', raw, 0xc)[0]
                segments = [struct.unpack_from('<III', raw, 0x10 + 16 * i) for i in range(3)]
                sizes = struct.unpack_from('<III', raw, 0x60)
                patched = (ROOT / 'work/patched' / f'{name}.patched.bin').read_bytes()
                sites = set()
                timing = {}
                manifest = ROOT / 'work/patched/main.timing.json'
                if name == 'main' and manifest.is_file():
                    declared = json.loads(manifest.read_text())
                    # Timing writes, plus the render-scale site recorded beside them (tools/render_scale.py).
                    for change in declared['writes'] + declared.get('render_scale', {}).get('writes', []):
                        old, new = bytes.fromhex(change['original']), bytes.fromhex(change['replacement'])
                        self.assertEqual(len(old), len(new))
                        for off in range(0, len(old), 4):
                            timing[change['offset'] + off] = (old[off:off + 4], new[off:off + 4])
                for line in (ROOT / 'work/patched' / f'{name}.sites.tsv').read_text().splitlines():
                    fields = line.split('\t')
                    if fields[1] != 'J':
                        sites.add(int(fields[0], 16))
                for i, (fileoff, memory, size) in enumerate(segments):
                    data = raw[fileoff:fileoff + (sizes[i] if flags & (1 << i) else size)]
                    if flags & (1 << i):
                        data = lz4.block.decompress(data, uncompressed_size=size)
                    rewritten = patched[memory:memory + size]
                    if i:
                        self.assertEqual(hashlib.sha256(data).hexdigest(), hashlib.sha256(rewritten).hexdigest(),
                                         f'{name}: non-code segment changed')
                    else:
                        for pc in range(0, size, 4):
                            if data[pc:pc + 4] != rewritten[pc:pc + 4]:
                                if memory + pc in timing:
                                    self.assertEqual((data[pc:pc + 4], rewritten[pc:pc + 4]), timing[memory + pc])
                                    continue
                                self.assertTrue(memory + pc in sites, f'{name}: undeclared write at {memory + pc:#x}')
                                self.assertEqual(int.from_bytes(rewritten[pc:pc + 4], 'little') >> 26, 5)
                for suffix in ('cuts', 'obs', 'params'):
                    lines = (ROOT / 'work/patched' / f'{name}.{suffix}.tsv').read_text().splitlines()
                    self.assertTrue(all(not line or line.startswith('#') for line in lines))


if __name__ == '__main__':
    unittest.main()
