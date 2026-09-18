"""Check that release preparation excludes private files and never overwrites data."""
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/prepare-public-release.py'
spec = importlib.util.spec_from_file_location('public_export', SCRIPT)
export = importlib.util.module_from_spec(spec)
spec.loader.exec_module(export)


class PublicExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'source'
        self.destination = Path(self.temp.name) / 'public'
        required = export.ROOT_FILES + export.PUBLIC_DOCS + export.SCRIPTS + export.GITHUB_FILES
        for name in required + ('Resources/Info.plist', 'Resources/AppIcon.icns',
                                'Resources/PelicanLogo.svg', 'Resources/MenuBarLogo.svg',
                                'Sources/Example.swift', 'Tests/ExampleTests.swift'):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('public fixture\n')
        (self.root / 'scripts/prepare-public-release.py').write_bytes(SCRIPT.read_bytes())
        (self.root / 'Resources/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleShortVersionString': '0.2.3', 'CFBundleVersion': '8'}))

    def run_export(self):
        return subprocess.run([sys.executable, str(self.root / 'scripts/prepare-public-release.py'),
                               str(self.destination)], text=True, capture_output=True)

    def test_allowlist_excludes_private_files_and_history(self):
        private = ['.git/config', '.env', '.env.local', 'artifacts/result.json',
                   'docs/crew/brief.json', 'docs/source/PRD.md',
                   'docs/RECOVERY_ACCEPTANCE.md', 'dist/private.txt', 'unexpected.txt']
        for name in private:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('PRIVATE_TEST_SENTINEL')
        result = self.run_export()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.destination / 'Sources/Example.swift').is_file())
        self.assertTrue((self.destination / 'LICENSE').is_file())
        for name in private:
            self.assertFalse((self.destination / name).exists(), name)
        manifest = json.loads((self.destination / 'release-manifest.json').read_text())
        self.assertEqual(manifest['version'], '0.2.3')
        self.assertTrue(all(not Path(name).is_absolute() for name in manifest['files']))

    def test_existing_destination_is_not_overwritten(self):
        self.destination.mkdir()
        sentinel = self.destination / 'keep.txt'
        sentinel.write_text('keep me')
        result = self.run_export()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sentinel.read_text(), 'keep me')
        self.assertEqual(list(self.destination.iterdir()), [sentinel])

    def test_symbolic_link_in_manifest_is_rejected(self):
        source = self.root / 'README.md'
        source.unlink()
        outside = Path(self.temp.name) / 'private.txt'
        outside.write_text('PRIVATE_TEST_SENTINEL')
        source.symlink_to(outside)
        result = self.run_export()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.destination.exists())

    def test_missing_required_file_fails_before_copy(self):
        (self.root / 'LICENSE').unlink()
        result = self.run_export()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.destination.exists())


if __name__ == '__main__':
    unittest.main()
