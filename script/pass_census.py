#!/usr/bin/env python3
"""Render-pass census of one frame from a DM_NVN_PASSDUMP log (best with DM_NVN_PASSDUMP_ALL=1 for per-draw lines).

Classifies each pass: clear-only, fullscreen single draw (no blend on written targets, no depth/stencil test, one
color target, viewport covering the target), or other. Consecutive fullscreen single-draw passes form runs; a run is
what a compute conversion could chain in one encoder. Prints counts by class, by fragment shader and by run length.

usage: pass_census.py LOG [--frame N] [--passes]
"""
import argparse
import collections
import re
import sys

LINE = re.compile(r'^\[pass\] F(\d+) (\S) (.*)$')


class Pass:
    def __init__(self, pid):
        self.id, self.att, self.draws, self.first, self.keys, self.samples = pid, [], 0, None, {}, []
        self.ended_by_copy = False
        self.compute_before = 0

    def kind(self):
        if not self.first:
            return 'clear-only' if self.att else 'empty'
        colors = [a for a in self.att if a['slot'].startswith('c')]
        depth = [a for a in self.att if not a['slot'].startswith('c')]
        f = self.first
        tgt = f['tgt']
        full = f['vp'][:2] == (0, 0) and f['vp'][2:] == tgt and f['sc'] == (0, 0) + tgt
        blend = any(f['blend'] >> int(a['slot'][1:]) & 1 for a in colors)
        if self.draws == 1 and f['vc'] in (3, 4, 6) and full and not blend and not depth and f['dt'] == 0 and f['st'] == 0:
            return 'fs1' if len(colors) == 1 else 'fs1-mrt'
        return 'draw'


def parse(path, frame):
    passes, order, events = {}, [], []
    want = None
    with open(path, errors='replace') as fh:
        for raw in fh:
            m = LINE.match(raw)
            if not m:
                continue
            f, t, rest = int(m.group(1)), m.group(2), m.group(3)
            if want is None:
                want = frame if frame is not None else f
            if f != want:
                if f > want:
                    break
                continue
            parts = rest.split()
            pid = int(parts[0]) if parts and parts[0].isdigit() else None

            def get(pid):
                if pid not in passes:
                    passes[pid] = Pass(pid)
                    order.append(pid)
                    events.append(('pass', pid))
                return passes[pid]

            if t == 'P' and pid is not None:
                p = get(pid)
                size = next(x for x in parts if re.match(r'^\d+x\d+$', x))
                fmt = next((x[4:] for x in parts if x.startswith('fmt=')), '?')
                p.att.append(dict(slot=parts[1], fmt=fmt, size=tuple(map(int, size.split('x'))), load=parts[-1]))
            elif t == 'D' and pid is not None:
                p = get(pid)
                kv = dict(x.split('=', 1) for x in parts[1:] if '=' in x)
                p.first = dict(vc=int(kv['vc']), blend=int(kv['blend'], 16), dt=int(kv['dt']), st=int(kv['st']),
                               tgt=tuple(map(int, kv['tgt'].split('x'))), sc=tuple(map(int, kv['sc'].split(','))),
                               vp=tuple(int(float(v)) for v in kv['vp'].split(',')))
            elif t == 'd' and pid is not None:
                get(pid).draws += 1
            elif t == 'K' and pid is not None:
                get(pid).keys.setdefault(parts[1], parts[2].split('=', 1)[1])
            elif t == 'R' and pid is not None:
                get(pid).samples.append(parts[2])
            elif t == 'E' and pid is not None and pid in passes:
                passes[pid].ended_by_copy = True
            elif t == 'b':
                events.append(('compute', pid))
    return want, [passes[p] for p in order], events


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('log')
    ap.add_argument('--frame', type=int)
    ap.add_argument('--passes', action='store_true', help='print one line per pass')
    a = ap.parse_args()
    frame, passes, events = parse(a.log, a.frame)
    if not passes:
        sys.exit('no passes in log')
    by = {p.id: p for p in passes}
    kinds = collections.Counter(p.kind() for p in passes)
    print(f'frame {frame}: {len(passes)} passes, draws {sum(p.draws for p in passes)}, '
          f'copy/compute encoders opened {sum(1 for e in events if e[0] == "compute")}')
    for k, n in kinds.most_common():
        print(f'  {k:11s} {n}')
    # Runs of consecutive fs1 passes (a copy/compute encoder between them does not break a compute run).
    runs, cur = [], []
    for kind, pid in events:
        if kind == 'compute':
            continue
        if by[pid].kind() == 'fs1':
            cur.append(by[pid])
        else:
            if cur:
                runs.append(cur)
            cur = []
    if cur:
        runs.append(cur)
    hist = collections.Counter(len(r) for r in runs)
    print('fs1 runs (length: count):', ', '.join(f'{n}:{c}' for n, c in sorted(hist.items())))
    print('fs1 passes in runs >= 2:', sum(len(r) for r in runs if len(r) >= 2), ' >= 4:', sum(len(r) for r in runs if len(r) >= 4))
    fs = collections.Counter(p.keys.get('st1', '-') for p in passes if p.kind() == 'fs1')
    print('fs1 fragment shaders:', len(fs))
    for key, n in fs.most_common(20):
        print(f'  {n:3d} {key}')
    sizes = collections.Counter('%dx%d/%s' % (p.att[0]['size'] + (p.att[0]['fmt'],)) for p in passes if p.kind() == 'fs1')
    print('fs1 target size/format:', ', '.join(f'{k}:{n}' for k, n in sizes.most_common(16)))
    if a.passes:
        for kind, pid in events:
            if kind == 'compute':
                print('   -- copy/compute encoder')
                continue
            p = by[pid]
            att = ' '.join('%s:%dx%d/%s/%s' % (x['slot'], *x['size'], x['fmt'], x['load']) for x in p.att)
            print(f'{p.id} {p.kind():10s} draws={p.draws:3d} fs={p.keys.get("st1", "-")[:16]} {att} samples={len(p.samples)}')


if __name__ == '__main__':
    main()
