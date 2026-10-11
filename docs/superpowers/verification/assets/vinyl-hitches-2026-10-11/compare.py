import os, pathlib, subprocess, sys, time, re, hashlib, json

base = pathlib.Path(__file__).resolve().parent
variant, mode, name = sys.argv[1:4]
out = base / name
out.mkdir(exist_ok=False)
binary = base / (variant + '-fixture') / 'MonolithProbe.app/Contents/MacOS/MonolithProbe'
env = os.environ.copy()
env['VINYL_PROBE_HOLD_SECONDS'] = '45'
if len(sys.argv) > 4:
    if variant == 'minimal':
        assert sys.argv[4] in ('swiftui30', 'swiftui60', 'appkit30')
        env['HITCH_MINIMAL_MODE'] = sys.argv[4]
        if len(sys.argv) > 5:
            assert sys.argv[5] == 'accessory'
            env['HITCH_MINIMAL_ACCESSORY'] = '1'
    elif variant == 'activation':
        assert sys.argv[4] in ('regular', 'accessory')
        if sys.argv[4] == 'accessory':
            env['HITCH_ACCESSORY'] = '1'
    elif variant == 'visibility':
        assert sys.argv[4] in ('normal', 'floating')
        env['HITCH_ACCESSORY'] = '1'
        if sys.argv[4] == 'floating':
            env['HITCH_FLOATING'] = '1'
    else:
        assert sys.argv[4] in ('progress', 'motor')
        env['HITCH_FREEZE_' + sys.argv[4].upper()] = '1'
(out / 'condition.txt').write_text('variant=' + variant + '\nmode=' + mode + '\noption=' + (sys.argv[4] if len(sys.argv) > 4 else 'none') + '\naccessory=' + str(len(sys.argv) > 5) + '\n')
(out / 'binary.json').write_text(json.dumps({'sha256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'path': str(binary)}, indent=2))
with (out / 'fixture.log').open('w') as log:
    app = subprocess.Popen([str(binary), str(out)], env=env, stdout=log, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 25
        while 'GPU CONTROL:' not in (out / 'fixture.log').read_text():
            if app.poll() is not None:
                raise RuntimeError('fixture exited before readiness')
            if time.monotonic() > deadline:
                raise RuntimeError('readiness timeout')
            time.sleep(.1)
        control = next(line for line in (out / 'fixture.log').read_text().splitlines() if line.startswith('GPU CONTROL:'))
        assert int(re.search(r'pid=(\d+)', control).group(1)) == app.pid
        print(control, flush=True)
        (out / 'pid.txt').write_text(str(app.pid))
        if mode != 'none':
            command = ['xcrun', 'xctrace', 'record', '--template', {'cpu': 'Time Profiler', 'swiftui': 'SwiftUI', 'system': 'Animation Hitches', 'scheduler': 'System Trace'}[mode]]
            if mode == 'scheduler':
                command += ['--instrument', 'Hitches']
            command += ['--all-processes'] if mode == 'system' else ['--attach', str(app.pid)]
            command += ['--time-limit', '20s', '--output', str(out / 'capture.trace'), '--no-prompt']
            subprocess.run(command, check=True)
        deadline = time.monotonic() + 25
        while not (out / 'cadence.json').exists():
            if app.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError('cadence report missing')
            time.sleep(.1)
        print('CADENCE:', out / 'cadence.json', flush=True)
    finally:
        app.terminate()
        try:
            app.wait(timeout=5)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()
