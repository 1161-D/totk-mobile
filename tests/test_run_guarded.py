import os
from pathlib import Path
import signal
import sys
import unittest
from unittest.mock import patch
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'script'))
from run_guarded import MacMemory, run


class FakeMemory:
    def __init__(self, footprint=1, pressure=1):
        self.footprint, self.level, self.reads = footprint, pressure, 0

    def group_bytes(self, group):
        self.reads += 1
        return self.footprint

    def pressure(self):
        return self.level if self.reads else 1


class GuardTests(unittest.TestCase):
    def test_live_physical_memory_and_pressure_are_readable(self):
        memory = MacMemory()
        self.assertIn(os.getpid(), memory.group_pids(os.getpgrp()))
        self.assertGreater(memory.group_bytes(os.getpgrp()), 0)
        self.assertIn(memory.pressure(), (1, 2, 4))

    def test_limits_stop_and_reap_owned_process(self):
        for expected, memory, seconds in [('deadline', FakeMemory(), 0.02),
                                          ('physical_footprint', FakeMemory(1025), 10),
                                          ('system_memory_pressure', FakeMemory(1, 2), 10)]:
            with self.subTest(reason=expected):
                result = run([sys.executable, '-c', 'import time; time.sleep(30)'], seconds, 1024, memory)
                self.assertEqual(result['stop_reason'], expected)
                self.assertEqual(result['returncode'], -signal.SIGTERM)
                self.assertLess(result['elapsed_seconds'], 3)
                with self.assertRaises(ProcessLookupError):
                    os.kill(result['pid'], 0)

    def test_normal_exit_and_monitor_failure(self):
        result = run([sys.executable, '-c', 'raise SystemExit(7)'], 5, 1024, FakeMemory())
        self.assertIsNone(result['stop_reason'])
        self.assertEqual(result['returncode'], 7)
        class Failing(FakeMemory):
            def group_bytes(self, group):
                self.pid = group
                raise OSError('monitor failed')
        memory = Failing()
        with self.assertRaisesRegex(OSError, 'monitor failed'):
            run([sys.executable, '-c', 'import time; time.sleep(30)'], 5, 1024, memory)
        with self.assertRaises(ProcessLookupError):
            os.kill(memory.pid, 0)

    def test_bad_limits_do_not_launch(self):
        for seconds in (0, -1, float('inf'), float('nan')):
            with self.assertRaises(ValueError):
                run(['does-not-exist'], seconds, 1024, FakeMemory())

    def test_disk_reserve_stops_before_or_during_launch(self):
        with patch('run_guarded.shutil.disk_usage', return_value=SimpleNamespace(free=0)):
            with self.assertRaisesRegex(RuntimeError, 'disk reserve'):
                run(['does-not-exist'], 5, 1024, FakeMemory())
        with patch('run_guarded.shutil.disk_usage', side_effect=[SimpleNamespace(free=8 << 30), SimpleNamespace(free=0)]):
            result=run([sys.executable, '-c', 'import time; time.sleep(30)'], 5, 1024, FakeMemory())
            self.assertEqual(result['stop_reason'], 'internal_disk_reserve')
            self.assertEqual(result['returncode'], -signal.SIGTERM)


if __name__ == '__main__':
    unittest.main()
