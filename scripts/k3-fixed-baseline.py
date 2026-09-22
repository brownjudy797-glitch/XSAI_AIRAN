"""Freeze/check the selected K3 A deployment; never commit or rebuild sources."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile

ROOT = Path('/home/ubuntu/sionna-rk')
OAI = ROOT / 'ext/openairinterface5g'
BASE = ROOT / '.baseline/k3-a-20260922'
BUILD = OAI / 'cmake_targets/phy-fixed-build-20260922'
CHECKER = ROOT / 'scripts/k3-fixed-baseline.py'
LAUNCHER = ROOT / 'scripts/run-k3-b200.sh'

def run(*args):
    return subprocess.check_output(args)

def sha(p):
    with p.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()

def check():
    m = json.loads((BASE / 'manifest.json').read_text())
    errors = []
    if (ROOT / 'ext/openairinterface5g_bak').exists():
        errors.append('B directory reappeared: ext/openairinterface5g_bak')
    for repo, head in m['heads'].items():
        if run('git', '-C', str(ROOT / repo), 'rev-parse', 'HEAD').decode().strip() != head:
            errors.append('Git HEAD changed: ' + repo)
    for filename, digest in m['sha256'].items():
        p = Path(filename)
        if not p.is_file() or sha(p) != digest:
            errors.append('File changed/missing: ' + filename)
    if errors:
        print('K3 fixed baseline FAILED\n' + '\n'.join(errors[:30]))
        return 1
    print(f"K3-A-20260922 baseline OK ({len(m['sha256'])} files); this is not a UE connectivity test.")
    return 0

def freeze():
    assert os.geteuid() == 0, 'freeze requires sudo for protected launcher'
    assert not BASE.exists(), 'refuse to overwrite frozen baseline'
    assert not (ROOT / 'ext/openairinterface5g_bak').exists()
    assert run('git', '-C', str(OAI), 'rev-parse', 'HEAD').decode().strip() == 'c6698f7dda869e0ab92e232da08d1a91385eb044'
    assert sha(BUILD / 'nr-softmodem') == 'ddb267e5fbbd030f7b28f9560e6673db2816c2ce3a1db932f4d5109581d09f7f'
    BASE.mkdir(parents=True, mode=0o700)
    shutil.copy2(LAUNCHER, BASE / 'run-k3-b200.before-guard.sh')
    original = LAUNCHER.read_text()
    assert original.count('start_gnb() {\n') == 1
    guarded = original.replace('start_gnb() {\n', 'start_gnb() {\n    python3 /home/ubuntu/sionna-rk/scripts/k3-fixed-baseline.py --check || return 1\n')
    LAUNCHER.write_text(guarded)
    try:
        run('bash', '-n', str(LAUNCHER))
        tracked = run('git', '-C', str(OAI), 'ls-files', '-z').decode().split('\0')
        source = [OAI / n for n in tracked if n and (OAI / n).is_file()]
        with tarfile.open(BASE / 'oai-tracked-working-tree.tar.gz', 'w:gz') as tar:
            for p in source:
                tar.add(p, arcname=str(p.relative_to(OAI)), recursive=False)
        (BASE / 'oai-unstaged.patch').write_bytes(run('git', '-C', str(OAI), 'diff', '--binary'))
        (BASE / 'oai-staged.patch').write_bytes(run('git', '-C', str(OAI), 'diff', '--cached', '--binary'))
        (BASE / 'oai-status.txt').write_bytes(run('git', '-C', str(OAI), 'status', '--short'))
        (BASE / 'project-unstaged.patch').write_bytes(run('git', '-C', str(ROOT), 'diff', '--binary'))
        (BASE / 'project-staged.patch').write_bytes(run('git', '-C', str(ROOT), 'diff', '--cached', '--binary'))
        files = set(source)
        critical = [LAUNCHER, CHECKER, ROOT / 'config/b200/.env', ROOT / 'config/common/gnb.sa.band78.24prbs.conf']
        critical += [ROOT / 'scripts' / n for n in ['start-cn5g-k3.sh','stop-cn5g-k3.sh','status-cn5g-k3.sh']]
        critical += [p for p in (ROOT / 'config/cn5g-k3').rglob('*') if p.is_file()]
        critical += [BUILD / 'nr-softmodem'] + list(BUILD.glob('*.so'))
        for name in ['upf','smf','amf']:
            critical.append(ROOT / f'ext/oai-cn5g-fed/component/oai-{name}/build/{name}/build/{name}')
        # Include actual shared objects from the running deployment, without
        # storing subscriber/session information or touching the database.
        pid = run('systemctl','show','k3-b200-gnb.service','-p','MainPID','--value').decode().strip()
        pids = [pid] + run('pgrep','-x','upf|smf|amf').decode().split()
        for proc in pids:
            for line in Path(f'/proc/{proc}/maps').read_text().splitlines():
                parts = line.split()
                if len(parts) >= 6 and parts[5].startswith('/') and Path(parts[5]).is_file():
                    critical.append(Path(parts[5]))
        for p in set(critical):
            assert p.is_file(), str(p)
            target = BASE / 'deployment-files' / str(p).lstrip('/')
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(p, target, follow_symlinks=True)
        files.update(critical)
        heads = {'.': run('git','-C',str(ROOT),'rev-parse','HEAD').decode().strip(),
                 'ext/openairinterface5g': run('git','-C',str(OAI),'rev-parse','HEAD').decode().strip()}
        manifest = {'baseline':'K3-A-20260922','heads':heads,
                    'status':'version frozen; UE connectivity unresolved; not a validated E2E release',
                    'sha256':{str(p):sha(p) for p in sorted(files)}}
        (BASE / 'manifest.json').write_text(json.dumps(manifest, indent=2))
        (BASE / 'runtime-service.txt').write_bytes(run('systemctl','show','k3-b200-gnb.service','-p','ExecStart','-p','AllowedCPUs','-p','Environment'))
        # Owner-only archive: config snapshots may contain local credentials.
        uid = int(run('id','-u','ubuntu').decode())
        gid = int(run('id','-g','ubuntu').decode())
        for p in [BASE] + list(BASE.rglob('*')):
            os.chown(p, uid, gid)
        assert check() == 0
        print('Frozen at ' + str(BASE))
    except BaseException:
        LAUNCHER.write_text(original)
        print('Freeze failed; original launcher restored. Preserve partial archive for inspection.')
        raise

if __name__ == '__main__':
    if sys.argv[1:] == ['--freeze']:
        freeze()
    elif sys.argv[1:] == ['--check']:
        sys.exit(check())
    else:
        sys.exit('Usage: k3-fixed-baseline.py --check | --freeze')
