# SPDX-License-Identifier: Apache-2.0
import contextlib
import csv
import hashlib
import io
import json
from pathlib import Path
import re
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
RESULT=ROOT/'benchmarks/results/k3-20261030'

class Acceptance(unittest.TestCase):
    def test_public_artifacts_and_failed_step_retained(self):
        data=json.loads((RESULT/'verification.json').read_text())
        for name,digest in data['publishedArtifacts'].items():
            self.assertEqual(hashlib.sha256((RESULT/name).read_bytes()).hexdigest(),digest)
        rounds=data['rfsim']['rounds'];self.assertEqual(len(rounds),10)
        for channel in ['ideal','awgn']:
            self.assertEqual(sorted(x['round'] for x in rounds if x['channel']==channel),[1,2,3,4,5])
        self.assertTrue(all(x['status']=='passed' and x['measureSeconds']==120 for x in rounds))
        with (RESULT/'rfsim-module-summary.csv').open(newline='') as stream: rows=list(csv.DictReader(stream))
        self.assertEqual(len(rows),134);self.assertTrue(all(x['rounds']=='5' for x in rows))
        radio={x['test']:x for x in data['radio']['throughput']}
        self.assertFalse(radio['ul-1M']['zero_loss_gate_passed'])
        self.assertGreater(radio['ul-1M']['lost_percent'],0)
        for key in ['ul-3M-120s','dl-2.5M-120s']:
            self.assertTrue(radio[key]['zero_loss_gate_passed'])
            self.assertEqual(radio[key]['seconds'],120)

    def test_profile_recipe_preserves_other_plmn_and_credentials(self):
        text=(ROOT/'tutorials/k3-cn5g/FROM_ZERO.md').read_text(encoding='utf-8')
        code=re.search(r"sudo python3 - <<'PY'\n(.*?)\nPY",text,re.S)[1]
        fixture='''database:
  password: keep_this_local_value
amf:
  served_guami_list:
    - mcc: 208
      mnc: 95
    - mcc: 001
      mnc: 01
  plmn_support_list:
    - mcc: 208
      mnc: 95
      tac: 0xa000
dns:
  primary_ipv4: "172.21.3.100"
  secondary_ipv4: "8.8.8.8"
'''
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)/'cn5g';root.mkdir()
            for name in ['amf.yaml','smf.yaml','upf.yaml']: (root/name).write_text(fixture)
            code=code.replace("root=Path('/etc/sionna-rk-k3/cn5g')",'root=Path('+repr(str(root))+')')
            with contextlib.redirect_stdout(io.StringIO()):
                exec(compile(code,'profile-recipe','exec'),{})
                exec(compile(code,'profile-recipe','exec'),{})
            for name in ['amf.yaml','smf.yaml','upf.yaml']:
                actual=(root/name).read_text()
                self.assertEqual(actual.count('mcc: 262'),2)
                self.assertIn('mcc: 001\n      mnc: 01',actual)
                self.assertIn('tac: 1',actual)
                self.assertIn('password: keep_this_local_value',actual)
                self.assertIn('secondary_ipv4: "1.1.1.1"',actual)
            backups=list(Path(temp).glob('cn5g-before-profile-*'))
            self.assertEqual(len(backups),2)
            self.assertIn(fixture,[(backup/'amf.yaml').read_text() for backup in backups])

    def test_new_report_links(self):
        for doc in [RESULT/'README.md',ROOT/'tutorials/k3-cn5g/FROM_ZERO.md',ROOT/'tutorials/quickstart/README.md']:
            for target in re.findall(r'\]\(([^)\n]+)\)',doc.read_text(encoding='utf-8')):
                if not re.match(r'[a-z]+:|#',target):
                    self.assertTrue((doc.parent/target.split('#')[0]).exists(),target)

if __name__=='__main__': unittest.main()
