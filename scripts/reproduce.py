#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Prepare and build an isolated, source-locked traditional OAI RFsim workspace."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys

REPO = Path(__file__).resolve().parents[1]
PROFILE = REPO / 'config/repro/20261029.json'
LOCK = json.loads(PROFILE.read_text(encoding='utf-8'))
MARKER = '.xsai-repro.json'

def run(args, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, **kwargs)

def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(1048576), b''): h.update(block)
    return h.hexdigest()

def safe_workspace(value):
    path = Path(value).expanduser().resolve()
    live = Path.home() / 'sionna-rk'
    if path == Path.home() or path == live or live in path.parents or path == REPO or REPO in path.parents:
        raise ValueError('Choose a NEW workspace outside both the published checkout and ~/sionna-rk.')
    return path

def state(work):
    data = json.loads((work / MARKER).read_text(encoding='utf-8'))
    if data['profileSha256'] != sha(PROFILE):
        raise ValueError('Workspace profile differs from this checkout; do not mix versions.')
    return data

def verify_source_files():
    """Compare with pinned Git blobs, allowing only declared text CRLF/LF conversion.

    Historic blobs include CRLF while .gitattributes requires LF, so a fresh
    Linux checkout can report a dirty diff without an actual source edit.
    """
    listing = subprocess.check_output(['git','-C',str(REPO),'ls-tree','-r','-z','HEAD','--','vendor/openairinterface5g','plugins'])
    entries = []
    for record in listing.split(b'\0'):
        if not record: continue
        header, path = record.split(b'\t', 1)
        mode, kind, obj = header.split()
        if kind != b'blob': continue
        entries.append((mode, obj, os.fsdecode(path)))
    blobs = subprocess.check_output(['git','-C',str(REPO),'cat-file','--batch'], input=b''.join(obj+b'\n' for _,obj,_ in entries))
    offset = 0
    for mode, obj, relative in entries:
        end = blobs.index(b'\n', offset)
        length = int(blobs[offset:end].split()[2]); offset = end+1
        expected = blobs[offset:offset+length]; offset += length+1
        path = REPO / relative
        if mode == b'120000':
            if not path.is_symlink(): raise ValueError('Source symlink changed: '+relative)
            actual = os.fsencode(os.readlink(path))
        else:
            if path.is_symlink() or not path.is_file(): raise ValueError('Source file missing or replaced: '+relative)
            actual = path.read_bytes()
        if path.suffix in ('.c','.cpp','.h','.py','.sh','.md','.patch') and b'\0' not in expected:
            actual, expected = actual.replace(b'\r\n',b'\n'), expected.replace(b'\r\n',b'\n')
        if actual != expected: raise ValueError('Uncommitted source change: '+relative)

