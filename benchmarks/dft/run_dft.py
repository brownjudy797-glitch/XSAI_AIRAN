# SPDX-License-Identifier: Apache-2.0
"""Isolated smoke baseline. Run on K3; emits one JSON document to stdout."""
import datetime
import hashlib
import json
import pathlib
import os
import re
import subprocess

root = pathlib.Path(os.environ.get('SIONNA_RK_ROOT', str(pathlib.Path.home() / 'sionna-rk')))
oai = root / 'ext/openairinterface5g'
build = pathlib.Path(os.environ.get('OAI_BUILD', str(oai / 'cmake_targets/ran_build/build')))
work = pathlib.Path(__file__).resolve().parent
library = build / 'libdfts.so'
header = (oai / 'openair1/PHY/TOOLS/tools_defs.h').read_text()
sizes = [int(x) for x in re.findall(r'SZ_DEF\((\d+)\)', header.split('#define FOREACH_DFTSZ(SZ_DEF)', 1)[1].split('#define', 1)[0])]
def read(path):
    try:
        return pathlib.Path(path).read_text().strip()
    except OSError:
        return None
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
results = []
metadata = {
    'date': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'source_head': subprocess.check_output(['git','-C',str(oai),'rev-parse','HEAD'], text=True).strip(),
    'library': str(library), 'library_sha256': digest(library),
    'harness_sha256': digest(work / 'bench_dft.c'),
    'tools_defs_sha256': digest(oai / 'openair1/PHY/TOOLS/tools_defs.h'),
    'cpu': 0, 'cpu_frequency_before_khz': read('/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq'),
    'governor': read('/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor'),
    'cpuinfo': read('/proc/cpuinfo'),
    'compiler': subprocess.check_output(['cc','--version'],text=True).splitlines()[0],
    'measurement': 'CLOCK_MONOTONIC_RAW; hot-cache fixed seed=42; Q15 scale=1; 100 warmups; 1000 batches of 32 calls; timer overhead included',
    'percentiles': 'percentiles of batch-average per-call time, NOT single-call latency percentiles',
    'correctness': 'FP64 mathematical DFT reference; normalized RMS EVM <= 0.05 for low-amplitude synthetic inputs; not full OAI test-suite validation',
    'core_cycles': None,
    'status': 'initial standalone DFT baseline; not full microbench suite or full PHY capacity test',
}
for n in [128, 512, 1024, 2048]:
    if n not in sizes:
        raise RuntimeError(f'Unsupported DFT size {n}')
    for trial in range(1, 4):
        run = subprocess.run(['taskset','-c','0',str(work/'bench_dft'),str(library),str(sizes.index(n)),str(n),'1000',str(trial)],capture_output=True,text=True,timeout=45)
        if run.returncode:
            raise RuntimeError(f'N={n}: {run.stdout} {run.stderr}')
        line = next(x for x in run.stdout.splitlines() if x.startswith('dft,'))
        _, _, _, samples, batch, mean, p50, p95, p99, evm, checksum = line.split(',')
        results.append(dict(operator='DFT',nfft=n,run=trial,samples=int(samples),batch=int(batch),mean_us=float(mean),batch_p50_us=float(p50),batch_p95_us=float(p95),batch_p99_us=float(p99),rms_evm=float(evm),checksum=int(checksum),library_index=sizes.index(n)))
metadata['cpu_frequency_after_khz'] = read('/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq')
print(json.dumps({'metadata':metadata,'results':results},ensure_ascii=False))
