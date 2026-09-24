"""Bridge the fresh CMake DFT artifact to the previously verified numeric module."""
from pathlib import Path
import hashlib
import json
import resource
import subprocess

root = Path(__file__).resolve().parents[1]
build = root/'.build/gnb-integration'
out = build/'dfts-regression'
out.mkdir(exist_ok=True)
prior = json.loads((root/'docs/validation/dfts-correctness-result.json').read_text())
runner = root/'.build/dfts-module/runner'
rows = []
def limits():
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
for direction,kind in enumerate(('DFT','IDFT')):
    for index,row in enumerate(r for r in prior['sizes'] if r['direction']==kind):
        prefix=out/f'{kind}-{row["size"]}'
        with prefix.with_suffix('.log').open('w') as log:
            p=subprocess.run([str(runner),str(build/'libdfts.so'),str(prefix.with_suffix('.bin')),str(direction),str(index)],
                             stdout=log,stderr=subprocess.STDOUT,timeout=30,preexec_fn=limits)
        digest=hashlib.sha256(prefix.with_suffix('.bin').read_bytes()).hexdigest() if p.returncode==0 else None
        passed=p.returncode==0 and digest==row['runs'][0]['sha256'] and 'ZERO_ANOMALY' not in prefix.with_suffix('.log').read_text()
        rows.append({'direction':kind,'size':row['size'],'passed':passed,'returncode':p.returncode,'sha256':digest})
result={'library_sha256':hashlib.sha256((build/'libdfts.so').read_bytes()).hexdigest(),
        'method':'Fresh CMake library versus independently audited isolated module; zero/impulse/random-small/random-full, scale 0/1; output canaries; exact binary hash comparison',
        'summary':{'sizes':len(rows),'passed':sum(r['passed'] for r in rows),'cases':8*len(rows)},'sizes':rows}
(out/'result.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result['summary']))
raise SystemExit(0 if all(r['passed'] for r in rows) else 1)
