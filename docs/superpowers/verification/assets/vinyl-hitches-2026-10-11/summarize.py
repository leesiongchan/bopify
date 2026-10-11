import argparse, collections, hashlib, json, math, pathlib, runpy, statistics

parser = argparse.ArgumentParser()
parser.add_argument('--raw-root', type=pathlib.Path, required=True)
parser.add_argument('--frame-analyzer', type=pathlib.Path, required=True)
parser.add_argument('--output', type=pathlib.Path, required=True)
args = parser.parse_args()
load = runpy.run_path(str(args.frame_analyzer))['load']

def distribution(values):
    values = sorted(values)
    if not values:
        return {'count': 0}
    return {'count': len(values), 'median': statistics.median(values),
            'p95': values[math.ceil(.95 * len(values)) - 1], 'max': max(values)}

runs = []
for out in sorted(args.raw_root.iterdir()):
    if not (out / 'pid.txt').is_file():
        continue
    pid = int((out / 'pid.txt').read_text())
    start, end = (2, 12) if out.name == 'after-swiftui-1' else (5, 15)
    fixture_log = (out / 'fixture.log').read_text()
    row = {'run': out.name, 'pid': pid, 'trace_window_seconds': [start, end],
           'control': next(line for line in fixture_log.splitlines() if line.startswith('GPU CONTROL:')),
           'raw_export_sha256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in out.glob('*.xml') if p.name != 'toc.xml'},
           'condition': (out / 'condition.txt').read_text() if (out / 'condition.txt').exists() else None,
           'binary': json.loads((out / 'binary.json').read_text()) if (out / 'binary.json').exists() else None}
    if (out / 'cadence.json').exists():
        data = json.loads((out / 'cadence.json').read_text())
        row['cadence'] = data
        row['cpu_one_core_percent'] = data['cpu_seconds'] / data['duration_seconds'] * 100
        row['clock_gap_ms'] = {}
        for clock in ['motor', 'progress']:
            ticks = data[clock + '_ticks_seconds']
            gaps = [(b - a) * 1000 for a, b in zip(ticks, ticks[1:])]
            row['clock_gap_ms'][clock] = {**distribution(gaps), 'tick_count': len(ticks),
                                          'rate_hz': len(ticks) / data['duration_seconds'],
                                          'gaps_over_50_ms': sum(gap > 50 for gap in gaps)}
    if (out / 'hitches.xml').exists():
        hitches = [r for r in load(out / 'hitches.xml') if r.get('process_pid') == pid
                   and r['is-system'] == '0' and start * 1e9 <= int(r['start']) < end * 1e9]
        row['hitches'] = {'count': len(hitches), 'duration_ms': distribution([int(r['duration']) / 1e6 for r in hitches]),
                          'by_display': dict(collections.Counter(r['display'] for r in hitches))}
        updates = [r for r in load(out / 'hitches-updates.xml') if r.get('process_pid') == pid
                   and r['containment-level'] == '0' and start * 1e9 <= int(r['start']) < end * 1e9]
        row['updates'] = {'count': len(updates), 'by_display': dict(collections.Counter(r['display'] for r in updates)),
                          'duration_ms': distribution([int(r['duration']) / 1e6 for r in updates]),
                          'longer_than_10_ms': sum(int(r['duration']) > 10_000_000 for r in updates)}
    runs.append(row)
args.output.write_text(json.dumps({'measurement': 'CPU timeline callbacks, process CPU time, and Instruments app-associated timing; not isolated shader cost', 'runs': runs}, indent=2) + '\n')
for row in runs:
    print(row['run'], 'hitches=' + str(row.get('hitches', {}).get('count', 'not recorded')),
          'display3_updates=' + str(row.get('updates', {}).get('by_display', {}).get('Display 3', 'not recorded')))
