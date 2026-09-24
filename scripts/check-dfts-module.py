"""Build a minimal host for the full DFT libraries, compare separate-process runs."""
from pathlib import Path
import subprocess,re,shlex,json,hashlib,resource
root=Path('/home/ubuntu/XSAI_AIRAN-publish-20260922')
base=Path('/home/ubuntu/sionna-rk/ext/openairinterface5g/cmake_targets/phy-fixed-build-20260922')
out=root/'.build/dfts-module'
text=(root/'vendor/openairinterface5g/openair1/PHY/TOOLS/tools_defs.h').read_text()
sizes={}
for name in ['DFT','IDFT']:
    section=text.split('#define FOREACH_'+name+'SZ(SZ_DEF)',1)[1].split('\n\n',1)[0]
    sizes[name]=[int(n) for n in re.findall(r'SZ_DEF\((\d+)\)',section)]
source=(root/'vendor/openairinterface5g/openair1/PHY/TOOLS/oai_dfts.c').read_text()
batch=[]
for n in sizes['DFT']:
    match=re.search(r'void dft'+str(n)+r'\([^)]*\)[^{]*\{',source)
    assert match, n
    start=match.end(); end=start; depth=1
    while depth:
        if source[end]=='{':depth+=1
        if source[end]=='}':depth-=1
        end+=1
    body=source[start:end]
    batch.append(4 if re.search(r'simd_q15_t\s*\*x128',body) else 1)
(out/'dfts_sizes.h').write_text('\n'.join('static const int '+k.lower()+'_sizes[]={'+','.join(map(str,v))+'};' for k,v in sizes.items())+'\nstatic const int dft_batch[]={'+','.join(map(str,batch))+'};')
flags={}
for line in (base/'CMakeFiles/dfts.dir/flags.make').read_text().splitlines():
    if ' = ' in line:
        k,v=line.split(' = ',1);flags[k]=shlex.split(v)
args=['gcc-16','-I/home/ubuntu/sionna-rk/ext/openairinterface5g','-I'+str(out)]
args+=flags['C_DEFINES']+flags['C_INCLUDES']+['-O2','-rdynamic',str(root/'architecture/tests/dfts_module_runner.c'),'-o',str(out/'runner'),'-ldl','-Wl,--no-as-needed','-lm']
subprocess.run(args,check=True)
libs={'baseline':base/'libdfts.so','control':root/'.build/dfts-control/libdfts.so','migrated':out/'libdfts.so'}
results={'libraries':{k:hashlib.sha256(p.read_bytes()).hexdigest() for k,p in libs.items()},'sizes':[],
         'method':'one process per library and size; aligned buffers; zero/impulse/random-small/random-full; both scale flags; logging/tracing-only stubs'}
def limits(): resource.setrlimit(resource.RLIMIT_CORE,(0,0))
for direction,(kind,values) in enumerate(sizes.items()):
    for idx,n in enumerate(values):
        row={'direction':kind,'size':n,'batch':batch[idx] if direction==0 else 1,'runs':{}}
        for key,lib in libs.items():
            prefix=out/(key+'-'+kind+'-'+str(n))
            binary=prefix.with_suffix('.bin'); logpath=prefix.with_suffix('.log')
            with logpath.open('w') as log:
                try:
                    p=subprocess.run([str(out/'runner'),str(lib),str(binary),str(direction),str(idx)],stdout=log,stderr=subprocess.STDOUT,timeout=30,preexec_fn=limits)
                    rc=p.returncode
                except subprocess.TimeoutExpired: rc=124
            logtext=logpath.read_text()
            row['runs'][key]={'returncode':rc,'sha256':hashlib.sha256(binary.read_bytes()).hexdigest() if rc==0 else None,
                             'zero_anomalies':[line for line in logtext.splitlines() if line.startswith('ZERO_ANOMALY')]}
        a=row['runs']['control'];b=row['runs']['migrated']
        row['migration_equal']=a['returncode']==b['returncode']==0 and a['sha256']==b['sha256']
        results['sizes'].append(row)
        print(kind,n,'equal='+str(row['migration_equal']),'rc='+str([x['returncode'] for x in row['runs'].values()]),flush=True)
results['summary']={'sizes':len(results['sizes']),'equal_sizes':sum(r['migration_equal'] for r in results['sizes']),
                    'failed_sizes':sum(any(v['returncode'] for v in r['runs'].values()) for r in results['sizes']),
                    'zero_anomaly_sizes':sum(any(v['zero_anomalies'] for v in r['runs'].values()) for r in results['sizes'])}
(out/'result.json').write_text(json.dumps(results,indent=2))
print(json.dumps(results['summary']))
raise SystemExit(0 if results['summary']['equal_sizes']==results['summary']['sizes'] and not results['summary']['zero_anomaly_sizes'] else 1)
