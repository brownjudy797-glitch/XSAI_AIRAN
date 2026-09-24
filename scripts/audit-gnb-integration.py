"""Record build provenance and dynamic dependencies without starting the gNB."""
from pathlib import Path
import hashlib
import json
import subprocess

root = Path(__file__).resolve().parents[1]
build = root/'.build/gnb-integration'
entries = json.loads((build/'compile_commands.json').read_text())
forbidden = ['/ext/openairinterface5g', 'openairinterface5g_bak']
bad = [e['file'] for e in entries if any(s in e['command'] for s in forbidden)]
assert not bad, ('Unexpected live/legacy source references', bad[:10])
cache = (build/'CMakeCache.txt').read_text()
source = Path(next(s.split('=',1)[1] for s in cache.splitlines() if s.startswith('CMAKE_HOME_DIRECTORY:')))
dependency = (build/'CMakeFiles/dfts.dir/openair1/PHY/TOOLS/oai_dfts.c.o.d').read_text()
assert 'adapters/oai/include/xsai_dfts_adapter.h' in dependency
assert 'plugins/rvv_phy/include/oai_dfts_rvv.h' in dependency
paths = [source/'openair1/PHY/TOOLS/oai_dfts.c', source/'openair1/PHY/TOOLS/oai_dfts_rvv.h',
         root/'plugins/rvv_phy/include/oai_dfts_rvv.h', root/'adapters/oai/include/xsai_dfts_adapter.h']
deps = subprocess.check_output(['ldd',str(build/'nr-softmodem')],text=True)
assert 'not found' not in deps
exports = subprocess.check_output(['nm','-D','--defined-only',str(build/'libdfts.so')],text=True)
for name in ('dfts_autoinit','dft_implementation','idft_implementation'):
    assert any(line.endswith(' '+name) for line in exports.splitlines())
result = {'passed':True,'source':str(source),'compile_entries':len(entries),
          'forbidden_source_references':bad,'adapter_dependency_confirmed':True,
          'source_sha256':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths},
          'gnb_ldd':deps,'required_dft_exports':True,
          'scope':'static provenance/dependency audit; ldd does not prove dlopen-only radio plugins work'}
(build/'integration-audit.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result,indent=2))
