import struct
import unittest

from test_exclusive import encoders
from patch_module import signed_jump_table, site_call
from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM
from unicorn.arm64_const import *


class CallTests(unittest.TestCase):
    def test_indirect_call_keeps_arguments_and_original_return_address(self):
        env = encoders()
        ins = env['dis'](0xd63f0240, 0)  # blr x18
        start = site_call(ins, env)
        code = bytearray(0x4000) + env['patch']
        struct.pack_into('<I', code, 0, env['B'](0, start))
        struct.pack_into('<II', code, 0x400, 0x91000400, 0xd65f03c0)  # add x0,x0,1; ret
        struct.pack_into('<Q', code, 0x2000, 8)
        uc = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
        uc.mem_map(0x100000, 0x10000)
        uc.mem_map(0x300000, 0x1000)
        uc.mem_write(0x100000, bytes(code))
        uc.mem_write(0x300008, struct.pack('<Q', 0x100400))
        uc.reg_write(UC_ARM64_REG_TPIDRRO_EL0, 0x300000)
        uc.reg_write(UC_ARM64_REG_X18, 0xabcdef)
        registers = [globals()[f'UC_ARM64_REG_X{i}'] for i in range(31)]
        for i in list(range(8)) + list(range(19, 30)):
            uc.reg_write(registers[i], i + 42)
        uc.reg_write(UC_ARM64_REG_NZCV, 0xa0000000)
        uc.emu_start(0x100000, 0x100004, count=1000)
        self.assertEqual(uc.reg_read(UC_ARM64_REG_PC), 0x100004)
        self.assertEqual(uc.reg_read(UC_ARM64_REG_LR), 0x100004)
        self.assertEqual(uc.reg_read(UC_ARM64_REG_X0), 43)
        self.assertEqual(uc.reg_read(UC_ARM64_REG_X18), 0xabcdef)
        self.assertEqual(uc.reg_read(UC_ARM64_REG_NZCV), 0xa0000000)
        for i in list(range(1, 8)) + list(range(19, 30)):
            self.assertEqual(uc.reg_read(registers[i]), i + 42)

    def test_signed_table_bounds_and_build_id(self):
        img = bytearray(0x2d8626c + 24)
        struct.pack_into('<6i', img, 0x2d8626c, -16, 4, 8, 0, 4, -8)
        args = (0x393bb0, img, '277178b7dba1b6d4949a84778d4abc58', 0x400000, 0x393ba0, None)
        self.assertEqual(signed_jump_table(*args), (0x393b90, 7))
        self.assertEqual(signed_jump_table(args[0], img, 'unknown', *args[3:]), (0x393ba0, None))
        struct.pack_into('<i', img, 0x2d8626c, -0x400000)
        with self.assertRaises(AssertionError):
            signed_jump_table(*args)


if __name__ == '__main__':
    unittest.main()
