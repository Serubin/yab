#!/usr/bin/env python3
"""Filesystem contracts used by CEF loading and native-messaging caller validation."""
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import os
import subprocess
import unittest

spec = importlib.util.spec_from_file_location('package_core', Path(__file__).with_name('package_core.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CoreBundleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.app = Path(self.tmp.name) / 'Yab.app'
        self.contents = self.app / 'Contents'
        (self.contents / 'MacOS').mkdir(parents=True)
        self.legacy = self.contents / 'MacOS/PaneCore'
        self.legacy.write_bytes(b'first executable')
        self.parent = dict(CFBundleIdentifier='dev.serafim.fast', CFBundleVersion='202611091715',
                           CFBundleShortVersionString='0.47.6', LSMinimumSystemVersion='15.4',
                           NSAppleScriptEnabled=True, OSAScriptingDefinition='Yab.sdef',
                           NSSupportsAutomaticTermination=True, NSSupportsSuddenTermination=True)
        (self.contents / 'Info.plist').write_bytes(plistlib.dumps(self.parent))
        self.framework = self.contents / 'Frameworks/Chromium Embedded Framework.framework'
        self.framework.mkdir(parents=True)
        (self.framework / 'payload').write_bytes(b'untouched framework')
        self.renderer = self.contents / 'Frameworks/PaneCore Helper (Renderer).app'
        for name in module.PAYLOADS[1:]:
            (self.contents / 'Frameworks' / name).mkdir()

    def test_own_identity_before_appkit_registration(self):
        bundle = module.package(self.app)
        info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleIdentifier'], 'dev.serafim.fast.core')
        self.assertTrue(info['LSUIElement'])
        self.assertEqual(info['CFBundleExecutable'], 'PaneCore')
        self.assertNotIn('NSAppleScriptEnabled', info)
        self.assertNotIn('OSAScriptingDefinition', info)
        self.assertEqual(plistlib.loads((self.contents / 'Info.plist').read_bytes()), self.parent)

    def test_engine_is_not_a_disposable_background_application(self):
        # Yab owns this process even when Chromium has no visible native window.
        bundle = module.package(self.app)
        info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
        self.assertIs(info.get('NSSupportsAutomaticTermination'), False)
        self.assertIs(info.get('NSSupportsSuddenTermination'), False)
        self.assertEqual(plistlib.loads((self.contents / 'Info.plist').read_bytes()), self.parent)

    def test_standalone_engine_has_the_same_termination_policy(self):
        template = Path(__file__).resolve().parents[2] / 'YabCore/src/Info.plist.in'
        info = plistlib.loads(template.read_bytes())
        self.assertIs(info.get('NSSupportsAutomaticTermination'), False)
        self.assertIs(info.get('NSSupportsSuddenTermination'), False)

    def test_cef_and_native_host_paths_survive_app_relocation(self):
        module.package(self.app)
        moved = self.app.with_name('Yab.app.old')
        self.app.rename(moved)
        legacy = moved / 'Contents/MacOS/PaneCore'
        binary = moved / 'Contents/Frameworks/PaneCore.app/Contents/MacOS/PaneCore'
        self.assertEqual(legacy.resolve(strict=True), binary.resolve(strict=True))
        self.assertEqual(binary.read_bytes(), b'first executable')
        framework = binary.parent.parent / 'Frameworks/Chromium Embedded Framework.framework/payload'
        self.assertEqual(framework.read_bytes(), b'untouched framework')
        self.assertFalse(framework.parent.is_symlink())
        self.assertFalse(framework.parent.parent.is_symlink())
        self.assertTrue((binary.parent.parent / 'Frameworks/PaneCore Helper (Renderer).app').is_dir())

    def test_reembedding_replaces_only_owned_bundle(self):
        module.package(self.app)
        self.legacy.unlink()
        self.legacy.write_bytes(b'new executable')
        for name in module.PAYLOADS:
            source = self.contents / 'Frameworks' / name
            source.unlink()
            source.mkdir()
            if name == module.PAYLOADS[0]:
                (source / 'payload').write_bytes(b'untouched framework')
        module.package(self.app)
        self.assertEqual(self.legacy.read_bytes(), b'new executable')
        self.assertEqual((self.framework / 'payload').read_bytes(), b'untouched framework')
        self.assertTrue(self.renderer.is_dir())

    def test_obsolete_flat_receipt_refuses_before_changing_app(self):
        self.legacy.chmod(0o700)
        before = self.legacy.read_bytes()
        embed = Path(__file__).with_name('embed.sh')
        result = subprocess.run(['bash', str(embed), str(self.app), '/missing-sdk',
                                 str(self.legacy), '-'], capture_output=True, text=True,
                                env=dict(os.environ, YABCORE_PREPARED_HELPER_INPUT='/old/receipt.json'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('receipts must be regenerated', result.stderr)
        self.assertEqual(self.legacy.read_bytes(), before)
        self.assertFalse((self.contents / 'Frameworks/PaneCore.app').exists())

    def test_refuses_to_move_an_existing_alias(self):
        module.package(self.app)
        with self.assertRaises(RuntimeError):
            module.package(self.app)
        self.assertEqual(self.legacy.read_bytes(), b'first executable')


if __name__ == '__main__':
    unittest.main()
