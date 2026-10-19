"""Request linked vertex/fragment variants for every program declared in the extracted archives.

The runtime links each vertex shader with the fragment shader it is drawn with (see nvn_shader_variant.inc) and used
to translate a pair the first time it was drawn, stalling the game for seconds. BNSH programs already name their
pairs, as do BAHS program variation tables, so the same requests can be written before the game runs. Requests use
the runtime's file format and identity.

Integer vertex attributes and integer colour targets select further variants by a 2-bit-per-slot mask. Masks seen in
play (plus locally captured ones) are requested for every shader of the same archive that reads those vertex
locations or writes those colour outputs. A wrong guess only costs a translation; the draw still picks its variant
from the actual formats, and a missing one is still compiled at run time.
"""
import collections
import hashlib
import json
from pathlib import Path
import re

from build_shaders import chain
from index_shaders import archive, read, span, stage

ROOT = Path(__file__).resolve().parents[1]
# v1.4.3 play on the underground autosave: material skinning reads location 6 as uint, and the matching G-buffer
# pass binds an unsigned colour target 6; cave meshes use unsigned locations/targets 0 and 1.
SEEN_MASKS = {
    ('vs', 'material.Product.140.product.Nin_NX_NVN.bfsha'): {4096, 20480},
    ('ps', 'material.Product.140.product.Nin_NX_NVN.bfsha'): {4096, 20480},
    ('vs', 'cave.Product.140.product.Nin_NX_NVN.bfsha'): {5},
    ('ps', 'cave.Product.140.product.Nin_NX_NVN.bfsha'): {5},
}


def bnsh_programs(data):
    count, table = read(data, 0x7c, '<IQ')
    span(data, table, count * 64)
    for i in range(count):
        program, = read(data, table + i * 64 + 16, '<Q')
        stages = {}
        for header in read(data, program + 8, '<6Q'):
            if header:
                control, code, code_size, control_size = read(data, header + 8, '<QQII')
                entry, _ = stage(span(data, control, control_size), span(data, code, code_size))
                stages[entry['stage']] = entry['key']
        yield stages


def bahs_programs(data):
    binaries = [entry for entry, _ in archive(data)]
    binary_section = 0x150 + read(data, 0x14, '<I')[0]
    offset = binary_section + read(data, binary_section, '<I')[0]
    size, count = read(data, offset, '<II')
    if size < 8 or offset + size > read(data, 0x1c, '<I')[0]:
        raise ValueError('invalid BAHS program section')
    table = span(data, offset, size)
    pos = 8
    for _ in range(count):
        size, name_size, mask, first = read(table, pos, '<4I')
        program = span(table, pos, size)
        if size < 16 or not name_size or not 0 < mask < 16:
            raise ValueError('invalid BAHS program header')
        label = span(program, 16, name_size)
        if not label.endswith(b'\0') or label.count(b'\0') != 1:
            raise ValueError('invalid BAHS program name')
        # BAHS v9 groups each variation's stages consecutively; its compute bit is 3, unlike NVN control kind 5.
        order = [kind for bit, kind in enumerate(('vs', 'ps', 'gs', 'cs')) if mask >> bit & 1]
        offset = 16 + name_size
        macro_size, macro_count = read(program, offset, '<II')
        macros = span(program, offset, macro_size)
        macro_pos, variations = 8, 1
        if macro_size < 8 or first + len(order) > len(binaries):
            raise ValueError('invalid BAHS program binary range')
        for _ in range(macro_count):
            size, name_length, values, symbol_length = read(macros, macro_pos, '<4I')
            macro = span(macros, macro_pos, size)
            if size < 16 or not name_length or not values or not symbol_length or 16 + name_length + symbol_length > size:
                raise ValueError('invalid BAHS variation macro')
            label = macro[16:16 + name_length]
            choices = macro[16 + name_length:size - symbol_length]
            symbol = macro[size - symbol_length:]
            if (not label.endswith(b'\0') or label.count(b'\0') != 1 or
                    not choices.endswith(b'\0') or choices.count(b'\0') != values or
                    not symbol.endswith(b'\0') or symbol.count(b'\0') != 1):
                raise ValueError('invalid BAHS variation strings')
            variations *= values
            if first + variations * len(order) > len(binaries):
                raise ValueError('BAHS variations exceed binary range')
            macro_pos += size
        if macro_pos != macro_size:
            raise ValueError('BAHS variation macro count mismatch')
        offset += macro_size
        for _ in range(2):
            tail_size, = read(program, offset, '<I')
            if tail_size < 8:
                raise ValueError('invalid BAHS program metadata section')
            span(program, offset, tail_size)
            offset += tail_size
        if offset != len(program):
            raise ValueError('BAHS program size mismatch')
        for variation in range(variations):
            group = binaries[first + variation * len(order):first + (variation + 1) * len(order)]
            if [entry['stage'] for entry in group] != order:
                raise ValueError('BAHS program stage mismatch')
            yield {entry['stage']: entry['key'] for entry in group}
        pos += len(program)
    if pos != len(table):
        raise ValueError('BAHS program count mismatch')


