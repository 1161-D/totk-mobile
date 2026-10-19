import ast
from itertools import combinations
from pathlib import Path
import re
import struct
import sys
import unittest

from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM
from unicorn.arm64_const import *

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from exclusive import find_windows, site_window
from patch_module import CORE

# Synthetic assembly: increment with LL/SC; alternate load branches to the shared
# store, or clears its reservation. No game bytes are used as test fixtures.
WORDS = [0x885f7d52, 0x11000652, 0x88117d52, 0x35ffffb1, 0xd65f03c0,
         0x885f7d51, 0x6b0f023f, 0x54ffff60, 0xd5033f5f, 0xd65f03c0]
CODE = struct.pack('<10I', *WORDS)


def encoders():
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    md.detail = True
    source = ast.parse((CORE / 'tools/patch_nso.py').read_text())
    functions = [n for n in source.body if isinstance(n, ast.FunctionDef)]
    env = dict(struct=struct, re=re, combinations=combinations, md=md,
               PATCH_OFF=0x4000, KEY_PAGE_OFF=0x2000, KEY_INDEX={'K18': 0},
               patch=bytearray(), fix=[], stats={})
    exec(compile(ast.Module(body=functions, type_ignores=[]), '<upstream encoders>', 'exec'), env)
    return env


class ExclusiveTests(unittest.TestCase):
    def test_shared_store_preserves_machine_state(self):
        env = encoders()
        ins = list(env['md'].disasm(CODE, 0))
        regions = find_windows(ins, env['has18'])
        self.assertEqual(len(regions), 1)
        self.assertEqual([x.address for x in regions[0]], [0, 4, 8, 20, 24, 28])
        entries = site_window(regions[0], env)
        rewritten = bytearray(CODE)
        for addr, dest in entries.items():
            struct.pack_into('<I', rewritten, addr, env['B'](addr, dest))
        rewritten += bytes(0x4000 - len(rewritten)) + env['patch']
        registers = [globals()[f'UC_ARM64_REG_X{i}'] for i in range(31)]

        def execute(code, entry, initial, expected, patched):
            uc = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
            for base, size in ((0x100000, 0x10000), (0x200000, 0x1000),
                               (0x300000, 0x1000), (0x400000, 0x1000)):
                uc.mem_map(base, size)
            uc.mem_write(0x100000, bytes(code))
            uc.mem_write(0x200000, struct.pack('<I', initial))
            uc.mem_write(0x102000, struct.pack('<Q', 8))
            uc.mem_write(0x300008, struct.pack('<Q', 123))
            uc.reg_write(UC_ARM64_REG_TPIDRRO_EL0, 0x300000)
            for i, reg in enumerate(registers):
                uc.reg_write(reg, i + 100)
            uc.reg_write(UC_ARM64_REG_X10, 0x200000)
            uc.reg_write(UC_ARM64_REG_X15, expected)
            uc.reg_write(UC_ARM64_REG_X18, 0xabc if patched else 123)
            uc.reg_write(UC_ARM64_REG_LR, 0x100100)
            uc.reg_write(UC_ARM64_REG_SP, 0x400800)
            uc.reg_write(UC_ARM64_REG_NZCV, 0xa0000000)
            uc.emu_start(0x100000 + entry, 0x100100, count=1000)
            self.assertEqual(uc.reg_read(UC_ARM64_REG_PC), 0x100100)
            values = [uc.reg_read(r) for r in registers]
            if patched:
                self.assertEqual(values[18], 0xabc)
                values[18] = int.from_bytes(uc.mem_read(0x300008, 8), 'little')
            return values, uc.reg_read(UC_ARM64_REG_SP), uc.reg_read(UC_ARM64_REG_NZCV), bytes(uc.mem_read(0x200000, 4))

        for entry in (0, 20):
            for initial in (0, 1, 0x7fffffff, 0xffffffff):
                for expected in (initial, initial ^ 1):
                    with self.subTest(entry=entry, initial=initial, expected=expected):
                        self.assertEqual(execute(CODE, entry, initial, expected, False),
                                         execute(rewritten, entry, initial, expected, True))

    def test_entry_without_reservation_is_rejected(self):
        env = encoders()
        invalid = CODE + struct.pack('<I', env['B'](40, 8))
        with self.assertRaisesRegex(AssertionError, 'entry without exclusive load'):
            find_windows(list(env['md'].disasm(invalid, 0)), env['has18'])

    def test_plain_atomic_needs_no_rewrite(self):
        env = encoders()
        code = struct.pack('<III', 0x885f7d51, 0x88007d51, 0xd65f03c0)
        self.assertEqual(find_windows(list(env['md'].disasm(code, 0)), env['has18']), [])


if __name__ == '__main__':
    unittest.main()
