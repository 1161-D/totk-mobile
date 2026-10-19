"""Read selected Zelda shader assets from the merged RomFS, without unpacking the game."""
from compression import zstd
from pathlib import Path, PurePosixPath
import hashlib
import json
import os
import struct


def unpack(data, offset, fmt):
    size = struct.calcsize(fmt)
    if offset < 0 or offset + size > len(data):
        raise ValueError('truncated archive structure')
    return struct.unpack_from(fmt, data, offset)


class RomFS:
    def __init__(self, stream):
        self.stream = stream
        self.size = os.fstat(stream.fileno()).st_size
        self.header = unpack(self.read(0, 80), 0, '<10Q')
        h = self.header
        if h[0] != 80 or not 80 <= h[9] <= self.size:
            raise ValueError('invalid RomFS header')
        self.tables = [(h[i], h[i] + h[i + 1]) for i in (1, 3, 5, 7)]
        for i, (start, end) in enumerate(self.tables):
            if start < 80 or end > self.size or end < start:
                raise ValueError('invalid RomFS table bounds')
            if any(start < b and a < end for a, b in self.tables[:i]):
                raise ValueError('overlapping RomFS tables')

    def read(self, offset, length):
        if offset < 0 or length < 0 or length > 512 << 20 or offset + length > self.size:
            raise ValueError('invalid RomFS read bounds')
        self.stream.seek(offset)
        data = self.stream.read(length)
        if len(data) != length:
            raise ValueError('truncated RomFS read')
        return data

    def entry(self, offset, directory):
        h = self.header
        table, size = (h[3], h[4]) if directory else (h[7], h[8])
        count = 24 if directory else 32
        if offset < 0 or offset % 4 or offset + count > size:
            raise ValueError('invalid RomFS entry offset')
        values = unpack(self.read(table + offset, count), 0, '<6I' if directory else '<IIQQII')
        if values[-1] > 4096 or offset + count + values[-1] > size:
            raise ValueError('invalid RomFS name length')
        name = self.read(table + offset + count, values[-1]).decode('utf-8')
        if '/' in name or '\0' in name or name in ('.', '..'):
            raise ValueError('invalid RomFS name')
        return values, name

    def children(self, parent, directory):
        values, _ = self.entry(parent, True)
        offset = values[2 if directory else 3]
        seen = set()
        while offset != 0xffffffff:
            if offset in seen:
                raise ValueError('cyclic RomFS sibling list')
            seen.add(offset)
            values, name = self.entry(offset, directory)
            if values[0] != parent:
                raise ValueError('invalid RomFS parent')
            yield name, offset, values
            offset = values[1]

    def directory(self, path):
        parent = 0
        for name in PurePosixPath(path).parts:
            if name == '/':
                continue
            matches = [off for n, off, _ in self.children(parent, True) if n == name]
            if len(matches) != 1:
                raise ValueError('RomFS directory missing or ambiguous')
            parent = matches[0]
        return parent

    def file(self, path):
        path = PurePosixPath(path)
        matches = [v for name, _, v in self.children(self.directory(path.parent), False) if name == path.name]
        if len(matches) != 1:
            raise ValueError('RomFS file missing or ambiguous')
        values = matches[0]
        start = self.header[9] + values[2]
        end = start + values[3]
        if any(start < b and a < end for a, b in self.tables):
            raise ValueError('RomFS file overlaps metadata')
        return self.read(start, values[3])


def sarc(data):
    if data[:4] != b'SARC' or data[6:8] != b'\xff\xfe':
        raise ValueError('expected little-endian SARC')
    header, = unpack(data, 4, '<H')
    length, base = unpack(data, 8, '<II')
    if header != 20 or length != len(data) or base > length:
        raise ValueError('invalid SARC bounds')
    magic, size, count, _ = unpack(data, 20, '<4sHHI')
    names = 32 + count * 16
    if magic != b'SFAT' or size != 12 or unpack(data, names, '<4sHH') != (b'SFNT', 8, 0) or names + 8 > base:
        raise ValueError('invalid SARC tables')
    files = {}
    for i in range(count):
        _, attr, start, end = unpack(data, 32 + i * 16, '<4I')
        pos = names + 8 + (attr & 0xffffff) * 4
        nul = data.find(b'\0', pos, base)
        if attr >> 24 != 1 or pos >= base or nul < 0 or start > end or base + end > length:
            raise ValueError('invalid SARC entry')
        name = data[pos:nul].decode('utf-8')
        if not name or name in files or PurePosixPath(name).is_absolute() or '..' in PurePosixPath(name).parts:
            raise ValueError('invalid SARC path')
        files[name] = data[base + start:base + end]
    return files


