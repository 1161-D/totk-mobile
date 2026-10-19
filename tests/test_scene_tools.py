import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'script'))
import scene_report  # noqa: E402


class SceneToolTests(unittest.TestCase):
    def test_raw_frame_tails_keep_discarded_presentations_separate(self):
        text = '# timing\nframe\tname\tvalue\n99\t@frame_ms\t500\n'
        for frame, present in enumerate((16.667, 25, -1, 8.333, 16.667), 100):
            text += f'{frame}\t@frame_ms\t{33 if frame == 101 else 16.667}\n{frame}\t@presented_ms\t{present}\n'
        with tempfile.TemporaryDirectory(dir=ROOT / 'work/tmp') as temp:
            path = Path(temp) / 'frames.tsv'; path.write_text(text)
            report = scene_report.frame_window(path, 100, 104)
        self.assertEqual((report['expected_frames'], report['recorded_frames']), (5, 5))
        self.assertTrue(report['complete'])
        self.assertEqual(report['present_discarded'], 1)
        self.assertEqual(report['presented_ms']['count'], 4)
        self.assertEqual(report['presented_ms']['p99'], 25)
        self.assertEqual(report['presented_ms']['over_16_8_ms'], 1)
        self.assertEqual(report['frame_ms']['max'], 33)
        with self.assertRaises(ValueError): scene_report.frame_window('unused', 104, 100)

    def test_frame_report_marks_truncated_or_missing_presentations_incomplete(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'work/tmp') as temp:
            path = Path(temp) / 'frames.tsv'
            path.write_text('100\t@frame_ms\t16.667\n100\t@presented_ms\t16.667\n101\t@frame_ms\t16.667\n')
            report = scene_report.frame_window(path, 100, 102)
        self.assertFalse(report['complete'])
        self.assertEqual(report['missing_metrics'], {'@frame_ms': 1, '@presented_ms': 2})

    def test_timeline_reports_slices_and_starvation(self):
        ms = 1_000_000
        rows = []
        for frame in range(4):
            start = frame * 20 * ms
            first, second = 2 * frame + 1, 2 * frame + 2
            rows += [(start, start + 6 * ms, 1, 7, 1, second),
                     (start + ms, start + ms, 2, 7, first, frame), (start + 5 * ms, start + 5 * ms, 2, 7, second, frame),
                     # The first slice finishes before the second is committed: 2 ms of GPU idle.
                     (start + 2 * ms, start + 2 * ms, 3, 9, first, start + 3 * ms),
                     (start + 6 * ms, start + 6 * ms, 3, 9, second, start + 18 * ms),
                     (start + 6 * ms, start + 19 * ms, 8, 7, 0x34, 0)]
        with tempfile.TemporaryDirectory(dir=ROOT / 'work/tmp') as temp:
            trace = Path(temp) / 'trace.tsv'
            trace.write_text('begin_ns\tend_ns\tkind\tthread\ta\tb\n' + ''.join('\t'.join(map(str, row)) + '\n' for row in rows))
            report = scene_report.timeline(trace)
        self.assertEqual(report['frames'], 2)
        self.assertEqual(report['period_ms']['mean'], 20)
        self.assertEqual(report['commits']['mean'], 2)
        self.assertEqual(report['gpu_start_after_submit_ms']['mean'], 2)
        self.assertEqual(report['gpu_busy_ms']['mean'], 13)
        self.assertEqual(report['gpu_span_ms']['mean'], 16)
        self.assertEqual(report['starved_ms_per_frame'], 3)
        self.assertAlmostEqual(report['render_thread_wait_share']['0x34'], 52 / 60)

    def test_window_keeps_missing_presentation_separate(self):
        header = 'time_s\tframe\tfps\tp95_ms\tgpu_ms\tsubmit_cpu_ms\tphysical_gb\tgpu_gb\tdraws\tupload_mb\tdropped\tthermal\tstale_s\trender_fps\trender_p95_ms\tpacing_fps\tpacing_override\n'
        rows = [f'{10 + i}\t{60 * i}\t{-1 if i == 1 else 60}\t16.667\t13\t7\t2.6\t2.2\t1100\t2.7\t{i}\t0\t0\t{59 + i}\t20\t60\t0\n' for i in range(4)]
        with tempfile.TemporaryDirectory(dir=ROOT / 'work/tmp') as temp:
            summary = Path(temp) / 'performance.tsv'
            summary.write_text(header + ''.join(rows))
            report = scene_report.window(summary, 10, 13)
            self.assertNotIn('game_speed_ratio', report)
            original = summary.read_text().splitlines()
            for speed in (1, 2):
                summary.write_text(original[0] + '\tgame_seconds\n' + '\n'.join(
                    line + '\t' + str(speed * float(line.split('\t')[0])) for line in original[1:]) + '\n')
                timed = scene_report.window(summary, 10, 13)
                self.assertEqual(timed['game_speed_ratio'], speed)
        self.assertEqual(report['rows'], 3)
        self.assertEqual(report['present_valid_rows'], 2)
        self.assertEqual(report['present_fps'], 60)
        self.assertEqual(report['render_fps_min'], 59)
        self.assertEqual(report['dropped'], [0, 2])

    def test_send_input_fails_fast_without_a_reader(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'work/tmp') as temp:
            fifo = Path(temp) / 'input.fifo'
            os.mkfifo(fifo)
            result = subprocess.run([sys.executable, str(ROOT / 'script/send_input.py'), 'tap x'], cwd=ROOT,
                                    env={**os.environ, 'ZELDA_INPUT_FIFO': str(fifo)}, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('ENXIO', result.stderr)


if __name__ == '__main__':
    unittest.main()
