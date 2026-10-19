"""Summaries for scripted scene measurements.

window PERFORMANCE_TSV START END   per-second rolling metrics between two CLOCK_UPTIME_RAW times (INPUT_SCRIPT marks)
timeline TRACE_TSV                 per-frame critical path from a ZELDA_INPUT_SCRIPT "trace" file
frames FRAME_TSV FIRST LAST         raw frame/present tails in an inclusive frame-number window
"""
import collections
import json
import statistics
import sys

SUBMIT, COMMIT, GPU, SYNC_WAIT, FENCE, ACQUIRE, PRESENT, SVC_WAIT, BARRIER = range(1, 10)


def window(path, start, end):
    with open(path) as stream:
        rows = [line.rstrip('\n').split('\t') for line in stream]
    column = {name: i for i, name in enumerate(rows[0])}
    selected = [row for row in rows[1:] if start <= float(row[column['time_s']]) < end]
    if not selected:
        raise SystemExit('no rows in window')

    def values(name, keep=lambda value: True):
        return [float(row[column[name]]) for row in selected if keep(float(row[column[name]]))]

    present = values('fps', lambda value: value >= 0)
    render = sorted(values('render_fps'))
    result = {
        'rows': len(selected), 'frames': [int(selected[0][column['frame']]), int(selected[-1][column['frame']])],
        'present_fps': statistics.mean(present) if present else None, 'present_valid_rows': len(present),
        'present_p95_ms': statistics.mean(values('p95_ms', lambda value: value > 0)) if present else None,
        'dropped': [int(selected[0][column['dropped']]), int(selected[-1][column['dropped']])],
        'render_fps': statistics.mean(render), 'render_fps_min': render[0],
        'thermal_max': max(int(row[column['thermal']]) for row in selected),
    }
    for name in ('render_p95_ms', 'gpu_ms', 'submit_cpu_ms', 'draws', 'upload_mb', 'physical_gb', 'gpu_gb'):
        result[name] = statistics.mean(values(name))
    if 'game_seconds' in column and len(selected) > 1:
        game = values('game_seconds')
        wall = values('time_s')
        if min(game) >= 0 and wall[-1] > wall[0]:
            result['game_seconds_elapsed'] = game[-1] - game[0]
            result['wall_seconds_elapsed'] = wall[-1] - wall[0]
            result['game_speed_ratio'] = (game[-1] - game[0]) / (wall[-1] - wall[0])
    return result


def distribution(values):
    values = sorted(values)
    return {'mean': statistics.mean(values), 'p50': values[len(values) // 2], 'p95': values[int(len(values) * .95)]}


def frame_window(path, first, last):
    if first < 0 or last < first:
        raise ValueError('invalid frame window')
    rows = collections.defaultdict(dict)
    with open(path) as stream:
        for line in stream:
            if line.startswith('#') or line.startswith('frame\t') or not line.strip():
                continue
            frame, name, value = line.rstrip('\n').split('\t')
            frame = int(frame)
            if first <= frame <= last:
                rows[frame][name] = float(value)
    result = {'frames': [first, last], 'expected_frames': last - first + 1, 'recorded_frames': len(rows)}
    result['missing_metrics'] = {name: last - first + 1 - sum(name in row for row in rows.values())
                                 for name in ('@frame_ms', '@presented_ms')}
    result['complete'] = len(rows) == last - first + 1 and not any(result['missing_metrics'].values())
    for name in ('@frame_ms', '@presented_ms', '@gpu_ms', '@nvn_ms', '@upload_ms', '@pso_new', '@lib_new'):
        values = sorted(row[name] for row in rows.values() if name in row and row[name] >= 0)
        if not values:
            continue
        result[name[1:]] = dict(distribution(values), count=len(values), min=values[0], max=values[-1],
                                p99=values[min(len(values) - 1, int(len(values) * .99))])
        if name in ('@frame_ms', '@presented_ms'):
            result[name[1:]]['over_16_8_ms'] = sum(value > 16.8 for value in values)
            result[name[1:]]['over_25_ms'] = sum(value > 25.01 for value in values)
    result['present_discarded'] = sum(row.get('@presented_ms', 0) < 0 for row in rows.values())
    return result


def timeline(path):
    with open(path) as stream:
        events = sorted(tuple(int(field) for field in line.split('\t')) for line in list(stream)[1:])
    submits = [event for event in events if event[2] == SUBMIT]
    commits = sorted((event for event in events if event[2] == COMMIT), key=lambda event: event[4])
    gpu = {event[4]: event for event in events if event[2] == GPU}
    render = collections.Counter(event[3] for event in submits).most_common(1)[0][0]
    frames = collections.defaultdict(list)
    for i in range(1, len(submits) - 1):
        begin, end, _, _, _, fence = submits[i]
        previous = submits[i - 1][5]
        slices = [commit for commit in commits if previous < commit[4] <= fence]
        work = [gpu[commit[4]] for commit in slices if commit[4] in gpu]
        if not work or len(work) != len(slices):
            continue
        first, last = min(event[0] for event in work), max(event[5] for event in work)
        frames['period_ms'].append((submits[i + 1][0] - begin) / 1e6)
        frames['submit_ms'].append((end - begin) / 1e6)
        frames['commits'].append(len(slices))
        frames['gpu_start_after_submit_ms'].append((first - begin) / 1e6)
        frames['gpu_busy_ms'].append(sum(event[5] - event[0] for event in work) / 1e6)
        frames['gpu_span_ms'].append((last - first) / 1e6)
        frames['next_submit_after_gpu_ms'].append((submits[i + 1][0] - last) / 1e6)
    # GPU idle because the next slice of the same frame had not been committed yet.
    starved = []
    for a, b in zip(commits, commits[1:]):
        if a[5] == b[5] and a[4] in gpu and b[4] in gpu and b[1] > gpu[a[4]][5]:
            starved.append((gpu[b[4]][0] - gpu[a[4]][5]) / 1e6)
    count = len(set(commit[5] for commit in commits))
    result = {name: distribution(values) for name, values in frames.items()}
    result['frames'] = len(frames['period_ms'])
    result['starved_ms_per_frame'] = sum(starved) / count if count else 0
    duration = (submits[-1][0] - submits[0][0]) / 1e9
    waits = collections.Counter()
    for event in events:
        if event[2] == SVC_WAIT and event[3] == render:
            waits[hex(event[4] & 0xffffffff)] += (event[1] - event[0]) / 1e9
    result['render_thread_wait_share'] = {svc: seconds / duration for svc, seconds in waits.most_common(3)}
    return result


if __name__ == '__main__':
    if len(sys.argv) == 5 and sys.argv[1] == 'window':
        report = window(sys.argv[2], float(sys.argv[3]), float(sys.argv[4]))
    elif len(sys.argv) == 3 and sys.argv[1] == 'timeline':
        report = timeline(sys.argv[2])
    elif len(sys.argv) == 5 and sys.argv[1] == 'frames':
        report = frame_window(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
    else:
        raise SystemExit(__doc__)
    print(json.dumps(report, indent=1, ensure_ascii=False))
