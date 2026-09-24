"""Build isolated integration artifacts only; never install or launch a modem."""
from pathlib import Path
import hashlib
import json
import subprocess
import time

root = Path(__file__).resolve().parents[1]
build = root / '.build/gnb-integration'
assert (build/'CMakeCache.txt').exists(), 'Configure the isolated tree first'
command = ['nice','-n','15','cmake','--build',str(build),'--target',
           'nr-softmodem','dfts','params_libconfig','--parallel','4']
result = {'command':command,'started':time.time(),'scope':'build only; no install or RF/modem launch'}
(build/'integration-build.json').write_text(json.dumps(result,indent=2))
with (build/'integration-build.log').open('w') as log:
    rc = subprocess.run(command,stdout=log,stderr=subprocess.STDOUT).returncode
result.update(returncode=rc,elapsed_seconds=time.time()-result['started'])
result['artifacts'] = {name:hashlib.sha256((build/name).read_bytes()).hexdigest()
                       for name in ['nr-softmodem','libdfts.so','libparams_libconfig.so']
                       if (build/name).is_file()}
(build/'integration-build.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result,indent=2))
raise SystemExit(rc)
