#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Run source-locked RFsim in an owned network namespace; never kill by name."""
import argparse
import csv
import fcntl
import datetime
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import uuid
from reproduce import LOCK, REPO, safe_workspace, state, sha

AWGN = '''
channelmod = {
  max_chan = 10;
  modellist = "modellist_rfsimu_1";
  modellist_rfsimu_1 = (
    { model_name = "rfsimu_channel_enB0"; type = "AWGN"; ploss_dB = 0; noise_power_dB = -100; forgetfact = 0; offset = 0; ds_tdl = 0; },
    { model_name = "rfsimu_channel_ue0"; type = "AWGN"; ploss_dB = 0; noise_power_dB = -95; forgetfact = 0; offset = 0; ds_tdl = 0; }
  );
};
'''

def utc(): return datetime.datetime.now(datetime.timezone.utc).isoformat()

def command(args, check=True):
    return subprocess.run(list(map(str, args)), check=check, capture_output=True, text=True)

def parse_stats(text):
    result = {}
    number = r'([-+]?\d+(?:\.\d*)?(?:[eE][-+]?\d+)?)'
    for line in text.splitlines():
        if ':' not in line: continue
        name, values = line.split(':', 1)
        parts = values.split(';')
        if len(parts) < 3: continue
        fields = [re.search(number, part) for part in parts[:3]]
        if all(fields): result[name.strip()] = (float(fields[0][1]), int(float(fields[1][1])), float(fields[2][1]))
    return result

def window_rows(start, end):
    rows = []
    for name, (avg, calls, maximum) in end.items():
        if name not in start: continue
        old_avg, old_calls, _ = start[name]
        delta = calls - old_calls
        if delta <= 0: continue
        total = avg * calls - old_avg * old_calls
        if total < 0: continue
        rows.append({'module': name, 'window_calls': delta, 'window_avg_us_estimate': total / delta,
                     'start_avg_us': old_avg, 'start_calls': old_calls,
                     'end_avg_us': avg, 'end_calls': calls, 'end_cumulative_max_us': maximum})
    return rows

def snapshot(source, target, marker, newer_than=0, timeout=25):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if source.exists():
            before = source.stat()
            data = source.read_bytes()
            after = source.stat()
            if before.st_mtime_ns == after.st_mtime_ns and after.st_mtime_ns > newer_than and marker.encode() in data:
                parsed = parse_stats(data.decode('utf-8', 'replace'))
                if parsed:
                    target.write_bytes(data)
                    return parsed, after.st_mtime_ns, utc()
        time.sleep(0.2)
    raise RuntimeError('No complete, fresh statistics snapshot: ' + str(source))

class Namespace:
    def __init__(self, name): self.name, self.owned = name, False
    def create(self):
        command(['sudo', '-n', 'ip', 'netns', 'add', self.name])
        self.owned = True
        command(['sudo', '-n', 'ip', '-n', self.name, 'link', 'set', 'lo', 'up'])
    def pids(self):
        if not self.owned: return []
        return [p for p in command(['sudo','-n','ip','netns','pids',self.name], check=False).stdout.split() if p.isdigit()]
    def close(self):
        if not self.owned: return
        for sig, seconds in [('INT', 8), ('TERM', 3), ('KILL', 1)]:
            pids = self.pids()
            if not pids: break
            command(['sudo', '-n', 'kill', '-' + sig, '--', *pids], check=False)
            deadline = time.monotonic() + seconds
            while self.pids() and time.monotonic() < deadline: time.sleep(0.2)
        command(['sudo', '-n', 'ip', 'netns', 'delete', self.name], check=False)
        self.owned = False
    def start(self, argv, build, cpus, log):
        args = ['sudo','-n','ip','netns','exec',self.name,'env','LD_LIBRARY_PATH='+str(build),
                'prlimit','--memlock=unlimited','--','taskset','-c',cpus,*map(str,argv)]
        return subprocess.Popen(args, cwd=build, stdout=log, stderr=subprocess.STDOUT)

