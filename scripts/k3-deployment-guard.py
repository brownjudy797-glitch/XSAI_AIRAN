# SPDX-License-Identifier: Apache-2.0
"""Verify the selected K3 B200 deployment without rewriting historic baselines."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import stat
import sys

ROOT = Path('/home/ubuntu/sionna-rk')
BASE = ROOT / '.baseline/k3-deployment-20261017'
MANIFEST = BASE / 'manifest.json'
GNBCONFIG = ROOT / 'config/b200/.env'


def sha(path: Path) -> str:
    with path.open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()


def selected_build() -> Path:
    text = GNBCONFIG.read_text()
    found = re.findall(r'^K3_GNB_BUILD=(.*)$', text, flags=re.MULTILINE)
    if len(found) != 1:
        raise ValueError('Expected one K3_GNB_BUILD entry in config/b200/.env')
    value = found[0].strip().strip('"\'')
    build = Path(value)
    if not build.is_absolute() or ROOT not in build.parents:
        raise ValueError('K3_GNB_BUILD must be an absolute path inside the project')
    return build


def collect() -> tuple[list[Path], dict[str, str]]:
    build = selected_build()
    cn = ROOT / 'ext/oai-cn5g-fed'
    amf = ROOT / '.runtime/cn5g-selected/amf'
    if not os.access(amf, os.X_OK):
        amf = cn / 'component/oai-amf/build/amf/build/amf'
    files = [
        ROOT / 'scripts/k3-deployment-guard.py',
        ROOT / 'scripts/run-k3-b200.sh',
        ROOT / 'scripts/start-cn5g-k3.sh',
        ROOT / 'scripts/stop-cn5g-k3.sh',
        ROOT / 'scripts/status-cn5g-k3.sh',
        GNBCONFIG,
        ROOT / 'config/common/gnb.sa.band78.24prbs.conf',
        build / 'nr-softmodem',
        amf,
        cn / 'component/oai-smf/build/smf/build/smf',
        cn / 'component/oai-upf/build/upf/build/upf',
    ]
    files.extend(sorted(build.glob('*.so')))
    files.extend(sorted(p for p in (ROOT / 'config/cn5g-k3').rglob('*') if p.is_file()))
    files = sorted(set(files), key=str)
    for path in files:
        if not path.is_file():
            raise FileNotFoundError(path)
    required_executables = {
        ROOT / 'scripts/run-k3-b200.sh',
        ROOT / 'scripts/start-cn5g-k3.sh',
        ROOT / 'scripts/stop-cn5g-k3.sh',
        ROOT / 'scripts/status-cn5g-k3.sh',
        build / 'nr-softmodem',
        amf,
        cn / 'component/oai-smf/build/smf/build/smf',
        cn / 'component/oai-upf/build/upf/build/upf',
    }
    for path in required_executables:
        if not os.access(path, os.X_OK):
            raise PermissionError(f'Deployment executable lacks execute permission: {path}')
    return files, {'gnb_build': str(build), 'amf_binary': str(amf)}


def snapshot_target(path: Path) -> Path:
    return BASE / 'deployment-files' / str(path).lstrip('/')


def capture() -> int:
    if BASE.exists():
        raise FileExistsError(f'Refuse to replace {BASE}')
    files, selection = collect()
    BASE.mkdir(mode=0o700)
    try:
        records = {}
        for path in files:
            dest = snapshot_target(path)
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, dest, follow_symlinks=True)
            digest = sha(path)
            if sha(dest) != digest:
                raise IOError(f'Snapshot copy mismatch: {path}')
            records[str(path)] = {
                'sha256': digest,
                'realpath': str(path.resolve()),
                'mode': stat.S_IMODE(path.stat().st_mode),
            }
        manifest = {
            'name': 'K3 deployment snapshot 2026-10-17',
            'status': 'project-owned runtime artifact integrity; not a UE connectivity or throughput result',
            'selection': selection,
            'files': records,
        }
        MANIFEST.write_text(json.dumps(manifest, indent=2) + '\n')
        os.chmod(MANIFEST, 0o600)
        # The launcher is root-owned; the project operator still needs to read
        # the owner-only snapshot when the start command checks it.
        user = pwd.getpwnam('ubuntu')
        for item in [BASE] + list(BASE.rglob('*')):
            os.chown(item, user.pw_uid, user.pw_gid)
        return check_snapshot()
    except BaseException:
        print(f'Capture incomplete. Preserve {BASE} for inspection; never overwrite it automatically.', file=sys.stderr)
        raise


def check_snapshot() -> int:
    manifest = json.loads(MANIFEST.read_text())
    errors = []
    for name, record in manifest['files'].items():
        path = snapshot_target(Path(name))
        if (not path.is_file() or sha(path) != record['sha256']
                or stat.S_IMODE(path.stat().st_mode) != record['mode']):
            errors.append(name)
    if errors:
        print('K3 deployment snapshot FAILED: ' + ', '.join(errors[:12]))
        return 1
    print(f'K3 deployment snapshot OK ({len(manifest["files"])} files)')
    return 0


def check_current() -> int:
    manifest = json.loads(MANIFEST.read_text())
    files, selection = collect()
    errors = []
    if selection != manifest['selection']:
        errors.append('Selected gNB build or AMF binary changed')
    if {str(path) for path in files} != set(manifest['files']):
        errors.append('Deployment file set changed')
    for name, record in manifest['files'].items():
        path = Path(name)
        if (not path.is_file() or sha(path) != record['sha256']
                or str(path.resolve()) != record['realpath']
                or stat.S_IMODE(path.stat().st_mode) != record['mode']):
            errors.append('Changed or missing: ' + name)
    if errors:
        print('K3 current deployment FAILED\n' + '\n'.join(errors[:30]))
        return 1
    print(f'K3 current deployment OK ({len(manifest["files"])} files); UE connectivity not checked.')
    return 0


if __name__ == '__main__':
    try:
        if sys.argv[1:] == ['--capture']:
            raise SystemExit(capture())
        if sys.argv[1:] == ['--check-snapshot']:
            raise SystemExit(check_snapshot())
        if sys.argv[1:] == ['--check']:
            raise SystemExit(check_current())
        raise SystemExit('Usage: --capture | --check-snapshot | --check')
    except (OSError, ValueError, KeyError) as exc:
        raise SystemExit(f'K3 deployment guard ERROR: {exc}')
