"""Summarise where GPU time goes in a Metal System Trace of the game.

Record:  xcrun xctrace record --template 'Metal System Trace' --attach <pid> --time-limit 3s --output run.trace
Report:  work/venv/bin/python script/metal_trace_report.py run.trace [process-name-substring]

Prints JSON: per-channel execution, idle time inside command buffers (between encoders and between the vertex and
fragment phases of one render pass), and transition costs by encoder kind. Command-buffer spans (the gpu_ms column of
performance.tsv) include this idle time; encoder execution does not.
"""
import collections
import json
import subprocess
import sys
import xml.etree.ElementTree as ET

TABLE = '/trace-toc/run[@number="1"]/data/table[@schema="metal-gpu-intervals"]'
FIELDS = {'start': 'start', 'duration': 'duration', 'channel-name': 'channel', 'event-depth': 'depth',
          'process': 'process', 'cmdbuffer-id': 'buffer', 'encoder-id': 'encoder'}


def intervals(trace, process):
    exported = subprocess.run(['xcrun', 'xctrace', 'export', '--input', trace, '--xpath', TABLE],
                              capture_output=True, check=True).stdout
    values, columns, rows = {}, [], []

    def value(element):
        if element.get('ref') is not None:
            return values[element.get('ref')]
        for child in element.iter():
            if child.get('id') is not None and child.get('id') not in values:
                values[child.get('id')] = ((child.text or '').strip(), child.get('fmt'))
        return (element.text or '').strip(), element.get('fmt')
    for _, element in ET.iterparse(__import__('io').BytesIO(exported)):
        if element.tag == 'schema':
            columns = [c.findtext('mnemonic') for c in element.findall('col')]
        elif element.tag == 'row':
            record = {}
            for name, child in zip(columns, element):
                text, fmt = value(child)   # every column may define ids that later rows refer to
                if name in FIELDS:
                    record[FIELDS[name]] = fmt if name == 'process' else text
            element.clear()
            if record.get('depth') == '0' and process in (record.get('process') or ''):
                rows.append((int(record['start']), int(record['start']) + int(record['duration']), record['channel'],
                             record['buffer'], record['encoder']))
    return sorted(rows)


def report(rows):
    if not rows:
        raise SystemExit('no GPU intervals for that process')
    seconds = (rows[-1][1] - rows[0][0]) / 1e9
    busy = gap_same = gap_other = 0
    start, end, buffer = rows[0][0], rows[0][1], rows[0][3]
    for s, e, _, b, _ in rows[1:]:
        if s > end:
            busy += end - start
            if b == buffer: gap_same += s - end
            else: gap_other += s - end
            start = s
        end = max(end, e); buffer = b
    busy += end - start
    encoders = collections.OrderedDict()
    for s, e, channel, b, encoder in rows:
        encoders.setdefault(encoder, {'buffer': b, 'spans': []})['spans'].append((s, e, channel))
    kinds = lambda e: 'compute' if {c for _, _, c in e['spans']} == {'Compute'} else 'render'
    transitions = collections.defaultdict(lambda: [0, 0])
    listed = list(encoders.values())
    for a, b in zip(listed, listed[1:]):
        if a['buffer'] != b['buffer']: continue
        gap = max(0, min(s for s, _, _ in b['spans']) - max(e for _, e, _ in a['spans']))
        key = kinds(a) + '>' + kinds(b); transitions[key][0] += 1; transitions[key][1] += gap
    vertex_fragment = [min(s for s, _, c in e['spans'] if c == 'Fragment') - max(x for _, x, c in e['spans'] if c == 'Vertex')
                       for e in listed if {'Vertex', 'Fragment'} <= {c for _, _, c in e['spans']}]
    channel = collections.Counter()
    for s, e, c, _, _ in rows: channel[c] += e - s
    per_second = lambda ns: round(ns / 1e6 / seconds, 1)
    return {
        'seconds': round(seconds, 3), 'encoders_per_second': round(len(listed) / seconds),
        'execution_ms_per_s': {c: per_second(v) for c, v in channel.items()},
        'busy_ms_per_s': per_second(busy),
        'idle_inside_command_buffers_ms_per_s': per_second(gap_same),
        'idle_between_command_buffers_ms_per_s': per_second(gap_other),
        'vertex_to_fragment_idle_ms_per_s': per_second(sum(g for g in vertex_fragment if g > 0)),
        'vertex_to_fragment_mean_us': round(sum(g for g in vertex_fragment if g > 0) / max(1, len(vertex_fragment)) / 1e3, 1),
        'transitions': {k: {'count_per_s': round(n / seconds), 'idle_ms_per_s': per_second(g),
                            'mean_us': round(g / max(1, n) / 1e3, 1)} for k, (n, g) in sorted(transitions.items())},
    }


if __name__ == '__main__':
    if len(sys.argv) not in (2, 3):
        raise SystemExit(__doc__)
    print(json.dumps(report(intervals(sys.argv[1], sys.argv[2] if len(sys.argv) == 3 else 'zelda_probe')), indent=1, ensure_ascii=False))
