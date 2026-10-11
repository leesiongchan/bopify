import pathlib, subprocess, sys

out = pathlib.Path(sys.argv[1])
for schema in sys.argv[2:]:
    subprocess.run(['xcrun', 'xctrace', 'export', '--input', str(out / 'capture.trace'), '--xpath', '/trace-toc/run[@number="1"]/data/table[@schema="' + schema + '"]', '--output', str(out / (schema + '.xml'))], check=True, stdout=subprocess.DEVNULL)
    print('EXPORTED', out.name, schema, flush=True)
