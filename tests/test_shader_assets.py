from compression import zstd
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'script'))
from extract_shaders import RomFS, sarc, decompress, layout_shaders


class ShaderAssetTests(unittest.TestCase):
    def test_layout_shaders_are_namespaced_and_do_not_overwrite(self):
        self.assertEqual(layout_shaders('/UI/Title.blarc.zs', {'bgsh/main.bnsh': b'code', 'timg/main.bntx': b'tex'}),
                         {'UI-Title-main.bnsh': b'code'})
        with self.assertRaises(ValueError):
            layout_shaders('Title.blarc.zs', {'bgsh/main.bnsh': b'one', 'other/main.bnsh': b'two'})

    def test_romfs_selected_reads_reject_cycles_and_out_of_bounds(self):
        image = bytearray(0x104)
        struct.pack_into('<10Q', image, 0, 80, 0x80, 4, 0x84, 56, 0xbc, 4, 0xc0, 40, 0x100)
        struct.pack_into('<6I', image, 0x84, 0, 0xffffffff, 24, 0xffffffff, 0xffffffff, 0)
        struct.pack_into('<6I', image, 0x9c, 0, 0xffffffff, 0xffffffff, 0, 0xffffffff, 6)
        image[0xb4:0xba] = b'Shader'
        struct.pack_into('<IIQQII', image, 0xc0, 24, 0xffffffff, 0, 4, 0xffffffff, 1)
        image[0xe0] = ord('x'); image[0x100:] = b'BNSH'
        with tempfile.TemporaryFile() as stream:
            stream.write(image); stream.flush(); rom = RomFS(stream)
            self.assertEqual(rom.file('/Shader/x'), b'BNSH')
            with self.assertRaises(ValueError): rom.file('/Shader/missing')
            stream.seek(0xd0); stream.write(struct.pack('<Q', 8)); stream.flush()
            with self.assertRaises(ValueError): rom.file('/Shader/x')
            stream.seek(0xa0); stream.write(struct.pack('<I', 24)); stream.flush()
            with self.assertRaises(ValueError): rom.file('/Shader/x')

    def test_sarc_and_zstd_reject_truncation_and_unsafe_paths(self):
        data = bytearray(68)
        struct.pack_into('<4sHHIIHH', data, 0, b'SARC', 20, 0xfeff, 68, 64, 0x100, 0)
        struct.pack_into('<4sHHI', data, 20, b'SFAT', 12, 1, 0x65)
        struct.pack_into('<4I', data, 32, 0, 0x1000000, 0, 4)
        struct.pack_into('<4sHH', data, 48, b'SFNT', 8, 0)
        data[56:64] = b'x.bnsh\0\0'; data[64:] = b'code'
        self.assertEqual(sarc(data), {'x.bnsh': b'code'})
        frame = zstd.compress(data)
        self.assertEqual(decompress(frame, {}), data)
        with self.assertRaises(ValueError): decompress(frame[:-1], {})
        with self.assertRaises(ValueError): decompress(frame + frame, {})
        with self.assertRaises(ValueError): sarc(data[:-1])
        data[56:64] = b'../x\0\0\0\0'
        with self.assertRaises(ValueError): sarc(data)


if __name__ == '__main__':
    unittest.main()
