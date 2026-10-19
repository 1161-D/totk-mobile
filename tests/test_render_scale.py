import struct
import unittest

from test_exclusive import encoders
from game_timing import apply_timing, BUILD_ID, ORIGINAL as TIMING_ORIGINAL, STATE_OFFSET
from render_scale import apply_render_scale, ORIGINAL, RESUME, SCALE_OFFSET, SITE, DYNAMIC_SITE, DYNAMIC_ORIGINAL
from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM
from unicorn.arm64_const import *

BASE = 0x10000000


def bits(value):
    return struct.unpack('<I', struct.pack('<f', value))[0]


def value(word):
    return struct.unpack('<f', struct.pack('<I', word & 0xffffffff))[0]


class RenderScaleTests(unittest.TestCase):
    def prepared(self):
        env = encoders()
        env.update(BUILD_ID=BUILD_ID, KEY_PAGE_OFF=STATE_OFFSET - 0x4000, PATCH_OFF=0x3af0000, IMG=bytearray(STATE_OFFSET))
        for offset, expected in TIMING_ORIGINAL.items():
            env['IMG'][offset:offset + len(expected) // 2] = bytes.fromhex(expected)
        struct.pack_into('<4I', env['IMG'], SITE, *ORIGINAL)
        struct.pack_into('<I', env['IMG'], DYNAMIC_SITE, DYNAMIC_ORIGINAL)
        apply_timing(env)
        return env

    def run_site(self, image, patch, factor, width, height, scale_x, scale_y):
        uc = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
        uc.mem_map(BASE, 0x4000000)
        uc.mem_write(BASE, bytes(image) + bytes(patch))
        uc.mem_write(BASE + SCALE_OFFSET, struct.pack('<f', factor))
        for register, number in ((UC_ARM64_REG_S2, width), (UC_ARM64_REG_S3, height),
                                 (UC_ARM64_REG_S5, scale_x), (UC_ARM64_REG_S4, scale_y)):
            uc.reg_write(register, bits(number))
        uc.emu_start(BASE + SITE, BASE + RESUME)
        return [value(uc.reg_read(r)) for r in (UC_ARM64_REG_S0, UC_ARM64_REG_S1, UC_ARM64_REG_S4)], uc.reg_read(UC_ARM64_REG_W8)

    def test_default_factor_keeps_sizes_and_other_factors_scale_both_extents(self):
        original = self.prepared()
        unpatched = self.run_site(original['IMG'], b'', 1.0, 1920.0, 1080.0, 5 / 6, 5 / 6)
        env = self.prepared()
        record = apply_render_scale(env)
        self.assertEqual(struct.unpack_from('<f', env['IMG'], SCALE_OFFSET)[0], 1.0)
        self.assertEqual(record['writes'][0]['offset'], SITE)
        # The prepared factor gives the original registers bit for bit: extents, the 16384 clamp in s4 and w8.
        self.assertEqual(self.run_site(env['IMG'], env['patch'], 1.0, 1920.0, 1080.0, 5 / 6, 5 / 6), unpatched)
        # Original also preserves the game's lower dynamic levels and non-scene views, not a fixed 896p size.
        for w, h, sx, sy in ((1920, 1080, 2/3, 2/3), (1920, 1080, .75, .75), (800, 450, 1, 1), (512, 256, .5, 1)):
            self.assertEqual(self.run_site(env['IMG'], env['patch'], 1, w, h, sx, sy),
                             self.run_site(original['IMG'], b'', 1, w, h, sx, sy))
        (width, height, clamp), w8 = self.run_site(env['IMG'], env['patch'], 1.2, 1920.0, 1080.0, 5 / 6, 5 / 6)
        self.assertAlmostEqual(width, 1920.0, places=3)
        self.assertAlmostEqual(height, 1080.0, places=3)
        self.assertEqual((clamp, w8), (16384.0, 0x46800000))
        (width, height, _), _ = self.run_site(env['IMG'], env['patch'], 0.8, 1920.0, 1080.0, 5 / 6, 5 / 6)
        self.assertAlmostEqual(width, 1280.0, places=3)
        self.assertAlmostEqual(height, 720.0, places=3)

    def test_height_presets_land_on_their_sizes_after_the_games_floor(self):
        env = self.prepared()
        apply_render_scale(env)
        f32 = lambda x: struct.unpack('<f', struct.pack('<f', x))[0]
        # Factors as host/game_timing.c computes them: (height + 0.5) / 900 in single precision.
        for height, expected in ((1080, (1920, 1080)), (720, (1280, 720)), (640, (1136, 640))):
            factor = f32(f32(height + 0.5) / 900.0)
            (width, scaled, _), _ = self.run_site(env['IMG'], env['patch'], factor, 1920.0, 1080.0, f32(5 / 6), f32(5 / 6))
            self.assertEqual((int(width // 8) * 8, int(scaled // 8) * 8), expected)

    def test_only_original_uses_dynamic_scale_and_other_registers_are_preserved(self):
        env = self.prepared()
        apply_render_scale(env)
        uc = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
        uc.mem_map(BASE, 0x4000000)
        uc.mem_write(BASE, bytes(env['IMG']) + bytes(env['patch']))
        for factor in (1, (1080.5/900), (720.5/900), (640.5/900)):
            for dynamic in (.8, .9, 1):
                for flags in (0, 0xf0000000):
                    uc.mem_write(BASE + SCALE_OFFSET, struct.pack('<f', factor))
                    uc.mem_write(BASE + 0x2000028, struct.pack('<f', dynamic))
                    registers = {UC_ARM64_REG_X8: BASE + 0x2000000, UC_ARM64_REG_X16: 0x12345678,
                                 UC_ARM64_REG_X17: 0x87654321, UC_ARM64_REG_SP: BASE + 0x3000000, UC_ARM64_REG_NZCV: flags}
                    for reg, v in registers.items(): uc.reg_write(reg, v)
                    uc.emu_start(BASE + DYNAMIC_SITE, BASE + DYNAMIC_SITE + 4)
                    self.assertEqual(uc.reg_read(UC_ARM64_REG_S6), bits(dynamic if factor == 1 else 1))
                    for reg, v in registers.items(): self.assertEqual(uc.reg_read(reg), v)

    def test_rejects_other_builds_changed_bytes_and_a_second_rewrite(self):
        env = self.prepared()
        with self.assertRaises(ValueError):
            apply_render_scale(env | {'BUILD_ID': '0' * 32})
        changed = self.prepared()
        struct.pack_into('<I', changed['IMG'], SITE + 4, 0xd503201f)
        with self.assertRaises(ValueError):
            apply_render_scale(changed)
        changed = self.prepared()
        struct.pack_into('<I', changed['IMG'], DYNAMIC_SITE, 0xd503201f)
        with self.assertRaises(ValueError):
            apply_render_scale(changed)
        apply_render_scale(env)
        with self.assertRaises(ValueError):
            apply_render_scale(env)


if __name__ == '__main__':
    unittest.main()
