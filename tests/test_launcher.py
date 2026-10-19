from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LauncherTests(unittest.TestCase):
    def test_launch_from_elsewhere_with_spaces_and_missing_build(self):
        with tempfile.TemporaryDirectory(prefix='launcher ', dir=ROOT / 'work/tmp') as temp:
            root = Path(temp)
            launcher = root / 'launch.command'
            shutil.copy2(ROOT / launcher.name, launcher)
            quick = root / 'quick-load.command'
            shutil.copy2(ROOT / quick.name, quick)
            missing = subprocess.run([str(launcher)], cwd='/', capture_output=True, text=True)
            self.assertEqual(missing.returncode, 1)
            self.assertIn('build_and_run.sh --load-only', missing.stderr)

            app = root / 'work/build/Zelda-Mobile.app'
            binary = app / 'Contents/MacOS/launch'
            binary.parent.mkdir(parents=True)
            binary.write_text('#!/bin/bash\nprintf "%s" "$PWD" > launched-path\nprintf "%s" "${ZELDA_INPUT_SCRIPT:-}" > input-script\n')
            binary.chmod(0o700)
            commands = root / 'bin'
            commands.mkdir()
            opener = commands / 'open'
            opener.write_text('#!/bin/bash\n[[ $# == 1 ]] || exit 2\nprintf "%s" "$1" > opened-path\n')
            opener.chmod(0o700)
            process_check = commands / 'pgrep'
            process_check.write_text('#!/bin/bash\n[[ "$1" == -x && "$2" == zelda_probe ]] || exit 2\nexit "${ALREADY_RUNNING:-1}"\n')
            process_check.chmod(0o700)
            environment = dict(os.environ, PATH=f'{commands}:/usr/bin:/bin')
            subprocess.run([str(launcher)], cwd='/', env=environment, check=True)
            self.assertEqual((root / 'launched-path').read_text(), str(root))
            self.assertFalse((root / 'opened-path').exists())
            (root / 'launched-path').unlink()
            environment['ALREADY_RUNNING'] = '0'
            subprocess.run([str(launcher)], cwd='/', env=environment, check=True)
            self.assertFalse((root / 'launched-path').exists())
            self.assertEqual((root / 'opened-path').read_text(), str(app))
            subprocess.run([str(quick)], cwd='/', env=environment, check=True)
            self.assertFalse((root / 'launched-path').exists())
            environment['ALREADY_RUNNING'] = '1'
            subprocess.run([str(quick)], cwd='/', env=environment, check=True)
            self.assertEqual((root / 'input-script').read_text(), str(root / 'script/scenes/first-save-fast.input'))
