from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

from test_exclusive import encoders
from game_timing import apply_timing, BUILD_ID, MAGIC, ORIGINAL, STATE_OFFSET
from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM
from unicorn.arm64_const import *

ROOT = Path(__file__).resolve().parents[1]


class GameTimingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.env = encoders()
        cls.env.update(BUILD_ID=BUILD_ID, KEY_PAGE_OFF=STATE_OFFSET - 0x4000,
                       PATCH_OFF=0x3af0000, IMG=bytearray(STATE_OFFSET))
        for offset, expected in ORIGINAL.items():
            cls.env['IMG'][offset:offset + len(expected) // 2] = bytes.fromhex(expected)
        cls.record = apply_timing(cls.env)

    def machine(self):
        uc = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
        uc.mem_map(0x10000000, 0x4000000)
        uc.mem_map(0x20000000, 0x10000)
        uc.mem_map(0x30000000, 0x10000)
        for change in self.record['writes']:
            uc.mem_write(0x10000000 + change['offset'], bytes.fromhex(change['replacement']))
        uc.mem_write(0x10000000 + self.env['PATCH_OFF'], bytes(self.env['patch']))
        uc.mem_write(0x10000000 + STATE_OFFSET, MAGIC + bytes(4) + struct.pack('<fdd', 60.0, 0.0, 0.0))
        uc.reg_write(UC_ARM64_REG_SP, 0x30008000)
        uc.reg_write(UC_ARM64_REG_LR, 0x10001000)
        return uc

    def test_elapsed_time_and_preserved_registers(self):
        uc = self.machine()
        # Synthetic standard AAPCS64 prologue/epilogue matching the replaced function's frame.
        uc.mem_write(0x102db174, struct.pack('<6I', 0xd10183ff, 0xa9027bfd, 0xf9001bf7,
                                           0xa90457f6, 0xa9054ff4, 0x910083fd))
        uc.mem_write(0x102db284, struct.pack('<6I', 0xa9454ff4, 0xa94457f6, 0xf9401bf7,
                                           0xa9427bfd, 0x910183ff, 0xd65f03c0))
        for target in (60, 90, 120):
            for movie in (0, 1):
                for ticks in (0, 160000, 320000, 320320, 640000, 970000, 1280000, 1920000, 2**64 - 1):
                    with self.subTest(target=target, movie=movie, ticks=ticks):
                        uc.mem_write(0x10000000 + STATE_OFFSET + 8, bytes([movie]))
                        uc.mem_write(0x10000000 + STATE_OFFSET + 12, struct.pack('<fdd', target, 0.0, 0.0))
                        uc.mem_write(0x20000000, bytes([0xa5]) * 0x100)
                        uc.mem_write(0x200010d8, struct.pack('<Q', ticks))
                        uc.reg_write(UC_ARM64_REG_X0, 0x20000000)
                        uc.reg_write(UC_ARM64_REG_X1, 0x20001000)
                        for r in range(18, 30):
                            uc.reg_write(globals()[f'UC_ARM64_REG_X{r}'], 0xabc000 + r)
                        for r in range(8, 16):
                            uc.reg_write(globals()[f'UC_ARM64_REG_D{r}'], 0x12340000 + r)
                        uc.reg_write(UC_ARM64_REG_LR, 0x10001000)
                        uc.emu_start(0x102db174, 0x10001000, count=100)
                        self.assertEqual(uc.reg_read(UC_ARM64_REG_PC), 0x10001000)
                        self.assertEqual(uc.reg_read(UC_ARM64_REG_SP), 0x30008000)
                        expected = min(30 if movie else target, max(15, 19200000 / ticks if ticks else target))
                        result = bytes(uc.mem_read(0x20000000, 0x100))
                        actual = struct.unpack_from('<f', result, 0x24)[0]
                        self.assertAlmostEqual(actual, expected, places=4)
                        elapsed = struct.unpack('<d', bytes(uc.mem_read(0x10000000 + STATE_OFFSET + 16, 8)))[0]
                        # Game seconds advance by the exact double-precision step the fps field was derived from.
                        ceiling = 30 if movie else target
                        step = min(1 / 15, max(1 / ceiling, ticks / 19200000))
                        self.assertAlmostEqual(elapsed, step, places=12)
                        self.assertEqual(struct.unpack_from('<I', result, 0x50)[0], int(actual))
                        for i, value in enumerate(result):
                            if not (0x24 <= i < 0x28 or 0x50 <= i < 0x54):
                                self.assertEqual(value, 0xa5)
                        for r in range(18, 30):
                            self.assertEqual(uc.reg_read(globals()[f'UC_ARM64_REG_X{r}']), 0xabc000 + r)
                        for r in range(8, 16):
                            self.assertEqual(uc.reg_read(globals()[f'UC_ARM64_REG_D{r}']), 0x12340000 + r)

    def test_short_frames_are_repaid_without_catching_up_long_ones(self):
        uc = self.machine()
        uc.mem_write(0x102db174, struct.pack('<6I', 0xd10183ff, 0xa9027bfd, 0xf9001bf7,
                                           0xa90457f6, 0xa9054ff4, 0x910083fd))
        uc.mem_write(0x102db284, struct.pack('<6I', 0xa9454ff4, 0xa94457f6, 0xf9401bf7,
                                           0xa9427bfd, 0x910183ff, 0xd65f03c0))
        uc.mem_write(0x10000000 + STATE_OFFSET + 8, bytes([0]))
        uc.mem_write(0x10000000 + STATE_OFFSET + 12, struct.pack('<fdd', 90, 0.0, 0.0))
        def frame(seconds):
            uc.mem_write(0x200010d8, struct.pack('<Q', round(seconds * 19200000)))
            uc.reg_write(UC_ARM64_REG_X0, 0x20000000); uc.reg_write(UC_ARM64_REG_X1, 0x20001000)
            uc.reg_write(UC_ARM64_REG_LR, 0x10001000)
            uc.emu_start(0x102db174, 0x10001000, count=100)
            lead = struct.unpack('<d', bytes(uc.mem_read(0x10000000 + STATE_OFFSET + 24, 8)))[0]
            total = struct.unpack('<d', bytes(uc.mem_read(0x10000000 + STATE_OFFSET + 16, 8)))[0]
            return struct.unpack('<f', bytes(uc.mem_read(0x20000024, 4)))[0], lead, total
        # Jitter around 1/90: the short frame is clamped to 1/90 and repaid by the long one, so game time = host time.
        host = 0
        for seconds in (1 / 120, 1 / 72) * 50:
            fps, lead, total = frame(seconds); host += round(seconds * 19200000) / 19200000
            self.assertLessEqual(fps, 90.0001)
        self.assertAlmostEqual(total, host, places=9)
        self.assertAlmostEqual(lead, 0, places=9)
        # A hitch is not caught up afterwards: the lead stays at zero and the next frame steps normally.
        fps, lead, total = frame(0.5)
        self.assertAlmostEqual(fps, 15, places=4); self.assertEqual(lead, 0)
        fps, lead, total = frame(1 / 90)
        self.assertAlmostEqual(fps, 90, places=3)
        # The lead is capped: frames persistently shorter than the ceiling still advance one ceiling step each.
        for _ in range(100): fps, lead, total = frame(1 / 240)
        self.assertAlmostEqual(fps, 90, places=3); self.assertAlmostEqual(lead, 0.25, places=9)

    def test_movie_hooks_keep_arguments_and_original_returns(self):
        uc = self.machine()
        uc.mem_write(0x10772fd8, struct.pack('<I', 0xd65f03c0))
        uc.mem_write(0x12bb9890, struct.pack('<I', 0xd65f03c0))
        for i in range(8):
            uc.reg_write(globals()[f'UC_ARM64_REG_X{i}'], 0x4200 + i)
        uc.emu_start(0x12b36100, 0x12b36104, count=20)
        self.assertEqual(bytes(uc.mem_read(0x10000000 + STATE_OFFSET + 8, 1)), b'\1')
        self.assertEqual(uc.reg_read(UC_ARM64_REG_LR), 0x12b36104)
        uc.reg_write(UC_ARM64_REG_LR, 0x10001000)
        uc.emu_start(0x12b33918, 0x10001000, count=20)
        self.assertEqual(bytes(uc.mem_read(0x10000000 + STATE_OFFSET + 8, 1)), b'\0')
        for i in range(8):
            self.assertEqual(uc.reg_read(globals()[f'UC_ARM64_REG_X{i}']), 0x4200 + i)
        self.assertEqual(uc.reg_read(UC_ARM64_REG_SP), 0x30008000)

    def test_menu_transition_only_changes_the_matching_initial_state(self):
        uc = self.machine()
        uc.reg_write(UC_ARM64_REG_X24, 0x20000010)
        for types in ((5, 5), (5, 4), (4, 5)):
            for elapsed in (0.0, 0.5):
                uc.mem_write(0x20000008, struct.pack('<HH', *types))
                for r, f in ((0, 0.5), (1, elapsed), (8, 0.0)):
                    uc.reg_write(globals()[f'UC_ARM64_REG_S{r}'], int.from_bytes(struct.pack('<f', f), 'little'))
                uc.reg_write(UC_ARM64_REG_LR, 0x42004200)
                uc.emu_start(0x101fbc80, 0x101fbc88, count=30)
                actual = struct.unpack('<f', struct.pack('<I', uc.reg_read(UC_ARM64_REG_S10)))[0]
                self.assertEqual(actual, 0.5 if types == (5, 5) and elapsed == 0 else elapsed)
                self.assertEqual(uc.reg_read(UC_ARM64_REG_LR), 0x42004200)
                self.assertEqual(uc.reg_read(UC_ARM64_REG_NZCV) & 0xf0000000, 0x20000000)

    def test_rewrite_rejects_wrong_version_or_bytes(self):
        for overrides in ({'BUILD_ID': 'other'}, {'KEY_PAGE_OFF': 0}, {}):
            with self.assertRaises(ValueError):
                apply_timing(self.env | overrides)  # Already patched bytes must also be rejected.

    def test_day_rate_preserves_registers_flags_and_original_default(self):
        uc = self.machine()
        for enabled, rate, original in ((0, 16, 0x7fc12345), (0, 0, 0x80000000),
                                         (1, 0, 0x3c23d70a), (1, .5, 0x3f800000),
                                         (1, 1, 0x3c23d70a), (1, 2, 0x3c23d70a), (1, 16, 0x3f800000)):
            with self.subTest(enabled=enabled, rate=rate, original=original):
                for i in range(31): uc.reg_write(globals()[f'UC_ARM64_REG_X{i}'], 0x1234567800 + i)
                for i in range(32): uc.reg_write(globals()[f'UC_ARM64_REG_Q{i}'], (0xabcdef1234567890 << 64) + i)
                uc.reg_write(UC_ARM64_REG_X19, 0x20000000)
                uc.reg_write(UC_ARM64_REG_NZCV, 0xa0000000)
                uc.mem_write(0x2000003c, struct.pack('<I', original))
                uc.mem_write(0x10000000 + STATE_OFFSET + 44, struct.pack('<fI', rate, enabled))
                uc.emu_start(0x1068c15c, 0x1068c160, count=30)
                expected = original if not enabled else int.from_bytes(struct.pack('<f', struct.unpack('<f', struct.pack('<I', original))[0] * rate), 'little')
                self.assertEqual(uc.reg_read(UC_ARM64_REG_Q9), expected)
                for i in range(32):
                    if i != 9: self.assertEqual(uc.reg_read(globals()[f'UC_ARM64_REG_Q{i}']), (0xabcdef1234567890 << 64) + i)
                for i in range(31):
                    self.assertEqual(uc.reg_read(globals()[f'UC_ARM64_REG_X{i}']), 0x20000000 if i == 19 else 0x1234567800 + i)
                self.assertEqual(uc.reg_read(UC_ARM64_REG_SP), 0x30008000)
                self.assertEqual(uc.reg_read(UC_ARM64_REG_NZCV), 0xa0000000)
                self.assertEqual(uc.reg_read(UC_ARM64_REG_PC), 0x1068c160)

    def test_host_policy_requires_the_marker_outside_readonly_pages(self):
        code = '''#include "game_timing.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>
int main(void) {
    unsigned char *p = calloc(1, 0x3af0000); assert(p);
    unsetenv("ZELDA_TARGET_FPS");
    unsetenv("ZELDA_DAY_RATE");
    assert(!zelda_game_frame_rate() && zelda_game_seconds() == -1);
    assert(!zelda_timing_init(p, 0x3af0000, 0x3ae0000, 0x3af0000));
    memcpy(p + 0x3ae4000, "ZFPS143", 8);
    assert(!zelda_timing_init(p, 0x3ae4000, 0x3ae0000, 0x3af0000));
    assert(!zelda_timing_init(p, 0x3af0000, 0x3ae0000, 0x3ae4000));
    assert(zelda_timing_init(p, 0x3af0000, 0x3ae0000, 0x3af0000));
    assert(zelda_game_frame_rate() == 60);
    __atomic_store_n(p + 0x3ae4008, 1, __ATOMIC_RELAXED);
    assert(zelda_game_frame_rate() == 30);
    __atomic_store_n(p + 0x3ae4008, 0, __ATOMIC_RELAXED);
    assert(zelda_game_frame_rate() == 60);
    const char *values[] = {"30", "60", "90", "120"};
    const unsigned expected[] = {30, 60, 90, 120};
    for (unsigned i = 0; i < 4; i++) {
        setenv("ZELDA_TARGET_FPS", values[i], 1);
        assert(zelda_timing_init(p, 0x3af0000, 0x3ae0000, 0x3af0000));
        assert(zelda_game_frame_rate() == expected[i]);
        float ceiling; memcpy(&ceiling, p + 0x3ae400c, sizeof ceiling);
        assert(ceiling == expected[i]);
        __atomic_store_n(p + 0x3ae4008, 1, __ATOMIC_RELAXED);
        assert(zelda_game_frame_rate() == 30);
        __atomic_store_n(p + 0x3ae4008, 0, __ATOMIC_RELAXED);
        double seconds = 1.25; memcpy(p + 0x3ae4010, &seconds, sizeof seconds);
        assert(zelda_game_seconds() == seconds);
    }
    // Menu changes rewrite the ceiling the patched frame step reads; the movie override stays separate.
    assert(zelda_set_target_fps(90) && zelda_target_fps() == 90 && zelda_game_frame_rate() == 90);
    { float ceiling; memcpy(&ceiling, p + 0x3ae400c, sizeof ceiling); assert(ceiling == 90); }
    __atomic_store_n(p + 0x3ae4008, 1, __ATOMIC_RELAXED);
    assert(zelda_game_frame_rate() == 30 && zelda_target_fps() == 90);
    __atomic_store_n(p + 0x3ae4008, 0, __ATOMIC_RELAXED);
    assert(!zelda_set_target_fps(45) && !zelda_set_target_fps(0) && zelda_target_fps() == 90);
    { float ceiling; memcpy(&ceiling, p + 0x3ae400c, sizeof ceiling); assert(ceiling == 90); }
    assert(zelda_render_scale_factor(0) == 1);
    assert(!zelda_render_scale_factor(-1) && !zelda_render_scale_factor(4));
    { float scale = 1; memcpy(p + 0x3ae4020, &scale, 4); }
    assert(zelda_timing_init(p, 0x3af0000, 0x3ae0000, 0x3af0000));
    for (int mode=0; mode<4; mode++) {
        float scale = zelda_render_scale_factor(mode);
        assert(zelda_set_render_scale(scale) && zelda_render_scale() == scale);
    }
    assert(zelda_set_render_scale(1) && zelda_render_scale() == 1);
    assert(!zelda_set_render_scale(0) && !zelda_set_render_scale(3));
    const char *bad[] = {"", "0", "59", "240", "90junk", "-1"};
    for (unsigned i = 0; i < sizeof bad / sizeof *bad; i++) {
        setenv("ZELDA_TARGET_FPS", bad[i], 1);
        assert(!zelda_timing_init(p, 0x3af0000, 0x3ae0000, 0x3af0000));
        assert(!zelda_game_frame_rate() && zelda_game_seconds() == -1);
        assert(!zelda_target_fps() && !zelda_set_target_fps(60));
    }
    unsetenv("ZELDA_TARGET_FPS");
    setenv("ZELDA_DAY_RATE", "0", 1);
    assert(!zelda_timing_init(p, 0x3af0000, 0x3ae0000, 0x3af0000));
    memcpy(p + 0x3ae4024, "ZDAY143", 8);
    const char *day_values[] = {"0", "0.5", "1", "2", "16"};
    const float day_expected[] = {0, .5f, 1, 2, 16};
    for (unsigned i=0; i<5; i++) {
        setenv("ZELDA_DAY_RATE", day_values[i], 1);
        assert(zelda_timing_init(p, 0x3af0000, 0x3ae0000, 0x3af0000));
        float rate; unsigned enabled;
        memcpy(&rate, p + 0x3ae402c, 4); memcpy(&enabled, p + 0x3ae4030, 4);
        assert(rate == day_expected[i] && enabled == (rate != 1));
        assert(zelda_target_fps() == 60);
    }
    const char *bad_day[] = {"", "nan", "inf", "-1", "17", "2junk"};
    for (unsigned i=0; i<6; i++) {
        setenv("ZELDA_DAY_RATE", bad_day[i], 1);
        assert(!zelda_timing_init(p, 0x3af0000, 0x3ae0000, 0x3af0000));
        assert(!zelda_target_fps());
    }
    unsetenv("ZELDA_DAY_RATE");
    assert(zelda_timing_init(p, 0x3af0000, 0x3ae0000, 0x3af0000));
    { unsigned enabled; memcpy(&enabled,p + 0x3ae4030,4); assert(!enabled); }
    assert(!zelda_timing_init(p, 0x3af0000, 0x3ae0000, 0x3ae4018));
    memcpy(p + 0x3ae4000, "Z60V143", 8);
    assert(!zelda_timing_init(p, 0x3af0000, 0x3ae0000, 0x3af0000));
    free(p);
}
'''
        with tempfile.TemporaryDirectory(dir=ROOT / 'work/tmp') as tmp:
            source, executable = Path(tmp) / 'timing.c', Path(tmp) / 'timing'
            source.write_text(code)
            subprocess.run(['clang', '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined',
                            '-I', str(ROOT / 'host'), str(source), str(ROOT / 'host/game_timing.c'),
                            '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)
