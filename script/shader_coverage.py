"""Translate every shader the game ships, before it is drawn.

prepare_shaders.sh originally covered the material/terrain/UI archives; effects (Effect/*.esetb) and engine libraries
(Lib/*/…sarc) were only captured on first draw, which ran the whole offline pipeline inside a frame (about 10 s).
This driver indexes the extended extraction, requests the program pairs, runs the unchanged translator in parallel
processes and builds MSL with the unchanged build step. Translation failures are reported, not raised: an unused
blocked shader must not stop preparation, and a requested one still stops the game explicitly at run time.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

from build_shaders import ROOT, TOOLS, XLATE, build, shader_entries
from index_shaders import index
from shader_pairs import request
from translate_shaders import valid

SHADERS = ROOT / 'work/shaders'
ENVIRONMENT = dict(os.environ, DOTNET_ROOT=str(TOOLS / 'dotnet'), DOTNET_CLI_HOME=str(TOOLS / 'dotnet-home'),
                   DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_NOLOGO='1')


def job(entry):
    # Same job as translate_shaders.translate(): DebugMode keeps BRX cases, pairs carry the next stage's code.
    result = dict(entry, code=str(SHADERS / 'code' / (entry.get('base', entry['key']) + '.bin')), debug=True)
    if 'next' in result:
        result['next'] = dict(result['next'], code=str(SHADERS / 'code' / (result['next']['key'] + '.bin')))
    return result


def translate_parallel(entries, workers):
    output = SHADERS / 'spv'
    output.mkdir(exist_ok=True)
    pending = [entry for entry in entries if not valid(entry, output)]
    for entry in pending:
        for suffix in ('.spv', '.res.json'):
            (output / (entry['key'] + suffix)).unlink(missing_ok=True)
    chunks = [pending[i::workers] for i in range(workers) if pending[i::workers]]
    processes = []
    for i, chunk in enumerate(chunks):
        path = SHADERS / f'jobs-{i}.json'
        path.write_text(json.dumps([job(entry) for entry in chunk]) + '\n')
        log = open(ROOT / f'work/logs/shader-coverage-xlate-{i}.log', 'w')
        processes.append((subprocess.Popen([str(TOOLS / 'dotnet/dotnet'), str(XLATE / 'dmsh_xlate.dll'), str(path), str(output)],
                                           env=ENVIRONMENT, stdout=log, stderr=subprocess.STDOUT), path, log))
    for process, path, log in processes:
        if process.wait() not in (0, 1):
            raise RuntimeError('shader translator could not run; see work/logs/shader-coverage-xlate-*.log')
        log.close()
        path.unlink()
    failed = [entry['key'] for entry in pending if not valid(entry, output)]
    return len(pending), failed


def main():
    start = time.time()
    index(SHADERS / 'source', SHADERS / 'code')
    workers = int(os.environ.get('ZELDA_SHADER_WORKERS', max(1, (os.cpu_count() or 4) - 2)))
    failed = []
    # The second round adds integer-format variants, which need the built base libraries' inputs and outputs.
    for round in range(2):
        if not request() and round:
            break
        translated, missing = translate_parallel(shader_entries(SHADERS), workers)
        failed = sorted(set(failed) | set(missing))
        print(f'Translated {translated - len(missing)} of {translated} pending shaders with {workers} processes; failed {len(missing)}',
              f'({time.time() - start:.0f} s)', flush=True)
        blocked = build()
    (SHADERS / 'translate-failures.json').write_text(json.dumps(failed, indent=2) + '\n')
    print(f'Shader coverage finished in {time.time() - start:.0f} s', flush=True)
    return 1 if blocked or failed else 0


if __name__ == '__main__':
    sys.exit(main())
