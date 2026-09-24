"""Regression gate after correctness repairs; uses the full-module runner."""
from pathlib import Path
import hashlib
import json
import resource
import subprocess

root = Path(__file__).resolve().parents[1]
build = root / '.build/dfts-module'
old = json.loads((root / 'docs/validation/dfts-module-result.json').read_text())
output = root / '.build/dfts-correctness'
output.mkdir(exist_ok=True)
rows = []
def limits():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
for direction, kind in enumerate(('DFT', 'IDFT')):
    selected = [r for r in old['sizes'] if r['direction'] == kind]
    for index, prior in enumerate(selected):
        runs = []
        for repeat in range(3):
            prefix = output / f'{kind}-{prior["size"]}-{repeat}'
            binary = prefix.with_suffix('.bin')
            with prefix.with_suffix('.log').open('w') as log:
                try:
                    rc = subprocess.run([str(build/'runner'), str(build/'libdfts.so'),
                        str(binary), str(direction), str(index)], stdout=log,
                        stderr=subprocess.STDOUT, timeout=30, preexec_fn=limits).returncode
                except subprocess.TimeoutExpired:
                    rc = 124
            logtext = prefix.with_suffix('.log').read_text()
            runs.append({'returncode': rc, 'sha256': hashlib.sha256(binary.read_bytes()).hexdigest() if rc == 0 else None,
                         'zero_anomaly': 'ZERO_ANOMALY' in logtext})
        expected_change = kind == 'DFT' and (prior['size'] in (2304, 98304) or bool(prior['runs']['migrated']['zero_anomalies']))
        stable = all(r['returncode'] == 0 and not r['zero_anomaly'] for r in runs) and len({r['sha256'] for r in runs}) == 1
        unchanged = runs[0]['sha256'] == prior['runs']['migrated']['sha256']
        passed = stable and (expected_change or unchanged)
        rows.append({'direction': kind, 'size': prior['size'], 'runs': runs,
                     'expected_change': expected_change, 'unchanged': unchanged, 'passed': passed})
        print(kind, prior['size'], 'PASS' if passed else 'FAIL', flush=True)
result = {'scope': 'Full-module safety/zero/determinism regression, not a floating-point accuracy certification',
          'library_sha256': hashlib.sha256((build/'libdfts.so').read_bytes()).hexdigest(),
          'sizes': rows, 'summary': {'sizes': len(rows), 'passed': sum(r['passed'] for r in rows),
          'cases': len(rows)*8*3}}
(output/'result.json').write_text(json.dumps(result, indent=2))
print(json.dumps(result['summary']))
raise SystemExit(0 if all(r['passed'] for r in rows) else 1)
