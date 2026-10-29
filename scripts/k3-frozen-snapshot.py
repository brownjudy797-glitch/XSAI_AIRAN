# SPDX-License-Identifier: Apache-2.0
"""Read-only comparison of the 2026-09-22 manifest with saved snapshot and host."""

from pathlib import Path
import hashlib
import json
import sys
import tarfile

root = Path('/home/ubuntu/sionna-rk')
base = root / '.baseline/k3-a-20260922'
manifest = json.loads((base / 'manifest.json').read_text())
expected = manifest['sha256']
snapshot = base / 'deployment-files'
saved = {}
for file in snapshot.rglob('*'):
    if file.is_file():
        saved['/' + str(file.relative_to(snapshot))] = file
tar_path = base / 'oai-tracked-working-tree.tar.gz'
tar_entries = {}
oai_prefix = '/home/ubuntu/sionna-rk/ext/openairinterface5g/'
with tarfile.open(tar_path, 'r:gz') as tar:
    for member in tar:
        if member.isfile():
            name = oai_prefix + member.name
            if name in expected:
                content = tar.extractfile(member).read()
                tar_entries[name] = hashlib.sha256(content).hexdigest()

def sha(path):
    with path.open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()

snapshot_missing = []
snapshot_mismatch = []
current_mismatch = []
for name, value in expected.items():
    path = Path(name)
    if not path.is_file() or sha(path) != value:
        current_mismatch.append(name)
    if name in saved:
        got = sha(saved[name])
    else:
        got = tar_entries.get(name)
    if got is None:
        snapshot_missing.append(name)
    elif got != value:
        snapshot_mismatch.append(name)
print(json.dumps({
    'manifest_entries': len(expected),
    'deployment_files': len(saved),
    'oai_tar_matched_entries': len(tar_entries),
    'snapshot_missing': snapshot_missing[:30],
    'snapshot_missing_count': len(snapshot_missing),
    'snapshot_mismatch': snapshot_mismatch[:30],
    'snapshot_mismatch_count': len(snapshot_mismatch),
    'current_mismatch': current_mismatch,
}, indent=2))
if snapshot_missing or snapshot_mismatch:
    sys.exit(1)