def programs(data):
    if data[:4] == b'BNSH':
        yield from bnsh_programs(data)
    elif data[:4] == b'FSHA':
        table, = read(data, 0x48, '<Q')
        count, = read(data, 0x78, '<H')
        for i in range(count):
            offset, = read(data, table + i * 256 + 0xa8, '<Q')
            size, = read(data, offset + 28, '<I')
            yield from bnsh_programs(span(data, offset, size))
    elif data[:4] == b'BAHS':
        yield from bahs_programs(data)
    else:
        raise ValueError('unsupported shader program archive')


def name(vertex, mask, fragment):
    return hashlib.sha256(f'{vertex}-{mask:08x}-{fragment}'.encode()).hexdigest()[:16]


def request(directory=ROOT / 'work/shaders'):
    stages = {entry['key']: entry['stage'] for entry in json.loads((directory / 'index.json').read_text())}
    pairs = set()
    for path in sorted((directory / 'source').iterdir()):
        if path.suffix in ('.bnsh', '.bfsha', '.sharcb'):
            for program in programs(path.read_bytes()):
                vertex, fragment = program.get('vs'), program.get('ps')
                if vertex and fragment and stages.get(vertex) == 'vs' and stages.get(fragment) == 'ps':
                    pairs.add((vertex, fragment))
    variants = directory / 'variants'
    variants.mkdir(exist_ok=True)
    sources = {entry['key']: entry['source'] for entry in json.loads((directory / 'index.json').read_text())}
    masks = collections.defaultdict(set, {key: set(value) for key, value in SEEN_MASKS.items()})
    for path in variants.glob('*.json'):
        observed = json.loads(path.read_text())
        if observed['mask'] and stages.get(observed['base']) in ('vs', 'ps'):
            masks[(stages[observed['base']], sources[observed['base']])].add(observed['mask'])
    library = directory / ('b-' + chain())
    slots = {}

    def used(key):
        # Vertex input locations or fragment colour outputs of the built base library; unknown until it is built.
        if key not in slots:
            try:
                if stages[key] == 'vs':
                    slots[key] = {item['location'] for item in json.loads((library / (key + '_b.json')).read_text())['vertex_inputs']}
                else:
                    slots[key] = {int(n) for n in re.findall(r'\[\[color\((\d+)\)\]\]', (library / (key + '_b.metallib')).read_text())}
            except (OSError, ValueError, KeyError):
                slots[key] = set()
        return slots[key]

    def fits(key, mask, count):
        return {i for i in range(count) if (mask >> (2 * i)) & 3} <= used(key)

    wanted = set()
    for vertex, fragment in pairs:
        wanted.add(name(vertex, 0, fragment) + '|' + json.dumps({'base': vertex, 'mask': 0, 'next': fragment}, separators=(',', ':')))
        for mask in masks[('vs', sources[vertex])]:
            if fits(vertex, mask, 16):
                wanted.add(name(vertex, mask, fragment) + '|' + json.dumps({'base': vertex, 'mask': mask, 'next': fragment}, separators=(',', ':')))
        for mask in masks[('ps', sources[fragment])]:
            if fits(fragment, mask, 8):
                wanted.add(f'{fragment}-{mask:04x}|' + json.dumps({'base': fragment, 'mask': mask}, separators=(',', ':')))
    written = 0
    for item in sorted(wanted):
        key, text = item.split('|', 1)
        path = variants / (key + '.json')
        if path.exists():
            continue
        # Same content as zelda_capture_program / zelda_shader_variant write at run time.
        temporary = path.with_suffix('.tmp')
        temporary.write_text(text + '\n')
        temporary.replace(path)
        written += 1
    print('Program pairs:', len(pairs), 'new requests:', written)
    return written


if __name__ == '__main__':
    request()
