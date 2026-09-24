"""Link a non-radio probe against actual gNB objects and native OAI loader."""
from pathlib import Path
import hashlib
import json
import os
import shlex
import subprocess

root = Path(__file__).resolve().parents[1]
build = root/'.build/gnb-integration'
probe = build/'loader-probe'
probe.mkdir(exist_ok=True)
commands = []
def run(args, **kwargs):
    commands.append(args)
    (probe/'commands.json').write_text(json.dumps(commands,indent=2))
    return subprocess.run(args,cwd=build,check=True,**kwargs)

entries = json.loads((build/'compile_commands.json').read_text())
entry = next(e for e in entries if e['file'].endswith('/executables/nr-softmodem.c'))
args = shlex.split(entry['command'])
args[args.index('-o')+1] = str(probe/'probe.o')
args[-1] = str(root/'architecture/tests/test_gnb_dfts_loader.c')
run(args)
original = build/'CMakeFiles/nr-softmodem.dir/executables/nr-softmodem.c.o'
renamed = probe/'modem-main-renamed.o'
run(['objcopy','--redefine-sym','main=xsai_unused_modem_main',str(original),str(renamed)])
args = shlex.split((build/'CMakeFiles/nr-softmodem.dir/link.txt').read_text())
for i, arg in enumerate(args):
    if arg.endswith('/executables/nr-softmodem.c.o'): args[i] = str(renamed)
    if arg.startswith('-Wl,--dependency-file='): args[i] = '-Wl,--dependency-file='+str(probe/'link.d')
args[args.index('-o')+1] = str(probe/'probe')
args.append(str(probe/'probe.o'))
run(args)
env = os.environ.copy()
env['LD_LIBRARY_PATH'] = str(build)
with (probe/'run.log').open('w') as log:
    run([str(probe/'probe'),str(build/'libdfts.so')],env=env,stdout=log,stderr=subprocess.STDOUT,timeout=30)
result = {'passed':True,'scope':'native OAI loader with real gNB link objects; modem main renamed and not called; no RF start',
          'library_sha256':hashlib.sha256((build/'libdfts.so').read_bytes()).hexdigest(),
          'probe_sha256':hashlib.sha256((probe/'probe').read_bytes()).hexdigest(),
          'log':(probe/'run.log').read_text()}
(probe/'result.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result,indent=2))
