"""Repository checks that need neither game resources nor a Metal device."""
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'script'))
from game_inputs import game_package


def documents():
    # Root pages, public guides and, on the private branch, internal notes.
    return [*ROOT.glob('*.md'), *(ROOT / 'docs').rglob('*.md'), *(ROOT / 'internal').rglob('*.md')]


class RepositoryTests(unittest.TestCase):
    @unittest.skipUnless((ROOT / '.git').exists(), 'Source inventory requires a checkout')
    def test_project_source_and_filenames_use_english(self):
        names = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT)
        source_types = {'.c', '.h', '.m', '.S', '.inc', '.py', '.sh', '.swift', '.metal', '.input',
                        '.command', '.patch', '.txt', '.plist', '.entitlements', '.toml', '.json', '.yml', '.yaml'}
        for name in filter(None, names.decode().split('\0')):
            path = ROOT / name
            if not path.is_file():
                continue
            with self.subTest(path=name):
                self.assertTrue(name.isascii(), 'Project-managed filenames must use ASCII English')
                # core/ keeps imported sources byte-identical so build-time anchors and fingerprints stay valid.
                if path.suffix in source_types and not name.startswith('core/'):
                    self.assertNotRegex(path.read_text(), r'[\u3400-\u4dbf\u4e00-\u9fff]',
                                        'Use English; encode necessary upstream anchors and Unicode fixtures explicitly')

    def test_game_input_directories(self):
        (ROOT / 'work/tmp').mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / 'work/tmp') as temporary:
            root = Path(temporary)
            with self.assertRaises(ValueError): game_package(root, True)
            games = root / 'local/games'; games.mkdir(parents=True)
            base, update = games / 'base.nsz', games / 'game[UPD].NSZ'
            base.touch(); update.touch(); (games / 'ignored.nsp').touch()
            self.assertEqual(game_package(root, False), base)
            self.assertEqual(game_package(root, True), update)
            legacy = root / update.name; update.rename(legacy)
            self.assertEqual(game_package(root, True), legacy)
            update.touch()
            with self.assertRaises(ValueError): game_package(root, True)
            legacy.unlink(); update.unlink(); (root / 'not-a-file[UPD].nsz').mkdir()
            with self.assertRaises(ValueError): game_package(root, True)

    def test_no_personal_absolute_paths(self):
        files = documents()
        for directory in ('host', 'ios', 'script', 'tools', 'tests'):
            files += [p for p in (ROOT / directory).rglob('*') if p.is_file()
                      and p.suffix in {'.c', '.h', '.m', '.inc', '.py', '.sh', '.txt', '.plist'}]
        for path in files:
            with self.subTest(path=path.relative_to(ROOT)):
                self.assertNotRegex(path.read_text(), r'/(?:Users|Volumes|private/var|var/folders)/')

    def test_document_links(self):
        for doc in documents():
            for target in re.findall(r'\[[^\]]+\]\(([^\s)]+)\)', doc.read_text()):
                link = urlsplit(target)
                if link.scheme or link.netloc or not link.path:
                    continue
                path = (doc.parent / unquote(link.path)).resolve()
                with self.subTest(document=doc.relative_to(ROOT), target=target):
                    self.assertTrue(path.is_relative_to(ROOT), 'Use repository-relative paths')
                    self.assertFalse(path.is_relative_to(ROOT / 'work'), 'Write local evidence paths as code, not links')
                    self.assertTrue(path.exists(), 'Broken document link')

    def test_public_documents_have_both_languages(self):
        public = [*ROOT.glob('*.md'), *(ROOT / 'docs').glob('*.md')]
        for doc in public:
            if doc.name in {'AGENTS.md', 'CLAUDE.md'}:
                continue
            pair = doc.with_name(doc.name[:-len('.zh-CN.md')] + '.md' if doc.name.endswith('.zh-CN.md')
                                 else doc.stem + '.zh-CN.md')
            with self.subTest(document=doc.relative_to(ROOT)):
                self.assertTrue(pair.is_file(), 'Public guides are English-first with a Simplified Chinese copy')
                text = doc.read_text()
                self.assertNotIn('internal/', text, 'Public guides must not point at private notes')

    def test_requirement_includes(self):
        requirements = ROOT / 'requirements'
        self.assertEqual({p.name for p in requirements.glob('*.txt')},
                         {'runtime.txt', 'resources.txt', 'test.txt', 'ios-transfer.txt'})
        for manifest in requirements.glob('*.txt'):
            for line in manifest.read_text().splitlines():
                if line.startswith('-r '):
                    with self.subTest(manifest=manifest.name):
                        self.assertTrue((manifest.parent / line[3:]).is_file())
        for script, manifest in [('prepare.sh', 'runtime.txt'), ('prepare_resources.sh', 'resources.txt'),
                                 ('ios.sh', 'ios-transfer.txt')]:
            self.assertIn('requirements/' + manifest, (ROOT / 'script' / script).read_text())

    @unittest.skipUnless((ROOT / '.git').exists(), 'Git checks require a checkout')
    def test_private_paths_stay_out_of_git(self):
        samples = ['local/games/game.nsz', 'local/keys/notes.txt', 'local/save-imports/slot/progress.sav',
                   'work/save/progress.sav', 'prod.keys', 'game.nsz', 'GAME.NsZ', 'game.nsp', 'game.xci', 'romfs.bin',
                   '.env', 'ZeldaMobile.ipa', 'profile.mobileprovision', 'signing.p12',
                   '.codex/environments/environment.toml', 'ZELDA_TOTK_SAVE/progress.sav']
        ignored = subprocess.check_output(['git', 'check-ignore', '--no-index', '--stdin', '-z'],
                                          cwd=ROOT, input=('\0'.join(samples) + '\0').encode())
        self.assertEqual(set(ignored.decode().strip('\0').split('\0')), set(samples))
        tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
        forbidden = {'.nsz', '.nsp', '.xci', '.nca', '.ncz', '.keys', '.tik', '.ipa', '.mobileprovision', '.p12', '.bin', '.sav'}
        for name in filter(None, tracked):
            with self.subTest(path=name):
                self.assertFalse(name.startswith(('work/', 'local/', '.codex/', 'ProdKeys', 'ZELDA_TOTK_SAVE/')))
                self.assertNotIn(Path(name).suffix.lower(), forbidden)


if __name__ == '__main__':
    unittest.main()
