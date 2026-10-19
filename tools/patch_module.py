"""Use the ARM64 rewriter in core/tools with Zelda's control-flow adapter."""
import hashlib
import json
import os
from pathlib import Path
import struct
import sys

from exclusive import find_windows, site_window
from game_timing import apply_timing
from render_scale import apply_render_scale

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / 'core'


def site_call(ins, env):
    # AAPCS64 reserves x16/x17 as call scratch. LR must point to the original caller.
    assert ins.mnemonic == 'blr' and ins.op_str == 'x18'
    emit, here = env['emit'], env['here']
    start = here()
    emit(env['MRS_TPIDRRO'](16))
    env['emit_slot_addr'](16, 17, 'K18')
    emit(env['LDRX'](16, 16))
    emit(env['ADRP'](30, here(), ins.address + 4))
    emit(env['ADDI'](30, 30, (ins.address + 4) & 0xfff))
    emit(env['BR'](16))
    return start


def signed_jump_table(addr, img, build_id, text_end, base, width):
    # Facts from the checked v1.4.3 module: ADR base, read-only table, guarded count.
    tables = {0x393bb0: (0x393ba0, 0x2d8626c, 6),
              0x596d30: (0x596d20, 0x2d89154, 9),
              0x598ef4: (0x598ee4, 0x2d89038, 9),
              0x5f2a9c: (0x5f2a90, 0x2d892e0, 5),
              0x6397d8: (0x6397cc, 0x2d88e7c, 7)}
    if build_id != '277178b7dba1b6d4949a84778d4abc58' or addr not in tables:
        return base, width
    anchor, table, count = tables[addr]
    assert base == anchor
    targets = [anchor + n for n in struct.unpack_from(f'<{count}i', img, table)]
    assert all(0 <= t < text_end and t % 4 == 0 for t in targets)
    assert max(targets) - min(targets) < 0x10000
    return min(targets), (max(targets) - min(targets)) // 4 + 1


def adapted_source():
    source = (CORE / 'tools/patch_nso.py').read_text()
    # All substitutions fail closed if the sibling dependency changes.
    replacements = [
        ("if m == 'br': st = site_br(ins, *jumps[a]); stat('br')",
         "if m == 'blr': st = zelda_site_call(ins, globals()); stat('blr')\n        elif m == 'br': st = site_br(ins, *jumps[a]); stat('br')"),
        ('ctx = insl[max(0, j - 8):j]', 'ctx = insl[max(0, j - 32):j]'),
        ("assert base and width, f'jump table {ins.address:x}'",
         "base, width = zelda_signed_table(ins.address, IMG, BUILD_ID, TEXT_END, base, width)\n            assert base is not None and width, f'jump table {ins.address:x}'"),
        ('ws = find_windows(insl)', 'ws = zelda_find_windows(insl, has18)'),
        ("assert not (t in inwin and t not in heads), f'branch into window {x.address:x}'",
         "assert x.address in inwin or t not in inwin or any(y.address == t and y.mnemonic in EXCL_LD for w in ws for y in w), f'branch into window {x.address:x}'"),
        ("st, lo, hi = site_window(wseg); stat('window'); put_branch(lo, st)",
         "entries = zelda_site_window(wseg, globals()); stat('window')\n    for lo, st in entries.items(): put_branch(lo, st)"),
        ("for wseg in windows: f.write(f'{wseg[0].address:#x}\\tW\\t{wseg[-1].address + 4:#x}\\n')",
         "for wseg in windows:\n        for ins in wseg: f.write(f'{ins.address:#x}\\tA\\n')"),
    ]
    for before, after in replacements:
        if source.count(before) != 1:
            raise ValueError('core rewriter changed; review the adapter before continuing')
        source = source.replace(before, after)
    return source


if __name__ == '__main__':
    if sys.flags.optimize:
        sys.exit('Python optimizations disable required rewrite assertions; remove -O/PYTHONOPTIMIZE')
    if len(sys.argv) != 4:
        sys.exit('usage: patch_module.py NSO OUTPUT MODULE')
    os.environ['DM_RULESET'] = 'native'
    env = {'__file__': str(CORE / 'tools/patch_nso.py'), '__name__': '__main__',
           'zelda_find_windows': find_windows, 'zelda_site_window': site_window,
           'zelda_signed_table': signed_jump_table, 'zelda_site_call': site_call}
    source = adapted_source()
    exec(compile(source, env['__file__'], 'exec'), env)
    # Reject rewriter changes meant for other games; Zelda timing has its own exact-byte manifest below.
    for suffix in ('cuts', 'obs', 'params'):
        lines = (Path(sys.argv[2]) / f'{sys.argv[3]}.{suffix}.tsv').read_text().splitlines()
        if any(line and not line.startswith('#') for line in lines):
            sys.exit(f'refusing game-specific patches: {suffix}')
    if sys.argv[3] == 'main':
        timing = apply_timing(env)
        timing['render_scale'] = apply_render_scale(env)
        output = Path(sys.argv[2])
        (output / 'main.patched.bin').write_bytes(env['IMG'] + env['patch'])
        (output / 'main.timing.json').write_text(json.dumps(timing, indent=2) + '\n')
    (Path(sys.argv[2]) / 'adapter.sha256').write_text(
        hashlib.sha256(source.encode()).hexdigest() + '\n')
