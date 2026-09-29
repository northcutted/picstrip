import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / 'ios_release.py'
spec = importlib.util.spec_from_file_location('platform_launcher', SCRIPT)
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)


class PlatformLauncherTest(unittest.TestCase):
    def fixture(self, root, revision='a' * 40):
        (root / '.github').mkdir()
        (root / '.github/ios-release-platform.json').write_text(json.dumps({
            'repository': 'northcutted/ios-release-workflows', 'revision': revision}))
        cached = root / 'build/ios-release-platform' / revision
        (cached / 'bin').mkdir(parents=True)
        (cached / 'bin/ios-release').write_text('# fixture')
        return cached

    def test_cache_must_match_the_pin_and_have_no_source_changes(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {}, clear=True):
            root = Path(tmp)
            cached = self.fixture(root)
            with patch.object(launcher, 'ROOT', root):
                for head, status in [('b' * 40, ''), ('a' * 40, ' M scripts/cli.py\n'), ('a' * 40, '?? unexpected.py\n')]:
                    with patch.object(launcher.subprocess, 'check_output', side_effect=[head, status]):
                        with self.assertRaisesRegex(ValueError, 'differs from the reviewed pin'):
                            launcher.platform_root()
                with patch.object(launcher.subprocess, 'check_output', side_effect=['a' * 40, '']):
                    self.assertEqual(launcher.platform_root(), cached)

    def test_mutable_revision_is_rejected_even_with_an_override(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.fixture(root, 'main')
            with patch.object(launcher, 'ROOT', root), patch.dict(os.environ, {'IOS_RELEASE_ROOT': tmp}):
                with self.assertRaisesRegex(ValueError, 'full platform commit'):
                    launcher.platform_root()

    def test_trusted_override_still_requires_the_public_interface(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.fixture(root)
            with patch.object(launcher, 'ROOT', root), patch.dict(os.environ, {'IOS_RELEASE_ROOT': tmp}):
                with self.assertRaisesRegex(ValueError, 'supported command interface'):
                    launcher.platform_root()


if __name__ == '__main__':
    unittest.main()
