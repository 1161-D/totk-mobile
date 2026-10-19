"""Build an atomic, fingerprinted set of rewritten Zelda modules."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from extract_exefs import digest
from patch_module import CORE, ROOT


def current_inputs():
    work = ROOT / 'work'
    expected = {'main': 'e84a90d551fed0824b4b74933b9c6d043c458521363a7cea58b2faca1822dc9e',
                'subsdk0': '767c35bcd7d23e78f9063c69b638290b8b83f91e839beb10799e6576960179b1',
                'sdk': '1d187f29784cd0af46e9e123fc2a62c77b3b07c5a39c8633d90d6c80de64e4ad'}
    actual = {n: digest(work / 'exefs' / n) for n in expected}
    if actual != expected:
        raise ValueError('unsupported ExeFS: this adapter is bound to the supplied v1.4.3 hashes')
    sources = ('tools/patch_nso.py', 'host/loader.c', 'host/entry.S', 'host/dm.h', 'host/hle.h')
    return {'modules': actual, 'core': {n: digest(CORE / n) for n in sources},
            'adapter': {p.name: digest(p) for p in (ROOT / 'tools').glob('*.py')}}


def ready(output, inputs):
    record = output / 'build.json'
    if record.exists():
        cached = json.loads(record.read_text())
        return cached['inputs'] == inputs and all((output / n).is_file() and digest(output / n) == sha
                                                  for n, sha in cached['outputs'].items())
    return False


def prepare(check_only=False):
    work = ROOT / 'work'
    exefs, output = work / 'exefs', work / 'patched'
    inputs = current_inputs()
    if ready(output, inputs):
        print('Patched modules already verified:', output)
        return
    if check_only:
        raise ValueError('missing, changed or stale modules; run ./script/prepare.sh')
    if (output / 'build.json').exists():
        pass
    elif output.exists():
        raise ValueError('unrecognized patched output directory; refusing to replace it')
    with tempfile.TemporaryDirectory(prefix='patch-', dir=work) as temp:
        staged = Path(temp) / 'modules'
        staged.mkdir()
        for name in inputs['modules']:
            print('Rewriting', name, flush=True)
            log = work / 'logs' / f'patch-{name}.log'
            with log.open('w') as stream:
                result = subprocess.run([sys.executable, str(ROOT / 'tools/patch_module.py'),
                                         str(exefs / name), str(staged), name],
                                        stdout=stream, stderr=subprocess.STDOUT)
            if result.returncode:
                print(log.read_text(), file=sys.stderr)
                raise ValueError(f'{name}: rewrite failed; no runnable output was published')
            print(log.read_text().strip(), flush=True)
        info = {'inputs': inputs, 'outputs': {p.name: digest(p) for p in staged.iterdir()}}
        (staged / 'build.json').write_text(json.dumps(info, indent=2) + '\n')
        if output.exists():
            shutil.rmtree(output)
        staged.rename(output)
    print('Patched modules verified:', output)


if __name__ == '__main__':
    if sys.argv[1:] not in ([], ['--check']):
        sys.exit('usage: prepare_modules.py [--check]')
    try:
        prepare(check_only=sys.argv[1:] == ['--check'])
    except (ValueError, OSError) as error:
        sys.exit(str(error))