def decompress(data, dictionaries):
    info = zstd.get_frame_info(data)
    if info.decompressed_size is not None and info.decompressed_size > 512 << 20:
        raise ValueError('shader asset too large')
    if info.dictionary_id and info.dictionary_id not in dictionaries:
        raise ValueError('required Zstandard dictionary missing')
    decoder = zstd.ZstdDecompressor(zstd_dict=dictionaries.get(info.dictionary_id))
    result = decoder.decompress(data, max_length=(512 << 20) + 1)
    if not decoder.eof or decoder.unused_data or len(result) > 512 << 20:
        raise ValueError('incomplete or oversized shader asset')
    return result


def layout_shaders(path, files):
    prefix = 'UI-' + PurePosixPath(path).name.removesuffix('.blarc.zs')
    result = {}
    for name, value in files.items():
        if name.endswith('.bnsh'):
            target = prefix + '-' + PurePosixPath(name).name
            if target in result:
                raise ValueError('ambiguous layout shader name')
            result[target] = value
    return result


def embedded_shaders(data):
    # Effect resources embed whole BNSH binaries; index_shaders validates each header and program table.
    pos = 0
    while (pos := data.find(b'BNSH\0\0\0\0', pos)) >= 0:
        size, = unpack(data, pos + 28, '<I')
        if size < 0x80 or pos + size > len(data):
            raise ValueError('invalid embedded BNSH bounds')
        yield data[pos:pos + size]
        pos += size


def extract(image, target):
    with image.open('rb') as stream:
        rom = RomFS(stream)
        dictionary_pack = decompress(rom.file('/Pack/ZsDic.pack.zs'), {})
        dictionaries = {}
        for value in sarc(dictionary_pack).values():
            dictionary = zstd.ZstdDict(value)
            if not dictionary.dict_id or dictionary.dict_id in dictionaries:
                raise ValueError('invalid or duplicate Zstandard dictionary')
            dictionaries[dictionary.dict_id] = dictionary
        paths = ['/Lib/NintendoSDK/TextureShader.bnsh'] + [
            '/Shader/' + name for name, _, _ in rom.children(rom.directory('/Shader'), False) if name.endswith('.zs')]
        paths += ['/UI/LayoutArchive/' + name for name, _, _ in rom.children(rom.directory('/UI/LayoutArchive'), False)
                  if name.endswith('.blarc.zs')]
        # Engine libraries (post effects, shadows, lighting, terrain) ship their own shader archives.
        for library, offset, _ in rom.children(rom.directory('/Lib'), True):
            paths += [f'/Lib/{library}/{name}' for name, _, _ in rom.children(offset, False) if name.endswith('.release.sarc.zs')]
        effects = ['/Effect/' + name for name, _, _ in rom.children(rom.directory('/Effect'), False) if '.esetb.' in name]
        manifest, written = [], set()
        target.mkdir(parents=True, exist_ok=True)

        def write(name, value, path):
            if '/' in name or '\\' in name or name in written:
                raise ValueError('unexpected nested or duplicate shader asset')
            written.add(name)
            (target / name).write_bytes(value)
            manifest.append({'name': name, 'source': path, 'size': len(value), 'sha256': hashlib.sha256(value).hexdigest()})

        for path in paths:
            original = rom.file(path)
            content = decompress(original, dictionaries) if path.endswith('.zs') else original
            if path.endswith('.blarc.zs'):
                files = layout_shaders(path, sarc(content))
            elif path.startswith('/Lib/') and '.sarc.' in path:
                library = PurePosixPath(path).parent.name
                files = {f'{library}-{name}': value for name, value in sarc(content).items() if name.endswith('.sharcb')}
            else:
                files = sarc(content) if '.sarc.' in path else {PurePosixPath(path).name.removesuffix('.zs'): content}
            for name, value in files.items():
                write(name, value, path)
                print('Shader asset:', name, 'bytes=', len(value))
        # Many effects share binaries; keep each distinct BNSH once, named by its content.
        shared = 0
        for path in effects:
            for value in embedded_shaders(decompress(rom.file(path), dictionaries)):
                name = 'Effect-' + hashlib.sha256(value).hexdigest()[:16] + '.bnsh'
                if name in written:
                    shared += 1
                    continue
                write(name, value, path)
        print('Effect shader binaries:', sum(name.startswith('Effect-') for name in written), 'shared=', shared)
        (target / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')


if __name__ == '__main__':
    extract(Path(os.environ.get('ZELDA_ROMFS', 'work/romfs.bin')), Path('work/shaders/source'))
