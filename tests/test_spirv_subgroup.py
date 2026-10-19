import os
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'script'))
import spirv_subgroup  # noqa: E402


def op(code, *operands):
    return [(len(operands) + 1) << 16 | code, *operands]


def text(value):
    data = value.encode() + b'\0'
    data += b'\0' * (-len(data) % 4)
    return list(struct.unpack('<%dI' % (len(data) // 4), data))


def module(group=339):
    # Vertex shader: out = ballot(true).x + subgroup invocation id, the shape of AglShader 159dd8d89a8d1afd.
    VOID, FN, UINT, V4, BOOL, TRUE, PIN, POUT, SCOPE, LANE, OUT, MAIN, LABEL, BALLOT, X, ID, SUM = range(1, 18)
    body = (op(17, 1) + op(17, 61) + op(17, 64) + op(14, 0, 1) + op(15, 0, MAIN, *text('main'), LANE, OUT) +
            op(71, LANE, 11, 41) + op(71, OUT, 30, 0) + op(5, LANE, *text('lane')) +
            op(19, VOID) + op(33, FN, VOID) + op(21, UINT, 32, 0) + op(23, V4, UINT, 4) + op(20, BOOL) + op(41, BOOL, TRUE) +
            op(32, PIN, 1, UINT) + op(32, POUT, 3, UINT) + op(43, UINT, SCOPE, 3) + op(59, PIN, LANE, 1) + op(59, POUT, OUT, 3) +
            op(54, VOID, MAIN, 0, FN) + op(248, LABEL) +
            (op(group, V4, BALLOT, SCOPE, TRUE) if group == 339 else op(group, UINT, BALLOT, SCOPE, SCOPE, SCOPE)) +
            op(81, UINT, X, BALLOT if group == 339 else SCOPE, 0) + op(61, UINT, ID, LANE) + op(128, UINT, SUM, X, ID) +
            op(62, OUT, SUM) + op(253) + op(56))
    words = [0x07230203, 0x00010300, 0, 18, 0] + body
    return struct.pack('<%dI' % len(words), *words)


class SubgroupLoweringTests(unittest.TestCase):
    def test_ballot_and_lane_id_become_a_single_invocation_subgroup(self):
        lowered = spirv_subgroup.lower(module())
        listing = list(spirv_subgroup.instructions(struct.unpack('<%dI' % (len(lowered) // 4), lowered)))
        codes = [code for _, code, _ in listing]
        self.assertNotIn(339, codes)
        self.assertIn(169, codes)  # OpSelect(predicate, (1,0,0,0), 0)
        self.assertFalse(any(code == 17 and ops[0] in (61, 64) for _, code, ops in listing))
        self.assertFalse(any(code == 71 and ops[1:3] == [11, 41] for _, code, ops in listing))
        entry = next(ops for _, code, ops in listing if code == 15)
        self.assertNotIn(10, entry[2 + spirv_subgroup.string_words(entry[2:]):])
        copy = next(ops for _, code, ops in listing if code == 83)  # invocation id load -> constant 0
        self.assertIn([3, copy[2], 0], [ops for _, code, ops in listing if code == 43])
        tool = ROOT / 'work/tools/spirv-cross'
        if tool.exists():
            with tempfile.NamedTemporaryFile(suffix='.spv', dir=ROOT / 'work/tmp') as file:
                file.write(lowered); file.flush()
                result = subprocess.run([str(tool), file.name, '--msl', '--msl-version', '20300'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('uint4(1u, 0u, 0u, 0u)', result.stdout)
            self.assertNotIn('simd_ballot', result.stdout); self.assertNotIn('thread_index_in_simdgroup', result.stdout)

    def test_cross_lane_operations_stay_blocked(self):
        self.assertIsNone(spirv_subgroup.lower(module(group=345)))  # OpGroupNonUniformShuffle

    def test_modules_without_subgroups_are_untouched(self):
        empty = struct.pack('<5I', 0x07230203, 0x00010300, 0, 1, 0)
        self.assertIsNone(spirv_subgroup.lower(empty))


if __name__ == '__main__':
    unittest.main()