def prepare(work):
    if work.exists():
        state(work)
        print('Existing workspace retained; no source recopied: ' + str(work))
        return
    for directory, key in [('vendor/openairinterface5g', 'vendorTree'), ('plugins', 'pluginTree')]:
        tree = subprocess.check_output(['git', '-C', str(REPO), 'rev-parse', 'HEAD:' + directory], text=True).strip()
        if tree != LOCK[key]: raise ValueError('Published source tree changed; select a matching profile: ' + directory)
    verify_source_files()
    work.mkdir(parents=True, exist_ok=False)
    # Mark creation before copying. An incomplete workspace is preserved, never reset.
    data = {'profile': LOCK['profile'], 'profileSha256': sha(PROFILE), 'repositoryCommit':
            subprocess.check_output(['git','-C',str(REPO),'rev-parse','HEAD'], text=True).strip(),
            'prepared': False, 'createdUtc': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    (work / MARKER).write_text(json.dumps(data, indent=2), encoding='utf-8')
    run(['bash', REPO / 'scripts/prepare-oai-worktree.sh', work / 'oai'])
    run(['git', '-C', work / 'oai', 'apply', '--check', REPO / LOCK['oaiOverlay']])
    run(['git', '-C', work / 'oai', 'apply', REPO / LOCK['oaiOverlay']])
    data['prepared'] = True
    (work / MARKER).write_text(json.dumps(data, indent=2), encoding='utf-8')
    print('Prepared isolated source: ' + str(work))

def build(work, jobs):
    data = state(work)
    if not data['prepared']: raise ValueError('Preparation was incomplete; inspect the workspace.')
    asn = work / 'deps/asn1c/bin/asn1c'
    simde = work / 'deps/include'
    if not asn.is_file() or not (simde / 'simde/simde-common.h').is_file():
        raise ValueError('Run repro-deps.sh tools WORKSPACE first; system ASN1C/SIMDe are not silently reused.')
    flags = '-I' + str(simde)
    cc, cxx = 'cc', 'c++'
    if platform.machine() == 'riscv64':
        cc, cxx = 'gcc-16', 'g++-16'
        flags += ' ' + LOCK['riscvCFlags']
    for command in [cc, cxx, 'cmake', 'ninja']:
        if not shutil.which(command): raise ValueError('Missing build tool: ' + command)
    cache = work / 'build/CMakeCache.txt'
    if cache.exists():
        entries = dict(line.split('=',1) for line in cache.read_text().splitlines() if '=' in line and not line.startswith(('#','//')))
        for key, compiler in [('CMAKE_C_COMPILER',cc),('CMAKE_CXX_COMPILER',cxx)]:
            saved = next((value for name,value in entries.items() if name.split(':')[0] == key),None)
            selected = str(Path(shutil.which(compiler)).resolve())
            if saved and saved != selected:
                raise ValueError('Compiler changed in existing CMake cache; preserve this workspace and prepare a new one.')
    args = ['cmake', '-S', work / 'oai', '-B', work / 'build', '-G', 'Ninja',
            '-DCMAKE_BUILD_TYPE=RelWithDebInfo', '-DASN1C_EXEC=' + str(asn),
            '-DCMAKE_C_COMPILER=' + str(Path(shutil.which(cc)).resolve()),
            '-DCMAKE_CXX_COMPILER=' + str(Path(shutil.which(cxx)).resolve()),
            '-DCMAKE_C_FLAGS=' + flags, '-DCMAKE_CXX_FLAGS=' + flags,
            '-DENABLE_PLUGINS=ON', '-DENABLE_CUDA=OFF', '-DENABLE_DGX_OPTIMIZATIONS=OFF',
            '-DOAI_SIMU=ON', '-DOAI_USRP=OFF']
    if platform.machine() == 'riscv64': args += ['-DAVX2=OFF', '-DAVX512=OFF']
    (work / 'configure-command.json').write_text(json.dumps(list(map(str, args)), indent=2), encoding='utf-8')
    run(args)
    entries = dict(line.split('=',1) for line in cache.read_text().splitlines() if '=' in line and not line.startswith(('#','//')))
    actual_asn = next((v for k,v in entries.items() if k.split(':')[0] == 'ASN1C_EXEC'), '')
    actual_flags = next((v for k,v in entries.items() if k.split(':')[0] == 'CMAKE_C_FLAGS'), '')
    if actual_asn != str(asn) or str(simde) not in actual_flags:
        raise ValueError('CMake did not retain private dependencies; inspect the cache before building.')
    run(['cmake', '--build', work / 'build', '--target', *LOCK['targets'], '-j', str(jobs)])
    check(work)

def check(work):
    data = state(work)
    if not data.get('prepared'): raise ValueError('Workspace source is incomplete.')
    artifacts = []
    for name in ['nr-softmodem', 'nr-uesoftmodem', *LOCK['requiredLibraries']]:
        path = work / 'build' / name
        if not path.is_file(): raise ValueError('Missing build output: ' + str(path))
        output = subprocess.check_output(['ldd', str(path)], text=True)
        if 'not found' in output: raise ValueError('Missing runtime dependency: ' + output)
        artifacts.append({'path': 'build/' + name, 'sha256': sha(path)})
    report = {'profile': LOCK['profile'], 'workspace': data, 'artifacts': artifacts,
              'kernel': platform.release(), 'architecture': platform.machine(),
              'checkedUtc': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    command_file = work / 'configure-command.json'
    if command_file.is_file(): report['configureCommand'] = json.loads(command_file.read_text())
    report['compilerVersions'] = {}
    for compiler in (['gcc-16','g++-16'] if platform.machine()=='riscv64' else ['cc','c++']):
        report['compilerVersions'][compiler] = subprocess.check_output([compiler,'--version'],text=True).splitlines()[0]
    (work / 'build-manifest.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print('Build outputs and dynamic dependencies verified; no RFsim process started.')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'build', 'check'])
    parser.add_argument('--workspace', required=True)
    parser.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args()
    if args.jobs < 1 or args.jobs > 16: parser.error('--jobs must be between 1 and 16')
    work = safe_workspace(args.workspace)
    {'prepare': lambda: prepare(work), 'build': lambda: build(work, args.jobs), 'check': lambda: check(work)}[args.action]()

if __name__ == '__main__':
    try: main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print('ERROR: ' + str(error), file=sys.stderr)
        sys.exit(1)
