# SPDX-License-Identifier: Apache-2.0
"""Offline checks of isolation, measurement semantics and subscriber validation."""
import ast
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
import reproduce

def module(name,file):
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts'/file)
    value=importlib.util.module_from_spec(spec); spec.loader.exec_module(value); return value

if os.name=='nt':
    sys.modules.setdefault('fcntl',types.SimpleNamespace())
rf=module('rf','repro-rfsim.py')
subscriber=module('subscriber','provision-test-subscriber.py')

class Reproduction(unittest.TestCase):
    def test_profile_integrity(self):
        lock=reproduce.LOCK
        self.assertEqual(reproduce.sha(ROOT/lock['simdePatch']),lock['simdePatchSha256'])
        for directory,key in [('vendor/openairinterface5g','vendorTree'),('plugins','pluginTree')]:
            actual=subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD:'+directory],text=True).strip()
            self.assertEqual(actual,lock[key])

    def test_workspace_protection(self):
        for path in [Path.home(),Path.home()/'sionna-rk',Path.home()/'sionna-rk/build',ROOT,ROOT/'scratch']:
            with self.assertRaises(ValueError): reproduce.safe_workspace(path)
        with tempfile.TemporaryDirectory() as temp:
            work=Path(temp)
            with self.assertRaises(FileNotFoundError): reproduce.prepare(work)
            self.assertEqual(list(work.iterdir()),[])

    def test_source_line_endings_do_not_hide_edits(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);path=root/'vendor/openairinterface5g/example.c';path.parent.mkdir(parents=True)
            path.write_bytes(b'int value=1;\n')
            blob=b'int value=1;\r\n';obj=b'a'*40
            outputs=[b'100644 blob '+obj+b'\tvendor/openairinterface5g/example.c\0',
                     obj+b' blob '+str(len(blob)).encode()+b'\n'+blob+b'\n']
            with patch.object(reproduce,'REPO',root),patch.object(reproduce.subprocess,'check_output',side_effect=outputs):
                reproduce.verify_source_files()
            path.write_bytes(b'int value=2;\n')
            with patch.object(reproduce,'REPO',root),patch.object(reproduce.subprocess,'check_output',side_effect=outputs):
                with self.assertRaises(ValueError): reproduce.verify_source_files()

    def test_cumulative_window_semantics(self):
        before=rf.parse_stats('dft: 2.0 us; 10 calls; 8.0 us;\nreset: 3 us; 10; 4;')
        after=rf.parse_stats('dft: 3.0 us; 20 calls; 12.0 us;\nreset: 1 us; 2; 2;')
        rows=rf.window_rows(before,after)
        self.assertEqual(len(rows),1)
        self.assertEqual(rows[0]['window_calls'],10)
        self.assertEqual(rows[0]['window_avg_us_estimate'],4)
        self.assertEqual(rows[0]['end_cumulative_max_us'],12)

    def test_build_uses_private_dependencies_and_serializes_command(self):
        with tempfile.TemporaryDirectory() as temp:
            work=Path(temp)
            for name in ['deps/asn1c/bin/asn1c','deps/include/simde/simde-common.h']:
                path=work/name;path.parent.mkdir(parents=True,exist_ok=True);path.touch()
            def configure(arguments):
                if arguments[0]=='cmake' and '-S' in arguments:
                    (work/'build').mkdir()
                    (work/'build/CMakeCache.txt').write_text('ASN1C_EXEC:FILEPATH='+str(work/'deps/asn1c/bin/asn1c')+'\nCMAKE_C_FLAGS:STRING=-I'+str(work/'deps/include')+'\n')
            with patch.object(reproduce,'state',return_value={'prepared':True}), \
                 patch.object(reproduce.shutil,'which',return_value='/usr/bin/tool'), \
                 patch.object(reproduce,'run',side_effect=configure) as run,patch.object(reproduce,'check') as check:
                reproduce.build(work,2)
                arguments=json.loads((work/'configure-command.json').read_text())
                self.assertIn('-DASN1C_EXEC='+str(work/'deps/asn1c/bin/asn1c'),arguments)
                self.assertIn('-DOAI_USRP=OFF',arguments)
                self.assertTrue(any(str(work/'deps/include') in arg for arg in arguments))
                self.assertEqual(run.call_count,2);check.assert_called_once_with(work)

    def test_cleanup_only_owned_namespace(self):
        namespace=rf.Namespace('xsai-rf-test')
        with patch.object(rf,'command') as command:
            namespace.close(); command.assert_not_called()
        namespace.owned=True
        with patch.object(namespace,'pids',return_value=[]),patch.object(rf,'command') as command:
            namespace.close()
            command.assert_called_once_with(['sudo','-n','ip','netns','delete','xsai-rf-test'],check=False)

    def test_subscriber_inputs(self):
        sql=subscriber.statement('001010000000001','ab'*16,'cd'*16,0,'ef'*16)
        self.assertIn('UNHEX',sql); self.assertNotIn('UPDATE',sql)
        for values in [("1';DROP TABLE users",'ab'*16,'cd'*16,0,'ef'*16),
                       ('001010000000001','bad','cd'*16,0,'ef'*16),
                       ('001010000000001','ab'*16,'cd'*16,2**48,'ef'*16)]:
            with self.assertRaises(ValueError): subscriber.statement(*values)

    def test_native_rfsim_does_not_require_usrp(self):
        if os.name=='nt': self.skipTest('Native Linux script; exercised on K3 instead of partial Windows coreutils')
        bash=os.environ.get('BASH') or shutil.which('bash')
        if not bash: self.skipTest('Bash unavailable')
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);oai=root/'oai';(oai/'cmake_targets').mkdir(parents=True);(oai/'plugins').mkdir()
            mock=oai/'cmake_targets/build_oai'
            mock.write_bytes(b'#!/usr/bin/env bash\nprintf "%s\\n" "$@" > "$NATIVE_ARGS"\n')
            mock.chmod(0o755)
            capture=root/'args.txt'
            result=subprocess.run([bash,str(ROOT/'scripts/build-oai-native.sh'),str(oai)],
                                  env={**os.environ,'NATIVE_ARGS':str(capture),'PATH':str(Path(bash).parent)+os.pathsep+os.environ['PATH']},capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            arguments=capture.read_text().splitlines()
            self.assertIn('-DOAI_USRP=OFF',arguments)
            self.assertNotIn('-DOAI_USRP=ON',arguments)
            self.assertNotIn('oai_usrpdevif',result.stdout)

    def test_draft_syntax_and_links(self):
        bash=os.environ.get('BASH') or shutil.which('bash')
        scripts=['reproduce.py','repro-rfsim.py','provision-test-subscriber.py']
        for name in scripts: ast.parse((ROOT/'scripts'/name).read_text(encoding='utf-8'))
        if bash:
            for name in ['repro-deps.sh','build-oai-native.sh']:
                subprocess.run([bash,'-n',str(ROOT/'scripts'/name)],check=True)
        docs=[ROOT/'tutorials/reproduction/README.md',ROOT/'tutorials/k3-cn5g/FROM_ZERO.md',ROOT/'docs/REPRODUCIBILITY_AUDIT.md']
        with tempfile.TemporaryDirectory() as temp:
            for doc in docs:
                text=doc.read_text(encoding='utf-8')
                for target in re.findall(r'\]\(([^)\n]+)\)',text):
                    if not re.match(r'[a-z]+:|#',target): self.assertTrue((doc.parent/target.split('#')[0]).exists(),target)
                if bash:
                    for block in re.findall(r'(?ms)^```bash\n(.*?)^```',text):
                        path=Path(temp)/'block.sh';path.write_bytes(block.encode())
                        subprocess.run([bash,'-n',str(path)],check=True)

if __name__=='__main__': unittest.main(verbosity=2)
