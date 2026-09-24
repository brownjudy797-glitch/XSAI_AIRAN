"""Reuse A compiler settings in an isolated build; never overwrite deployed objects."""
from pathlib import Path
import subprocess,shlex,json,hashlib,sys
root=Path('/home/ubuntu/XSAI_AIRAN-publish-20260922')
source=Path('/home/ubuntu/oai-A-dfts-extraction-20260924')
base=Path('/home/ubuntu/sionna-rk/ext/openairinterface5g/cmake_targets/phy-fixed-build-20260922')
control='--control' in sys.argv
if control: source=root/'vendor/openairinterface5g'
out=root/('.build/dfts-control' if control else '.build/dfts-module')
out.mkdir(exist_ok=True)
flags={}
for line in (base/'CMakeFiles/dfts.dir/flags.make').read_text().splitlines():
    if ' = ' in line:
        k,v=line.split(' = ',1);flags[k]=shlex.split(v)
commands=[]
def run(args):
    commands.append(args)
    (out/'commands.json').write_text(json.dumps(commands,indent=2))
    with (out/'build.log').open('a') as log:
        subprocess.run(args,cwd=base,stdout=log,stderr=subprocess.STDOUT,check=True)
for name in ['oai_dfts.c','oai_dfts_neon.c']:
    args=['gcc-16','-I'+str(source),'-I/home/ubuntu/sionna-rk/ext/openairinterface5g']
    for key in ['C_DEFINES','C_INCLUDES','C_FLAGS']:args+=flags[key]
    args+=['-c',str(source/'openair1/PHY/TOOLS'/name),'-o',str(out/(name+'.o'))]
    run(args)
args=shlex.split((base/'CMakeFiles/dfts.dir/link.txt').read_text())
for i,a in enumerate(args):
    if a=='-o':args[i+1]=str(out/'libdfts.so')
    elif a.endswith('.c.o'):args[i]=str(out/Path(a).name)
    elif a.startswith('-Wl,--dependency-file='):args[i]='-Wl,--dependency-file='+str(out/'link.d')
run(args)
print('BUILD_OK',hashlib.sha256((out/'libdfts.so').read_bytes()).hexdigest())
