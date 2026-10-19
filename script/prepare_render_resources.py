"""Prepare a copy-on-write RomFS view with room for the supported 1080p menu targets."""
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile

from extract_shaders import RomFS, decompress, sarc, zstd

ASSET = '/System/HeapSize/Product.Nin_NX_NVN.HeapDef.byml.zs'
SOURCE_SHA = 'b84a6a647cb60ecc3df012819f917a9db460a0ca8a0e9eec5ffe6fdee7b0edd1'
# Byte offsets are bound to the complete compressed asset hash, not to guessed BYML field positions.
CHANGES = ((2732, 113664, 163840, 'Heaps/DynamicTextureAllocatorMem/Size'),
           (2920, 201728, 251904, 'Heaps/Graphics/Size'))


def patch_config(packed, dictionaries):
    if hashlib.sha256(packed).hexdigest() != SOURCE_SHA:
        raise ValueError('unsupported render heap asset; expected the verified v1.4.3 configuration')
    data = bytearray(decompress(packed, dictionaries))
    for offset, before, after, _ in CHANGES:
        if offset + 4 > len(data) or struct.unpack_from('<I', data, offset)[0] != before:
            raise ValueError('render heap field changed')
        struct.pack_into('<I', data, offset, after)
    # No dictionary is needed for this small derived resource; the game selects it from the frame header.
    return zstd.compress(data, level=19)


def prepare(root=Path('work')):
    source, output, record = root / 'romfs.bin', root / 'romfs-host.bin', root / 'render-resources.json'
    stat = source.stat()
    inputs = dict(size=stat.st_size, mtime_ns=stat.st_mtime_ns, asset_sha256=SOURCE_SHA, changes=CHANGES)
    inputs = json.loads(json.dumps(inputs))
    if output.exists() and not record.exists():
        raise ValueError('unrecognized romfs-host.bin; refusing to overwrite it')
    if record.exists() and output.exists():
        previous = json.loads(record.read_text())
        current = output.stat()
        if previous['inputs'] == inputs and previous['output'] == dict(size=current.st_size, mtime_ns=current.st_mtime_ns):
            print('Render resource view already verified:', output)
            return
    with source.open('rb') as stream:
        rom = RomFS(stream)
        dictionaries = {}
        for value in sarc(decompress(rom.file('/Pack/ZsDic.pack.zs'), {})).values():
            dictionary = zstd.ZstdDict(value)
            dictionaries[dictionary.dict_id] = dictionary
        packed = patch_config(rom.file(ASSET), dictionaries)
        parent = rom.directory(str(Path(ASSET).parent))
        matches = [offset for name, offset, _ in rom.children(parent, False) if name == Path(ASSET).name]
        if len(matches) != 1:
            raise ValueError('render heap file entry missing or ambiguous')
        entry, base = rom.header[7] + matches[0], rom.header[9]
    (root / 'tmp').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='render-resources-', dir=root / 'tmp') as temp:
        staged = Path(temp) / 'romfs.bin'
        # APFS clone shares unchanged extents; never fall back to a full 17 GB copy or a hard link.
        subprocess.run(['cp', '-c', str(source), str(staged)], check=True)
        if staged.stat().st_ino == stat.st_ino:
            raise ValueError('render view must not alias the source inode')
        with staged.open('r+b') as stream:
            stream.seek(0, 2)
            position = (stream.tell() + 15) & ~15
            stream.seek(position); stream.write(packed)
            stream.seek(entry + 8); stream.write(struct.pack('<QQ', position - base, len(packed)))
        with staged.open('rb') as stream:
            if RomFS(stream).file(ASSET) != packed:
                raise ValueError('derived render heap resource did not round-trip')
        staged.replace(output)
    current = output.stat()
    record.write_text(json.dumps(dict(inputs=inputs, output=dict(size=current.st_size, mtime_ns=current.st_mtime_ns),
                                     asset=ASSET, file_entry=entry, data_offset=position,
                                     patched_asset_sha256=hashlib.sha256(packed).hexdigest()), indent=2) + '\n')
    print('Prepared render resource view:', output, '(dynamic textures 111 -> 160 MiB; Graphics +49 MiB)')


if __name__ == '__main__':
    prepare()
