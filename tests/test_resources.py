"""Synthetic encrypted headers and compressed sections; no game bytes or keys."""
from compression import zstd
import hashlib
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'script'))
from extract_romfs import decrypt_header, inspect_package, restore_ncz, hactool_key_subset
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes


def xts(data, key):
    result = bytearray()
    for sector in range(6):
        c = Cipher(algorithms.AES(key), modes.XTS(sector.to_bytes(16, 'big'))).encryptor()
        result += c.update(data[sector * 512:(sector + 1) * 512]) + c.finalize()
    return result


class ResourceTests(unittest.TestCase):
    @unittest.skipUnless((ROOT / 'work/tools/hactool').is_file(), 'prepare_resources.sh builds the optional resource tool')
    def test_bktr_metadata_integrity_and_bounds(self):
        header_key, key, rights = bytes(range(32)), bytes(range(16)), bytes(range(16, 32))
        body = bytearray(0x18200)
        for offset, total in ((0x4000, 0x4000), (0xc000, 0x4000)):
            struct.pack_into('<IIQ', body, offset, 0, 1, total)
            struct.pack_into('<IIQ', body, offset + 0x4000, 0, 1, total)
        struct.pack_into('<QQI', body, 0x8010, 0, 0, 1)
        struct.pack_into('<QII', body, 0x10010, 0, 0, 0)
        for i in range(4):
            body[0x14000 + 32*i:0x14020 + 32*i] = hashlib.sha256(body[0x4000 + 0x4000*i:0x8000 + 0x4000*i]).digest()
        meta = bytearray(0xe8)
        struct.pack_into('<Q4sIII', meta, 0, 0x14000, b'IVFC', 0x20000, 32, 3)
        struct.pack_into('<QQII', meta, 24, 0, 0x4000, 14, 0)
        struct.pack_into('<QQII', meta, 48, 0x4000, 0x10000, 14, 0)
        meta[0xc8:0xe8] = hashlib.sha256(body[0x14000:0x18000]).digest()
        body[0x18000:0x180e8] = meta
        fs = bytearray(512); fs[3:6] = bytes((3, 4, 1))
        struct.pack_into('<4sIII', fs, 8, b'IVFC', 0x20000, 32, 7)
        for i in range(6): struct.pack_into('<QQII', fs, 24+24*i, 0, 0x4000, 14, 0)
        struct.pack_into('<QQ4sIII', fs, 0x100, 0x4000, 0x8000, b'BKTR', 1, 1, 0)
        struct.pack_into('<QQ4sIII', fs, 0x120, 0xc000, 0x8000, b'BKTR', 1, 1, 0)
        struct.pack_into('<QQ', fs, 0x1a0, 0x18000, len(meta))
        fs[0x1b0:0x1d0] = hashlib.sha256(meta).digest()
        header = bytearray(0xc00); header[0x200:0x204] = b'NCA3'; header[0x206] = 1
        header[0x230:0x240] = rights
        struct.pack_into('<Q', header, 0x208, 0x4000+len(body))
        struct.pack_into('<II', header, 0x240, 0x20, (0x4000+len(body))//512)
        with tempfile.TemporaryDirectory(dir=ROOT / 'work/tmp') as temp:
            temp = Path(temp)
            (temp/'prod.keys').write_text('header_key = '+header_key.hex()+'\ntitlekek_00 = '+bytes(16).hex()+'\n')
            cipher = Cipher(algorithms.AES(bytes(16)), modes.ECB()).encryptor()
            (temp/'title.keys').write_text(rights.hex()+' = '+(cipher.update(key)+cipher.finalize()).hex()+'\n')
            def run(body, fs):
                header[0x400:0x600] = fs
                header[0x280:0x2a0] = hashlib.sha256(fs).digest()
                cipher = Cipher(algorithms.AES(key), modes.CTR((0x4000//16).to_bytes(16, 'big'))).encryptor()
                (temp/'fixture.nca').write_bytes(xts(header, header_key)+bytes(0x3400)+cipher.update(body)+cipher.finalize())
                return subprocess.run([str(ROOT/'work/tools/hactool'), '-k', str(temp/'prod.keys'),
                    '--titlekeysfile='+str(temp/'title.keys'), '--disablekeywarns', '--suppresskeys',
                    str(temp/'fixture.nca')], capture_output=True, text=True)
            result = run(body, fs)
            self.assertEqual(result.returncode, 0)
            self.assertIn('BKTR Metadata Hashes (GOOD)', result.stdout)
            self.assertNotIn('corrupted', result.stdout)
            for offset in (0x4010, 0x14010, 0x18010):
                corrupt = bytearray(body); corrupt[offset] ^= 1
                result = run(corrupt, fs)
                self.assertEqual(result.returncode, 1)
                self.assertIn('Invalid BKTR layout', result.stderr)
            malformed = bytearray(fs); struct.pack_into('<Q', malformed, 0x1a0, (1<<64)-1)
            self.assertEqual(run(body, malformed).returncode, 1)

    def test_hactool_receives_only_required_keys(self):
        required = dict(header_key=bytes(range(32)), titlekek_0e=bytes(16), titlekek_0f=bytes(range(16)))
        keys = required | dict(mariko_master_kek_source_05=bytes(17), master_key_15=bytes(16))
        self.assertEqual(hactool_key_subset(keys, [{'generation': 14}, {'generation': 15}]), required)
        self.assertEqual(len(keys), 5)

    def test_header_key_section_hash_and_version_bounds(self):
        keys = {'header_key': bytes(range(32)), 'titlekek_0f': bytes(range(16))}
        header = bytearray(0xc00)
        header[0x200:0x204] = b'NCA3'; header[0x206] = 16
        struct.pack_into('<QQ', header, 0x208, 0x8000, 0x0100f2c0115b6000)
        header[0x230:0x240] = bytes(range(16))
        struct.pack_into('<II', header, 0x240, 0x20, 0x40)
        header[0x403] = 3; header[0x404] = 4; header[0x408:0x40c] = b'IVFC'
        struct.pack_into('<Q', header, 0x498, 0x1000)
        header[0x280:0x2a0] = hashlib.sha256(header[0x400:0x600]).digest()
        encrypted = xts(header, keys['header_key'])
        self.assertEqual(decrypt_header(encrypted, keys['header_key']), header)
        with self.assertRaises(ValueError): decrypt_header(encrypted, bytes(reversed(range(32))))
        with self.assertRaises(ValueError): decrypt_header(encrypted[:-1], keys['header_key'])
        def package(raw):
            ncz = raw + bytes(0x3400) + struct.pack('<8sQ', b'NCZSECTN', 1)
            ncz += struct.pack('<QQQQ16s16s', 0x4000, 0x4000, 3, 0, bytes(range(16)), bytes(16))
            ncz += zstd.compress(bytes(0x4000))
            name = b'0' * 32 + b'.ncz\0'
            return struct.pack('<4sIIIQQII', b'PFS0', 1, len(name), 0, 0, len(ncz), 0, 0) + name + ncz
        with tempfile.TemporaryDirectory(dir=ROOT / 'work/tmp') as temp:
            p = Path(temp) / 'fixture.nsz'; p.write_bytes(package(encrypted))
            plan = inspect_package(p, keys, True)
            self.assertEqual((plan['generation'], plan['romfs_size']), (15, 0x1000))
            with self.assertRaises(ValueError): inspect_package(p, keys, False)
            header[0x410] ^= 1
            p.write_bytes(package(xts(header, keys['header_key'])))
            with self.assertRaises(ValueError): inspect_package(p, keys, True)

    def test_stream_restore_ctr_boundaries_hash_and_extra_data(self):
        raw = bytes(0x4000); key = bytes(range(16)); counter = bytes(range(16, 32))
        data = bytes(range(256)) * 16385
        sections, expected = [], raw
        cursor = len(raw)
        chunks = (data[:32], data[32:-32], data[-32:])
        for crypto, chunk in zip((1, 3, 4), chunks):
            sections.append((cursor, len(chunk), crypto, key, counter))
            if crypto != 1:
                c = Cipher(algorithms.AES(key), modes.CTR(counter[:8] + (cursor // 16).to_bytes(8, 'big'))).encryptor()
                expected += c.update(chunk) + c.finalize()
            else:
                expected += chunk
            cursor += len(chunk)
        wanted = hashlib.sha256(expected).hexdigest()
        with tempfile.TemporaryDirectory(dir=ROOT / 'work/tmp') as temp:
            p = Path(temp) / 'fixture.ncz'; out = Path(temp) / 'out.nca'
            p.write_bytes(zstd.compress(data))
            plan = dict(path=p, raw=raw, offset=0, length=p.stat().st_size, compressed=0,
                        sections=sections, nca_size=cursor, name=wanted[:32]+'.ncz')
            self.assertEqual(restore_ncz(plan, out), wanted)
            self.assertEqual(out.read_bytes(), expected)
            out.unlink(); plan['name'] = '0' * 32 + '.ncz'
            with self.assertRaisesRegex(ValueError, 'hash mismatch'): restore_ncz(plan, out)
            out.unlink(); plan['name'] = wanted[:32]+'.ncz'
            p.write_bytes(zstd.compress(data + b'x')); plan['length'] = p.stat().st_size
            with self.assertRaisesRegex(ValueError, 'length mismatch'): restore_ncz(plan, out)
