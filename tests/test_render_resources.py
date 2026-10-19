import hashlib
from pathlib import Path
import struct
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'script'))
import prepare_render_resources as resources
from extract_shaders import decompress, zstd


class RenderResourceTests(unittest.TestCase):
    def test_only_verified_child_and_parent_budgets_change(self):
        original = bytearray(3716)
        for offset, before, _, _ in resources.CHANGES:
            struct.pack_into('<I', original, offset, before)
        packed = zstd.compress(original)
        with self.assertRaises(ValueError):
            resources.patch_config(packed, {})
        with patch.object(resources, 'SOURCE_SHA', hashlib.sha256(packed).hexdigest()):
            result = bytearray(decompress(resources.patch_config(packed, {}), {}))
            for offset, before, after, _ in resources.CHANGES:
                self.assertEqual(struct.unpack_from('<I', result, offset)[0], after)
                struct.pack_into('<I', result, offset, before)
            self.assertEqual(result, original)
            changed = bytearray(packed); changed[-1] ^= 1
            with self.assertRaises(ValueError):
                resources.patch_config(changed, {})
