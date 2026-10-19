"""Build resumable macOS Metal IR beside the source cache; never replace MSL inputs."""
import argparse
from concurrent.futures import Future, ThreadPoolExecutor
from collections import deque
from functools import lru_cache
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
TARGET = 'air64-apple-macosx26.0'
LANGUAGE = 'metal3.2'
STRICT_FLAGS = ['-fmetal-math-mode=safe', '-fmetal-math-fp32-functions=precise']
CUBES = {'48e3901f9b4eb169_b', 'c3960b272d349125_b'}


@lru_cache(maxsize=1)
def contract():
    digest = hashlib.sha256(json.dumps([1, TARGET, LANGUAGE, STRICT_FLAGS]).encode())
    for name in ('host/nvn_shader_math.h', 'host/nvn_cube_source.h', 'tools/shader_library_probe.m'):
        digest.update(name.encode() + b'\0' + (ROOT / name).read_bytes())
    return digest.hexdigest()


def cache_directory(source):
    return source.parent / 'ir-macos' / source.name / contract()


def current(metadata, binary, source_hash, layered):
    try:
        if metadata.stat().st_size > 4096 or binary.stat().st_size > (64 << 20):
            return False
        record = json.loads(metadata.read_text())
        valid = (record['format'] == 1 and record['contract'] == contract() and record['target'] == TARGET and record['language'] == LANGUAGE and
                record['layered'] == layered and record['source_sha256'] == source_hash and
                binary.is_file() and hashlib.sha256(binary.read_bytes()).hexdigest() == record['binary_sha256'])
        return record if valid else None
    except (OSError, ValueError, KeyError, TypeError):
        return None


def build(directory, keys=None, jobs=2):
    sources = sorted(directory.glob('*.metallib'))
    if keys is not None:
        names = set(keys)
        if any(not name or Path(name).name != name or not name.endswith('.metallib') for name in names):
            raise ValueError('keys must be source-library basenames')
        sources = [source for source in sources if source.name in names]
        if {p.name for p in sources} != names:
            raise ValueError('a selected source library is missing')
    if not sources:
        raise ValueError('no source libraries found')
    destination = cache_directory(directory); destination.mkdir(parents=True, exist_ok=True)
    identity = contract()
    work = ROOT / 'work/tmp'; work.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='shader-ir-', dir=work) as temporary:
        temporary = Path(temporary)
        environment = dict(os.environ, TMPDIR=str(temporary) + '/')

        def run(args):
            result = subprocess.run([str(arg) for arg in args], env=environment, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True, timeout=90)
            if result.returncode:
                raise RuntimeError(result.stderr[-3000:])
            return result.stdout

        compiler = run(['xcrun', '--sdk', 'macosx', '--find', 'metal']).strip()
        sdk = run(['xcrun', '--sdk', 'macosx', '--show-sdk-path']).strip()
        version = run([compiler, '--version']).splitlines()[0]
        exporter = temporary / 'export'
        run(['clang', '-O2', '-fobjc-arc', ROOT / 'tools/shader_library_probe.m', '-framework', 'Foundation',
             '-framework', 'Metal', '-framework', 'QuartzCore', '-o', exporter])
        shared, shared_lock = {}, threading.Lock()

        def finish(job):
            source, layered = job
            data = source.read_bytes()
            if data[:4] == b'MTLB':
                raise ValueError('expected MSL source, not an existing binary')
            source_hash = hashlib.sha256(data).hexdigest()
            name = source.stem + ('-cube' if layered else '')
            binary, metadata = destination / (name + '.metallib'), destination / (name + '.json')
            prior = current(metadata, binary, source_hash, layered)
            with shared_lock:
                future = shared.get((source_hash, layered))
                owner = future is None
                if owner: future = shared[(source_hash, layered)] = Future()
            if prior:
                if owner: future.set_result((binary, prior))
                return 'reused'
            if not owner:
                original, record = future.result()
                with tempfile.TemporaryDirectory(dir=temporary) as folder:
                    folder = Path(folder)
                    linked, staged = folder / 'output.metallib', folder / 'metadata.json'
                    os.link(original, linked)
                    staged.write_text(json.dumps(record, sort_keys=True) + '\n')
                    linked.replace(binary); staged.replace(metadata)
                return 'shared'
            try:
                result = compile_one(source, data, source_hash, layered, binary, metadata)
                future.set_result(result)
            except BaseException as error:
                future.set_exception(error)
                raise
            return 'compiled'

        def compile_one(source, data, source_hash, layered, binary, metadata):
            with tempfile.TemporaryDirectory(dir=temporary) as folder:
                folder = Path(folder)
                raw, prepared = folder / 'input.metal', folder / 'prepared.metal'
                raw.write_bytes(data)
                exported = json.loads(run([exporter, 'export', raw, prepared, *(['cube'] if layered else [])]))
                flags = STRICT_FLAGS if exported['strict_math'] else []
                compiled = folder / 'output.metallib'
                # The driver compiles and links in one call, avoiding a second compiler process per library.
                run([compiler, '-isysroot', sdk, '-target', TARGET, '-std=' + LANGUAGE, *flags, prepared, '-o', compiled])
                content = compiled.read_bytes()
                if content[:4] != b'MTLB':
                    raise ValueError('compiler did not produce a Metal library')
                record = dict(format=1, contract=identity, target=TARGET, language=LANGUAGE, layered=layered,
                              source_sha256=source_hash, binary_sha256=hashlib.sha256(content).hexdigest(),
                              compiler=version, flags=flags)
                staged = folder / 'metadata.json'; staged.write_text(json.dumps(record, sort_keys=True) + '\n')
                # Publishing metadata last lets concurrent readers reject an incomplete update and use source.
                compiled.replace(binary); staged.replace(metadata)
                return binary, record

        tasks = [(source, layered) for source in sources for layered in ((False, True) if source.stem in CUBES else (False,))]
        start = time.monotonic(); counts = dict(compiled=0, shared=0, reused=0)
        with ThreadPoolExecutor(max_workers=jobs) as executor:
            iterator = iter(tasks)
            pending = deque(executor.submit(finish, job) for _, job in zip(range(jobs * 2), iterator))
            count = 0
            while pending:
                changed = pending.popleft().result(); count += 1
                job = next(iterator, None)
                if job is not None: pending.append(executor.submit(finish, job))
                counts[changed] += 1
                if count % 100 == 0 or count == len(tasks):
                    print(f'IR progress={count}/{len(tasks)} compiled={counts["compiled"]} shared={counts["shared"]} reused={counts["reused"]} seconds={time.monotonic() - start:.1f}', flush=True)
        print(json.dumps(dict(contract=identity, libraries=len(tasks), **counts,
                              seconds=time.monotonic()-start)), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--keys', type=Path, help='Optional newline-separated source basenames for a small batch')
    parser.add_argument('--jobs', type=int, choices=(1, 2, 4), default=2)
    args = parser.parse_args()
    build(args.directory.resolve(), args.keys.read_text().splitlines() if args.keys else None, args.jobs)
