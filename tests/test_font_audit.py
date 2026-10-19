import struct
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'script'))
from font_audit import layout_fonts, message_characters


class FontAuditTests(unittest.TestCase):
    def test_message_controls_are_not_font_characters(self):
        text = 'A\u84cb\U0001f600'.encode('utf-16-le')
        text += struct.pack('<HHHHH', 14, 2, 3, 2, 0xe37f)
        text += struct.pack('<HHHHH', 15, 2, 3, ord('B'), 0)
        payload = struct.pack('<II', 1, 8) + text
        data = bytearray(32)
        data[:10] = b'MsgStdBn\xff\xfe'; data[12] = 1
        struct.pack_into('<H', data, 14, 1)
        data += b'TXT2' + struct.pack('<I', len(payload)) + bytes(8) + payload
        struct.pack_into('<I', data, 18, len(data))
        self.assertEqual(message_characters(data), {ord(c) for c in 'A\u84cb\U0001f600B'})
        struct.pack_into('<I', data, 52, 0)
        with self.assertRaises(ValueError):
            message_characters(data)

    def test_layout_font_offsets_and_bounds(self):
        block = bytearray(b'fnl1' + bytes(8))
        struct.pack_into('<H', block, 8, 2)
        block.extend(struct.pack('<II', 8, 24))
        block.extend(b'Normal_00.fcpx\0\0External_00.fcpx\0')
        struct.pack_into('<I', block, 4, len(block))
        data = bytearray(b'FLYT\xff\xfe' + struct.pack('<HIIHH', 20, 0x09030000, 20 + len(block), 1, 0)) + block
        self.assertEqual(layout_fonts(data), ['Normal_00.fcpx', 'External_00.fcpx'])
        with self.assertRaises(ValueError):
            layout_fonts(data[:-1])
        struct.pack_into('<I', data, 20 + 12, 0)
        with self.assertRaises(ValueError):
            layout_fonts(data)
        struct.pack_into('<I', data, 20 + 12, 0xffffffff)
        with self.assertRaises(ValueError):
            layout_fonts(data)
