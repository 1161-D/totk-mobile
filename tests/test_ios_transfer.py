import hashlib
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'script'))
from ios_transfer import CHUNK, InterruptedUpload, local_hash, remote_path, save_source_lock, upload


class LocalAFC:
    def __init__(self, root): self.root = root; self.handles = {}; self.serial = 0; self.largest = 0
    def path(self, path): return self.root / path.lstrip('/')
    async def exists(self, path): return self.path(path).exists()
    async def makedirs(self, path): self.path(path).mkdir(parents=True, exist_ok=True)
    async def stat(self, path):
        p = self.path(path)
        return {'st_size': p.stat().st_size, 'st_ifmt': 'S_IFDIR' if p.is_dir() else 'S_IFREG'}
    async def get_device_info(self): return {'FSFreeBytes': 100 << 30}
    async def fopen(self, path, mode):
        self.serial += 1; self.handles[self.serial] = self.path(path).open(mode + 'b'); return self.serial
    async def fclose(self, handle): self.handles.pop(handle).close()
    async def fseek(self, handle, offset): self.handles[handle].seek(offset)
    async def fwrite(self, handle, block, chunk_size):
        assert len(block) <= CHUNK and chunk_size == CHUNK
        self.largest = max(self.largest, len(block)); self.handles[handle].write(block)
    async def fread(self, handle, size):
        assert size <= CHUNK
        return self.handles[handle].read(size)
    async def rename(self, a, b): self.path(a).rename(self.path(b))
    async def rm(self, p): self.path(p).unlink()


class TransferTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[1] / 'work/tmp')
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'; self.source.write_bytes(bytes(range(256)) * (CHUNK // 256 * 3) + b'end')
        self.afc = LocalAFC(self.root / 'device'); self.target = '/Documents/work/resource.bin'

    async def asyncTearDown(self): self.temp.cleanup()

    async def test_bounded_roundtrip_resume_and_reuse(self):
        with self.assertRaises(InterruptedUpload): await upload(self.afc, self.source, self.target, CHUNK)
        self.assertFalse(await self.afc.exists(self.target))
        result = await upload(self.afc, self.source, self.target)
        self.assertEqual(result['resumed'], CHUNK)
        self.assertEqual(result['sha256'], hashlib.sha256(self.source.read_bytes()).hexdigest())
        self.assertTrue((await upload(self.afc, self.source, self.target))['skipped'])
        self.assertLessEqual(self.afc.largest, CHUNK)

    async def test_corrupt_checkpoint_and_existing_file_are_preserved(self):
        with self.assertRaises(InterruptedUpload): await upload(self.afc, self.source, self.target, CHUNK)
        partial = self.afc.path(self.target + '.uploading'); partial.write_bytes(b'wrong')
        with self.assertRaisesRegex(ValueError, 'checkpoint content'): await upload(self.afc, self.source, self.target)
        self.assertEqual(partial.read_bytes(), b'wrong')
        partial.unlink(); final = self.afc.path(self.target); final.write_bytes(b'user data')
        with self.assertRaisesRegex(ValueError, 'refusing to replace'): await upload(self.afc, self.source, self.target)
        self.assertEqual(final.read_bytes(), b'user data')

    async def test_no_space_rejected_before_writing(self):
        async def low(): return {'FSFreeBytes': CHUNK}
        self.afc.get_device_info = low
        with self.assertRaisesRegex(ValueError, 'free storage'): await upload(self.afc, self.source, self.target)
        self.assertFalse(await self.afc.exists(self.target + '.uploading'))

    def test_path_boundary(self):
        for path in ('/Documents/work/../save', '/Documents/elsewhere/x', '/Documents/work/a/./b', '/Documents/work/a\\b'):
            with self.assertRaises(ValueError): remote_path(path)

    def test_large_source_hash_without_page_cache(self):
        path=self.root/'large';digest=hashlib.sha256();block=bytes(CHUNK)
        with path.open('wb') as stream:
            for _ in range(65):stream.write(block);digest.update(block)
        self.assertEqual(local_hash(path),digest.hexdigest())

    def test_save_import_excludes_a_concurrent_game_writer(self):
        path=self.root/'save.lock'
        with save_source_lock(path):
            with self.assertRaises(BlockingIOError):
                with save_source_lock(path):self.fail('second writer acquired the volume')
        with save_source_lock(path):pass


if __name__ == '__main__': unittest.main()
