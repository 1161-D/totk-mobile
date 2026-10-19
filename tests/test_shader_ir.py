import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'script'))
from build_shader_ir import build, cache_directory, contract, current, TARGET, LANGUAGE


class ShaderIRTests(unittest.TestCase):
    def test_cache_identity_checks_content_and_policy(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'work/tmp') as temporary:
            path = Path(temporary); binary, metadata = path / 'a.metallib', path / 'a.json'
            binary.write_bytes(b'MTLBfixture')
            record = dict(format=1, contract=contract(), target=TARGET, language=LANGUAGE, layered=False, source_sha256='source',
                          binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest())
            metadata.write_text(json.dumps(record))
            self.assertTrue(current(metadata, binary, 'source', False))
            self.assertFalse(current(metadata, binary, 'changed', False))
            self.assertFalse(current(metadata, binary, 'source', True))
            binary.write_bytes(b'MTLBchanged'); self.assertFalse(current(metadata, binary, 'source', False))
            metadata.write_text('[]'); self.assertFalse(current(metadata, binary, 'source', False))
            metadata.write_text(' ' * 8192); self.assertFalse(current(metadata, binary, 'source', False))
            metadata.unlink(); self.assertFalse(current(metadata, binary, 'source', False))

    def test_compiled_cache_gpu_readback_and_fallback(self):
        if subprocess.run(['xcrun', '--sdk', 'macosx', 'metal', '--version'], capture_output=True).returncode:
            self.skipTest('Optional Metal Toolchain is not installed')
        with tempfile.TemporaryDirectory(dir=ROOT / 'work/tmp') as temporary:
            path = Path(temporary); sources = path / 'sources'; sources.mkdir()
            source = sources / 'fixture.metallib'
            source.write_text('#include <metal_stdlib>\nusing namespace metal;\n'
                              'struct Args { device uint *out [[id(0)]]; };\n'
                              'kernel void fixture(constant Args &a [[buffer(0)]], uint i [[thread_position_in_grid]]) { a.out[i] = i * 7 + 3; }\n')
            clones = [sources / ('copy' + str(i) + '.metallib') for i in range(2)]
            for clone in clones: clone.write_bytes(source.read_bytes())
            build(sources, jobs=2)
            binary = cache_directory(sources) / 'fixture.metallib'
            for clone in clones:
                self.assertEqual(binary.stat().st_ino, (cache_directory(sources) / clone.name).stat().st_ino)
            before = binary.stat().st_mtime_ns
            build(sources, jobs=1)
            self.assertEqual(before, binary.stat().st_mtime_ns)
            for clone in clones: clone.unlink()
            (path / 'shader_ir_identity.h').write_text(f'#define ZELDA_SHADER_IR_CONTRACT "{contract()}"\n')
            (path / 'dmsh_chain.h').write_text('#define DMSH_CHAIN "fixture"\n')
            test = path / 'test'
            subprocess.run(['clang', '-O2', '-fobjc-arc', '-Wall', '-Wextra', '-Werror', '-I', str(path),
                            str(ROOT / 'tests/test_shader_ir.m'), str(ROOT / 'host/shader_prep.m'), str(ROOT / 'host/performance.c'),
                            '-framework', 'Cocoa', '-framework', 'QuartzCore', '-framework', 'Metal', '-o', str(test)], check=True)
            subprocess.run([str(test), str(source)], env=dict(os.environ, MTL_DEBUG_LAYER='1'), check=True)