def one_round(work, result, channel, number, args):
    build, oai = work / 'build', work / 'oai'
    dest = result / f'{channel}-{number:02d}'; dest.mkdir()
    config = oai / 'ci-scripts/conf_files/gnb.sa.band78.106prb.rfsim.conf'
    text = config.read_text()
    if re.search(r'^\s*channelmod\s*=', text, re.M): raise ValueError('Base config already contains channelmod; inspect it.')
    gnb = dest / 'gnb.conf'; gnb.write_text(text + (AWGN if channel == 'awgn' else ''))
    ue = oai / 'targets/PROJECTS/GENERIC-NR-5GC/CONF/ue.conf'
    # Preserve any previous output in this isolated build, never remove it.
    for name in ('nrL1_stats.log','nrL1_UE_stats-0.log'):
        path = build / name
        if path.exists(): path.rename(dest / ('preexisting-' + name))
    ns = Namespace('xsai-rf-' + uuid.uuid4().hex[:12])
    meta = {'channel': channel, 'round': number, 'startedUtc': utc(), 'cpuSet': args.cpus,
            'profile': LOCK['profile'], 'gnbConfigSha256': sha(gnb), 'ueConfigSha256': sha(ue),
            'warmupSeconds': args.warmup, 'measureSeconds': args.seconds,
            'functionalOnly': args.smoke or args.functional_only, 'namespace': ns.name,
            'status': 'incomplete', 'windowMethod': 'difference of rounded cumulative average times call count; estimate, not per-call tail latency'}
    try:
        ns.create()
        with (dest/'gnb.log').open('w') as glog, (dest/'nrue.log').open('w') as ulog:
            gargs = [build/'nr-softmodem','-O',gnb,'--rfsim','--rfsimulator.serveraddr','server',
                     '--phy-test','--noS1','--gNBs.[0].min_rxtxtime','6','--T_stdout','1','-q']
            if channel == 'awgn': gargs += ['--rfsimulator.options','chanmod']
            gp = ns.start(gargs, build, args.cpus, glog)
            deadline = time.monotonic()+60
            while time.monotonic()<deadline:
                ports = command(['sudo','-n','ip','netns','exec',ns.name,'ss','-Hln','sport = :4043'], check=False).stdout
                if ':4043' in ports: break
                if gp.poll() is not None: raise RuntimeError('gNB exited before listen; see gnb.log')
                time.sleep(0.5)
            else: raise RuntimeError('gNB did not listen on RFsim port')
            up = ns.start([build/'nr-uesoftmodem','-O',ue,'--rfsim','--rfsimulator.serveraddr','127.0.0.1',
                           '--phy-test','--noS1','-r','106','--numerology','1','--band','78','-C','3319680000',
                           '--ue-rxgain','140','--ue-txgain','0','--T_stdout','1','-q'], build, args.cpus, ulog)
            deadline = time.monotonic()+args.sync_timeout
            while time.monotonic()<deadline:
                content = (dest/'nrue.log').read_text(errors='replace')
                if 'UE synchronized' in content or 'Initial sync successful' in content: break
                if gp.poll() is not None or up.poll() is not None: raise RuntimeError('gNB/nrUE exited before sync; inspect logs')
                time.sleep(0.5)
            else: raise RuntimeError('nrUE synchronization timeout')
            meta['synchronizedUtc'] = utc()
            time.sleep(args.warmup)
            starts = {}
            for side, name, marker in [('gNB','nrL1_stats.log','feptx_total:'),('nrUE','nrL1_UE_stats-0.log','OFDM_MOD_STATS:')]:
                starts[side] = snapshot(build/name, dest/('start-'+name), marker)
            time.sleep(args.seconds)
            rows = []
            for side, name, marker in [('gNB','nrL1_stats.log','feptx_total:'),('nrUE','nrL1_UE_stats-0.log','OFDM_MOD_STATS:')]:
                end, mtime, observed = snapshot(build/name, dest/('end-'+name), marker, starts[side][1])
                current = window_rows(starts[side][0], end)
                if not current: raise RuntimeError('No increasing timing counters for ' + side)
                for row in current:
                    row.update(side=side, channel=channel, round=number, measure_start=starts[side][2], measure_end=observed)
                rows += current
            with (dest/'window-stats.csv').open('w', newline='') as handle:
                writer = csv.DictWriter(handle, fieldnames=list(rows[0])); writer.writeheader(); writer.writerows(rows)
            meta['status'] = 'passed'; meta['rows'] = len(rows)
    except BaseException as error:
        meta['error'] = str(error)
        raise
    finally:
        ns.close()
        meta['finishedUtc'] = utc()
        (dest/'metadata.json').write_text(json.dumps(meta, indent=2), encoding='utf-8')
    print(f'{channel} round {number}: synchronized; statistics captured at {dest}', flush=True)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', required=True)
    parser.add_argument('--mode', choices=['ideal','awgn','pair'], default='pair')
    parser.add_argument('--cpus', default='0-7')
    parser.add_argument('--rounds', type=int, default=5)
    parser.add_argument('--warmup', type=int, default=20)
    parser.add_argument('--seconds', type=int, default=120)
    parser.add_argument('--sync-timeout', type=int, default=120)
    parser.add_argument('--smoke', action='store_true')
    parser.add_argument('--functional-only', action='store_true')
    args=parser.parse_args()
    if not re.fullmatch(r'\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*',args.cpus): parser.error('Invalid CPU list')
    if min(args.rounds,args.seconds,args.sync_timeout)<1 or args.warmup<0: parser.error('Invalid duration/count')
    work=safe_workspace(args.workspace); state(work)
    lock_handle=(work/'.rfsim.lock').open('a')
    try: fcntl.flock(lock_handle,fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: raise ValueError('Another runner owns this workspace; use a separate workspace.')
    manifest=json.loads((work/'build-manifest.json').read_text())
    for artifact in manifest['artifacts']:
        if sha(work/artifact['path'])!=artifact['sha256']: raise ValueError('Build artifact changed: '+artifact['path'])
    busy = [name for name in ['nr-softmodem','nr-uesoftmodem','amf','smf','upf']
            if command(['pgrep','-x',name],check=False).returncode==0]
    if busy and not (args.smoke or args.functional_only):
        raise ValueError('Formal timing requires an idle experiment host; active processes: '+','.join(busy))
    command(['sudo','-n','true'])
    result=work/'results'/(datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+uuid.uuid4().hex[:8])
    result.mkdir(parents=True)
    shutil_data = (work/'build-manifest.json').read_bytes()
    (result/'build-manifest.json').write_bytes(shutil_data)
    requested=vars(args).copy()
    if args.smoke: args.mode,args.rounds,args.warmup,args.seconds='ideal',1,2,4
    (result/'invocation.json').write_text(json.dumps({'requestedArguments':requested,'arguments':vars(args),'backgroundProcesses':busy},indent=2),encoding='utf-8')
    print('RESULTS='+str(result),flush=True)
    for number in range(1,args.rounds+1):
        for channel in (['ideal','awgn'] if args.mode=='pair' else [args.mode]):
            one_round(work,result,channel,number,args)

if __name__=='__main__':
    def interrupted(signum, frame): raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM,interrupted)
    try: main()
    except KeyboardInterrupt:
        print('Interrupted; owned namespace cleanup completed.',file=sys.stderr);sys.exit(130)
    except (OSError,ValueError,KeyError,RuntimeError,subprocess.CalledProcessError) as error:
        print('ERROR: '+str(error),file=sys.stderr); sys.exit(1)
