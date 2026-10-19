"""Inventory game fonts and layout references without unpacking the whole RomFS."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import struct

from extract_shaders import RomFS, decompress, sarc, zstd


def message_characters(data):
    if len(data) < 32 or data[:10] != b'MsgStdBn\xff\xfe' or data[12] != 1:
        raise ValueError('unsupported message header')
    count, = struct.unpack_from('<H', data, 14)
    size, = struct.unpack_from('<I', data, 18)
    if size != len(data):
        raise ValueError('invalid message size')
    result, offset = set(), 32
    for _ in range(count):
        if offset + 16 > size:
            raise ValueError('truncated message section')
        length, = struct.unpack_from('<I', data, offset + 4)
        start, end = offset + 16, offset + 16 + length
        if end > size:
            raise ValueError('invalid message section size')
        if data[offset:offset + 4] == b'TXT2':
            if length < 4:
                raise ValueError('truncated message text table')
            strings, = struct.unpack_from('<I', data, start)
            if 4 + 4 * strings > length:
                raise ValueError('invalid message text count')
            for i in range(strings):
                position = start + struct.unpack_from('<I', data, start + 4 + i * 4)[0]
                if not start + 4 + 4 * strings <= position < end or (position - start) & 1:
                    raise ValueError('invalid message text offset')
                literal = bytearray()
                while position + 2 <= end:
                    code, = struct.unpack_from('<H', data, position)
                    position += 2
                    if not code:
                        break
                    if code in (14, 15):
                        # Control parameters are binary, not literal UTF-16 (including ruby annotations).
                        header = 6 if code == 14 else 4
                        if position + header > end:
                            raise ValueError('truncated message control')
                        extra = struct.unpack_from('<H', data, position + 4)[0] if code == 14 else 0
                        position += header + extra
                        if position > end or position & 1:
                            raise ValueError('invalid message control length')
                    else:
                        literal.extend(struct.pack('<H', code))
                else:
                    raise ValueError('unterminated message text')
                result.update(map(ord, literal.decode('utf-16-le')))
        offset = (end + 15) & ~15
    return result


def layout_fonts(data):
    if len(data) < 20 or data[:6] != b'FLYT\xff\xfe':
        raise ValueError('invalid layout header')
    offset, = struct.unpack_from('<H', data, 6)
    size, = struct.unpack_from('<I', data, 12)
    blocks, = struct.unpack_from('<H', data, 16)
    if size != len(data) or not 20 <= offset <= size:
        raise ValueError('invalid layout size')
    names = []
    for _ in range(blocks):
        if offset + 8 > size:
            raise ValueError('truncated layout block')
        length, = struct.unpack_from('<I', data, offset + 4)
        end = offset + length
        if length < 8 or end > size:
            raise ValueError('invalid layout block size')
        if data[offset:offset + 4] == b'fnl1':
            if length < 12:
                raise ValueError('truncated font list')
            count, = struct.unpack_from('<H', data, offset + 8)
            table = offset + 12
            if table + 4 * count > end:
                raise ValueError('invalid font list count')
            for i in range(count):
                start = table + struct.unpack_from('<I', data, table + 4 * i)[0]
                nul = data.find(b'\0', start, end)
                if start < table + 4 * count or nul < 0:
                    raise ValueError('invalid font name offset')
                names.append(data[start:nul].decode('utf-8'))
        offset = end
    return names


def inventory(image, output):
    output.mkdir(parents=True, exist_ok=True)
    assets = output / 'assets'
    assets.mkdir(exist_ok=True)
    fonts, archives, layouts, messages = {}, [], [], []
    with image.open('rb') as stream:
        rom = RomFS(stream)
        paths, seen, todo = [], set(), [('', 0)]
        while todo:
            base, parent = todo.pop()
            if parent in seen:
                raise ValueError('cyclic or shared RomFS directory')
            seen.add(parent)
            todo.extend((base + '/' + n, o) for n, o, _ in rom.children(parent, True))
            paths.extend(base + '/' + n for n, _, _ in rom.children(parent, False))
        dictionaries = {}
        for value in sarc(decompress(rom.file('/Pack/ZsDic.pack.zs'), {})).values():
            dictionary = zstd.ZstdDict(value)
            dictionaries[dictionary.dict_id] = dictionary
        for path in sorted(p for p in paths if p.startswith('/Font/') and p.endswith('.bfarc.zs')):
            composites = []
            for name, data in sarc(decompress(rom.file(path), dictionaries)).items():
                if name.endswith(('.bfotf', '.bfttf')):
                    digest = hashlib.sha256(data).hexdigest()
                    destination = assets / (digest + '.bfont')
                    if destination.exists() and destination.read_bytes() != data:
                        raise ValueError('existing font asset does not match its hash')
                    if not destination.exists():
                        destination.write_bytes(data)
                    entry = fonts.setdefault(digest, dict(name=name, file=str(destination), bytes=len(data), archives=[]))
                    entry['archives'].append(path)
                elif name.endswith('.bfcpx'):
                    references = [s.decode() for s in re.findall(rb'[A-Za-z0-9_.-]+\.bf(?:otf|ttf)', data)]
                    composites.append(dict(name=name, fonts=references))
            archives.append(dict(archive=path, composites=composites))
        for path in sorted(p for p in paths if p.startswith('/UI/') and p.endswith('.blarc.zs')):
            for name, data in sarc(decompress(rom.file(path), dictionaries)).items():
                if name.endswith('.bflyt'):
                    layouts.append(dict(archive=path, layout=name, fonts=layout_fonts(data)))
        for path in sorted(p for p in paths if p.startswith('/Mals/') and p.endswith('.sarc.zs')):
            characters, count = set(), 0
            for name, data in sarc(decompress(rom.file(path), dictionaries)).items():
                if name.endswith('.msbt'):
                    characters.update(message_characters(data))
                    count += 1
            messages.append(dict(archive=path, files=count, literal_codepoints=sorted(characters)))
    available = {PurePosixPath(f['name']).name for f in fonts.values()}
    referenced = {f for a in archives for c in a['composites'] for f in c['fonts']}
    manifest = dict(files_scanned=len(paths), fonts=list(fonts.values()), font_archives=archives,
                    layouts=layouts, messages=messages, message_scope='Literal text only; control parameters and runtime-inserted symbols excluded',
                    fonts_outside_game_archives=sorted(referenced - available),
                    shared_substitute='/System/Library/Fonts/Supplemental/AppleGothic.ttf')
    (output / 'inventory.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    lines = []
    for font in fonts.values():
        if any(c in font['file'] + font['name'] for c in '\t\n\r'):
            raise ValueError('font manifest field contains a delimiter')
        lines.append('bfont\t' + font['file'] + '\t' + font['name'])
    lines.append('plain\t' + manifest['shared_substitute'] + '\tshared-system-substitute')
    (output / 'font-files.tsv').write_text('\n'.join(lines) + '\n')
    text_lines = []
    for line, font in zip(lines, list(fonts.values()) + [None]):
        if font and any(tag in font['name'] for tag in ('Symbol', 'External', 'Nin-Zelda')):
            text_lines.append(line) # Programmatically inserted icons retain the full font repertoire test.
            continue
        characters = set()
        for message in messages:
            locale = PurePosixPath(message['archive']).name.split('.')[0]
            archive = f'/Font/Font_{locale}.Nin_NX_NVN.bfarc.zs' if locale in ('CNzh', 'KRko', 'TWzh') else '/Font/Font.Nin_NX_NVN.bfarc.zs'
            if font is None or archive in font['archives']:
                characters.update(message['literal_codepoints'])
        if not characters:
            raise ValueError('font has no matching message corpus')
        encoded = ''.join(f'{c:X}\n' for c in sorted(characters))
        path = assets / (hashlib.sha256(encoded.encode()).hexdigest() + '.codes')
        path.write_text(encoded)
        text_lines.append(line + '\t' + str(path))
    (output / 'font-game-text.tsv').write_text('\n'.join(text_lines) + '\n')
    print(f'{len(paths)} RomFS files, {len(archives)} font archives, {len(fonts)} distinct fonts, {len(layouts)} layouts')
    print('External/shared references:', ', '.join(manifest['fonts_outside_game_archives']))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--romfs', type=Path, default=Path('work/romfs.bin'))
    parser.add_argument('--output', type=Path, default=Path('work/font-audit'))
    args = parser.parse_args()
    inventory(args.romfs, args.output)
