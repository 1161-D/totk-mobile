"""Bounded offline-library pilot; never replaces the game's shader directory or cache."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
CUBES = ('48e3901f9b4eb169_b', 'c3960b272d349125_b')
STAGES = {'0': 'vertex', '1': 'pixel', '5': 'compute'}


def samples(directory, records):
    groups = {stage: set() for stage in STAGES}
    for line in records.splitlines():
        fields = line.split('\t')
        if len(fields) != 3 or fields[0] != 'S' or fields[2] not in groups:
            continue
        key = fields[1]
        if not re.fullmatch(r'[0-9a-f]{16}(?:-[0-9a-f]{4,8})?_b', key):
            raise ValueError('invalid recorded shader name')
        if (directory / (key + '.metallib')).is_file():
            groups[fields[2]].add(key)
    selected = []
    for stage, keys in groups.items():
        ordered = sorted(keys, key=lambda key: ((directory / (key + '.metallib')).stat().st_size, key))
        if not ordered:
            raise ValueError('each shader stage needs an observed source library')
        for key in dict.fromkeys(ordered[int((len(ordered) - 1) * q)] for q in (0, .5, .95)):
            selected.append((key, STAGES[stage], False))
    for key in CUBES:
        if (directory / (key + '.metallib')).is_file():
            selected.append((key, 'vertex', True))
    return selected


def rename_entry(source, entry, suffix):
    if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', entry) or not re.fullmatch(r'[0-9a-f]{32}', suffix):
        raise ValueError('invalid isolated entry-point identity')
    result, count = re.subn(r'\b' + re.escape(entry) + r'\b', entry + '_' + suffix, source)
    if not count:
        raise ValueError('shader entry point missing')
    return result


def pilot(directory, records, output):
    chosen = samples(directory, records.read_text())
    output.mkdir(parents=True, exist_ok=False)
    report = {'libraries': [], 'host_os': platform.mac_ver()[0], 'metal_language': '3.2', 'source_chain': directory.name,
              'transform_sha256': {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                                   for name in ('host/nvn_shader_math.h', 'host/nvn_cube_source.h')},
              'note': 'Unique entry points isolate new library identities; no global cache is cleared.'}
    with (output / 'compiler.log').open('w') as log, tempfile.TemporaryDirectory(prefix='shader-libraries-', dir=ROOT / 'work/tmp') as temporary:
        temporary = Path(temporary)
        environment = dict(os.environ, TMPDIR=str(temporary) + '/')

        def run(command):
            result = subprocess.run([str(arg) for arg in command], cwd=ROOT, env=environment,
                                    stdout=subprocess.PIPE, stderr=log, text=True, timeout=90)
            if result.returncode:
                raise RuntimeError('shader probe command failed; inspect compiler.log')
            return result.stdout

        report['compiler'] = run(['xcrun', '--sdk', 'macosx', 'metal', '--version']).strip()
        probe = temporary / 'probe'
        run(['clang', '-O2', '-fobjc-arc', '-Wall', '-Wextra', '-Werror', ROOT / 'tools/shader_library_probe.m',
             '-framework', 'Foundation', '-framework', 'Metal', '-framework', 'QuartzCore', '-o', probe])
        for index, (key, stage, cube) in enumerate(chosen):
            source = directory / (key + '.metallib')
            with source.open('rb') as stream:
                if stream.read(4) == b'MTLB':
                    raise ValueError('pilot requires MSL source inputs')
            metadata = json.loads(source.with_suffix('.json').read_text())
            prepared = temporary / (str(index) + '.metal')
            info = json.loads(run([probe, 'export', source, prepared, *(['cube'] if cube else [])]))
            raw = Path(str(prepared) + '.raw.metal')
            original, effective = raw.read_text(), prepared.read_text()
            flags = ['-fmetal-math-mode=safe', '-fmetal-math-fp32-functions=precise'] if info['strict_math'] else []
            item = dict(key=key, stage=stage, layered=cube, strict_math=info['strict_math'],
                        source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(), trials=[])
            for isolated in (False, True):
                suffix = uuid.uuid4().hex
                raw.write_text(rename_entry(original, metadata['entry'], suffix) if isolated else original)
                prepared.write_text(rename_entry(effective, metadata['entry'], suffix) if isolated else effective)
                trial = {'isolated_entry': isolated, 'targets': {}}
                for sdk, target in [('macosx', 'air64-apple-macosx26.0'), ('iphoneos', 'air64-apple-ios26.0')]:
                    # One iOS compile per case is enough; execution here is macOS-only.
                    if isolated and sdk == 'iphoneos':
                        continue
                    library = temporary / (sdk + '.metallib')
                    air = temporary / (sdk + '.air')
                    start = time.monotonic()
                    run(['xcrun', '--sdk', sdk, 'metal', '-target', target, '-std=metal3.2', *flags, '-c', prepared, '-o', air])
                    run(['xcrun', '--sdk', sdk, 'metal', '-target', target, air, '-o', library])
                    trial['targets'][sdk] = dict(compile_ms=(time.monotonic() - start) * 1000, bytes=library.stat().st_size,
                                                sha256=hashlib.sha256(library.read_bytes()).hexdigest(), target=target, flags=flags)
                    if sdk == 'macosx':
                        trial['bench'] = json.loads(run([probe, 'bench', raw, library, *(['binary-first'] if index % 2 else [])]))
                item['trials'].append(trial)
            report['libraries'].append(item)
            (output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
            print(f'Validated {index + 1}/{len(chosen)} {stage} layered={cube}', flush=True)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path, help='Existing b-<chain> source-library directory')
    parser.add_argument('--records', type=Path, default=ROOT / 'work/shaders/pso_user.tsv')
    parser.add_argument('--output', type=Path, required=True, help='New directory for small evidence files')
    args = parser.parse_args()
    pilot(args.directory.resolve(), args.records.resolve(), args.output.resolve())
