#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Copy rolling CN5G logs to a new private archive before a launcher rewrites them."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import uuid

def archive(root):
    root=Path(root).expanduser().resolve()
    logs=root/'logs/cn5g-k3'
    if not logs.exists(): return None
    if logs.is_symlink() or root not in logs.resolve().parents:
        raise ValueError('Log directory must stay inside the project')
    sources=[]
    for name in ['amf.log','smf.log','upf.log','gnb.log','nrue.log']:
        source=logs/name
        if source.is_symlink(): raise ValueError('Refusing a log symlink: '+name)
        if source.is_file(): sources.append(source)
    if not sources: return None
    parent=logs/'history'
    if parent.is_symlink(): raise ValueError('Refusing an archive-directory symlink')
    parent.mkdir(exist_ok=True)
    target=parent/(datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+uuid.uuid4().hex[:8])
    target.mkdir(mode=0o700)
    records=[]
    for source in sources:
        before=source.stat();dest=target/source.name
        shutil.copyfile(source,dest);os.chmod(dest,0o600)
        after=source.stat()
        records.append({'file':source.name,'bytes':dest.stat().st_size,
                        'sha256':hashlib.sha256(dest.read_bytes()).hexdigest(),
                        'sourceChangedDuringCopy':(before.st_size,before.st_mtime_ns)!=(after.st_size,after.st_mtime_ns)})
    manifest=target/'manifest.json'
    manifest.write_text(json.dumps({'files':records,'note':'A copy of rolling logs; active writers can change during capture. Nothing removed.'},indent=2))
    os.chmod(manifest,0o600)
    return target

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',default=str(Path.home()/'sionna-rk'))
    args=parser.parse_args()
    result=archive(args.root)
    print('Archived rolling logs: '+str(result) if result else 'No rolling logs to archive.')
