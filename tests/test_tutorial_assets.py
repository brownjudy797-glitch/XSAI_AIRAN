# SPDX-License-Identifier: Apache-2.0
"""Offline integrity checks for the versioned multi-platform tutorials."""
from pathlib import Path
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / 'tutorials/assets/20261029'
GUIDES = [ROOT / 'tutorials' / platform / 'README.md' for platform in
          ('k3-rv64', 'x86-rfsim', 'arm64-rfsim', 'k3-cn5g')]

class TutorialAssets(unittest.TestCase):
    def test_asset_digests_and_manifest(self):
        manifest = json.loads((ASSETS / 'manifest.json').read_text(encoding='utf-8'))
        sums = dict(line.split('  ', 1)[::-1] for line in (ASSETS / 'SHA256SUMS').read_text().splitlines())
        self.assertEqual(len(sums), 7)
        for entry in manifest['assets']:
            path = ASSETS / entry['file']
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            self.assertEqual(digest, entry['sha256'], path.name)
            self.assertEqual(digest, sums[path.name], path.name)
            self.assertNotIn(b'\r', path.read_bytes(), path.name)
            if entry['originalPayloadSha256']:
                original = path.read_bytes().replace(b'# SPDX-License-Identifier: Apache-2.0\n', b'', 1)
                self.assertEqual(hashlib.sha256(original).hexdigest(), entry['originalPayloadSha256'])

    def test_embedded_download_checksums(self):
        count = 0
        for doc in GUIDES:
            for block in re.findall(r'(?ms)^```bash\n(.*?)^```[ \t]*$', doc.read_text(encoding='utf-8')):
                urls = re.findall(r'https://raw\.githubusercontent\.com/brownjudy797-glitch/XSAI_AIRAN/main/([^"\s]+)', block)
                for relative in urls:
                    asset = ROOT / relative
                    self.assertTrue(asset.is_file(), f'{doc}: {relative}')
                    self.assertIn(hashlib.sha256(asset.read_bytes()).hexdigest(), block, str(doc))
                    count += 1
        self.assertGreaterEqual(count, 10)

    def test_relative_links(self):
        docs = GUIDES + [ROOT / 'tutorials/README.md', ASSETS / 'README.md', ROOT / 'patches/k3-rv64/20261029/README.md']
        for doc in docs:
            text = doc.read_text(encoding='utf-8')
            self.assertEqual(len(re.findall(r'(?m)^```', text)) % 2, 0, str(doc))
            for target in re.findall(r'\]\(([^)\n]+)\)', text):
                if re.match(r'[a-z]+:|#', target):
                    continue
                self.assertTrue((doc.parent / unquote(target.split('#')[0])).exists(), f'{doc}: {target}')

    def test_bash_syntax(self):
        bash = os.environ.get('BASH') or shutil.which('bash')
        if not bash:
            self.skipTest('Bash unavailable; set BASH to run syntax checks')
        for script in ASSETS.glob('*.sh'):
            result = subprocess.run([bash, '-n', str(script)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', 'replace'))
        with tempfile.TemporaryDirectory() as work:
            count = 0
            for doc in GUIDES:
                for block in re.findall(r'(?ms)^```bash\n(.*?)^```[ \t]*$', doc.read_text(encoding='utf-8')):
                    count += 1
                    script = Path(work) / f'block-{count}.sh'
                    script.write_bytes(block.encode())
                    result = subprocess.run([bash, '-n', str(script)], capture_output=True)
                    self.assertEqual(result.returncode, 0, f'{doc} block {count}: {result.stderr.decode("utf-8", "replace")}')
            self.assertGreater(count, 100)

    def test_platform_separation(self):
        for platform in ('x86-rfsim', 'arm64-rfsim'):
            text = (ROOT / 'tutorials' / platform / 'README.md').read_text(encoding='utf-8')
            self.assertNotIn('/patches/k3-rv64/', text)
            self.assertIn('cpu-only-plugins.patch', text)
            self.assertIn('3319680000', text)
            self.assertNotIn('  --clean \\', text)
        for script in ASSETS.glob('run-*-hotspot-experiment.sh'):
            text = script.read_text(encoding='utf-8')
            self.assertIn('-C 3319680000', text)
            self.assertIn('--phy-test', text)
            self.assertIn('--noS1', text)

if __name__ == '__main__':
    unittest.main(verbosity=2)
