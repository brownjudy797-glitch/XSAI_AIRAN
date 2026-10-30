# SPDX-License-Identifier: Apache-2.0
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('archive',Path(__file__).resolve().parents[1]/'scripts/archive-k3-runtime-logs.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class Archive(unittest.TestCase):
    def test_preserves_logs_and_prior_archives(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);logs=root/'logs/cn5g-k3';logs.mkdir(parents=True)
            (logs/'amf.log').write_bytes(b'original evidence\n')
            first=module.archive(root)
            (logs/'amf.log').write_bytes(b'next run\n')
            second=module.archive(root)
            self.assertNotEqual(first,second)
            self.assertEqual((first/'amf.log').read_bytes(),b'original evidence\n')
            self.assertEqual((second/'amf.log').read_bytes(),b'next run\n')
            self.assertEqual((logs/'amf.log').read_bytes(),b'next run\n')
            self.assertFalse(json.loads((second/'manifest.json').read_text())['files'][0]['sourceChangedDuringCopy'])

    def test_absent_logs_do_not_create_project(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)/'absent'
            self.assertIsNone(module.archive(root));self.assertFalse(root.exists())

if __name__=='__main__': unittest.main()
