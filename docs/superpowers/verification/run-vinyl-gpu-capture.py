"""Capture a prepared native vinyl fixture and export app/frame correlation tables."""
import argparse, os, pathlib, subprocess, time, re
parser=argparse.ArgumentParser()
parser.add_argument('--binary', required=True)
parser.add_argument('--output', required=True)
options=parser.parse_args()
binary=pathlib.Path(options.binary).resolve(strict=True)
out=pathlib.Path(options.output).resolve()
out.mkdir(parents=True, exist_ok=False)
env=os.environ.copy()
env['VINYL_PROBE_HOLD_SECONDS']='45'
with (out/'fixture.log').open('w') as log:
    app=subprocess.Popen([str(binary), str(out)],env=env,stdout=log,stderr=subprocess.STDOUT)
    try:
        deadline=time.monotonic()+25
        while 'GPU CONTROL:' not in (out/'fixture.log').read_text():
            if app.poll() is not None: raise RuntimeError('fixture exited before ready')
            if time.monotonic()>deadline: raise RuntimeError('fixture readiness timeout')
            time.sleep(.1)
        line=next(l for l in (out/'fixture.log').read_text().splitlines() if l.startswith('GPU CONTROL:'))
        if int(re.search(r'pid=(\d+)',line).group(1)) != app.pid:
            raise RuntimeError('fixture readiness PID differs from launched process')
        print(line,flush=True)
        trace=out/'capture.trace'
        subprocess.run(['xcrun','xctrace','record','--template','Animation Hitches','--all-processes','--time-limit','12s','--output',str(trace),'--no-prompt'],check=True)
        for schema in ['hitches-updates','hitches-gpu','hitches-renders','hitches','device-display-info']:
            subprocess.run(['xcrun','xctrace','export','--input',str(trace),'--xpath',f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]','--output',str(out/(schema+'.xml'))],check=True,stdout=subprocess.DEVNULL)
        (out/'pid.txt').write_text(str(app.pid))
    finally:
        app.terminate()
        try: app.wait(timeout=5)
        except subprocess.TimeoutExpired:
            app.kill(); app.wait()
