# SPDX-License-Identifier: Apache-2.0
"""Check the public K3 snapshot without connecting to or modifying a host."""
from pathlib import Path
import ast
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
SNAPSHOT = ROOT / 'snapshots/k3/20261029'
MANIFEST = json.loads((SNAPSHOT / 'manifest.json').read_text(encoding='utf-8'))

class K3Snapshot(unittest.TestCase):
    def test_published_source_fingerprints(self):
        for entry in MANIFEST['publishedSourceFiles']:
            path = ROOT / entry['path']
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), entry['publishedSha256'])
            self.assertTrue(path.suffix in ('.py', '.sh', '.c'))
            self.assertFalse(any(part in path.parts for part in ('config', '.runtime', '.baseline', 'logs')))
        for key in ('optionalOaiOverlay', 'oaiVsHeadPatch'):
            entry = MANIFEST[key]
            self.assertEqual(hashlib.sha256((SNAPSHOT / entry['path']).read_bytes()).hexdigest(), entry['sha256'])

    def test_source_syntax(self):
        bash = os.environ.get('BASH') or shutil.which('bash')
        for entry in MANIFEST['publishedSourceFiles']:
            path = ROOT / entry['path']
            if path.suffix == '.py':
                ast.parse(path.read_text(encoding='utf-8'), filename=str(path))
            elif path.suffix == '.sh' and bash:
                result = subprocess.run([bash, '-n', str(path)], capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', 'replace'))

    def test_oai_overlays(self):
        patch = SNAPSHOT / 'oai-published-to-observed.patch'
        result = subprocess.run(['git', '-C', str(ROOT), 'apply', '--check', '--directory=vendor/openairinterface5g', str(patch)], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', 'replace'))
        full = SNAPSHOT / 'oai-vs-head.patch'
        paths = re.findall(r'(?m)^--- a/(.+)$', full.read_text(encoding='utf-8'))
        self.assertEqual(len(paths), 9)
        with tempfile.TemporaryDirectory() as work:
            work = Path(work)
            for relative in paths:
                target = work / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / 'vendor/openairinterface5g' / relative, target)
            for args in [('init', '--quiet'), ('apply', str(patch)), ('apply', '--reverse', '--check', str(full)),
                         ('apply', '--reverse', str(full)), ('apply', '--check', str(full))]:
                result = subprocess.run(['git', '-C', str(work), *args], capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', 'replace'))

    def test_new_document_links(self):
        paths = ['docs/K3_CURRENT_STATUS.md', 'snapshots/k3/20261029/README.md',
                 'benchmarks/README.md', 'benchmarks/dft/README.md']
        for relative in paths:
            path = ROOT / relative
            for target in re.findall(r'\]\(([^)]+)\)', path.read_text(encoding='utf-8')):
                if re.match(r'\w+:|#', target): continue
                self.assertTrue((path.parent / unquote(target.split('#')[0])).exists(), f'{relative}: {target}')

    def test_quickstart_guard_selection_and_failure(self):
        bash = os.environ.get('BASH') or shutil.which('bash')
        if not bash:
            self.skipTest('Bash unavailable')
        with tempfile.TemporaryDirectory() as work:
            work = Path(work)
            scripts = work / 'project/scripts'; scripts.mkdir(parents=True)
            commands = work / 'bin'; commands.mkdir()
            log = work / 'guard.log'
            launch = work / 'launched'
            (scripts / 'run-k3-b200.sh').write_text('#!/bin/sh\nprintf launched > "$LAUNCH_LOG"\n', encoding='utf-8')
            legacy = scripts / 'k3-fixed-baseline.py'; legacy.write_text('# fixture\n')
            current = scripts / 'k3-deployment-guard.py'; current.write_text('# fixture\n')
            for name, source in {
                'uname': '#!/bin/sh\nprintf riscv64\n',
                'lsusb': '#!/bin/sh\nprintf "Bus 001 Device 002: ID 2500:0020\\n"\n',
                'systemctl': '#!/bin/sh\nprintf inactive\n',
                'python3': '#!/bin/sh\nprintf "%s\\n" "$@" >> "$GUARD_LOG"\nexit "${GUARD_EXIT:-0}"\n',
            }.items():
                path = commands / name; path.write_text(source, encoding='utf-8'); path.chmod(0o755)
            env = os.environ.copy()
            env.update(SIONNA_RK_ROOT=(work / 'project').as_posix(), GUARD_LOG=log.as_posix(), LAUNCH_LOG=launch.as_posix())
            env['PATH'] = str(commands) + os.pathsep + str(Path(bash).parent) + os.pathsep + env.get('PATH', '')
            wrapper = ROOT / 'tutorials/quickstart/k3-quickstart.sh'
            result = subprocess.run([bash, str(wrapper), 'check'], env=env, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', 'replace'))
            self.assertIn('k3-deployment-guard.py', log.read_text())
            log.write_text(''); env['GUARD_EXIT'] = '1'
            result = subprocess.run([bash, str(wrapper), 'start'], env=env, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('k3-fixed-baseline.py', log.read_text())
            self.assertFalse(launch.exists())
            current.unlink(); log.write_text(''); env['GUARD_EXIT'] = '0'
            result = subprocess.run([bash, str(wrapper), 'check'], env=env, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', 'replace'))
            self.assertIn('k3-fixed-baseline.py', log.read_text())

if __name__ == '__main__':
    unittest.main(verbosity=2)
