"""Regression checks for package safety and compatibility boundaries; no device needed."""
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('verify_package', ROOT / 'scripts/verify_package.py')
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


def member(name, directory=False):
    result = tarfile.TarInfo(name)
    result.type = tarfile.DIRTYPE if directory else tarfile.REGTYPE
    result.mode = 0o755 if directory or name in verify.BINARIES else 0o644
    result.uid = result.gid = 0
    return result


class PackageRegressionTests(unittest.TestCase):
    def payload(self):
        names = list(verify.BINARIES) + [f'{verify.APP}/Info.plist', f'{verify.HELPER}.plist', verify.LAUNCHD]
        return [member('.', True), member('var', True), member('var/jb', True)] + [member(name) for name in names]

    def test_archive_accepts_rootless_payload(self):
        verify.validate_archive(self.payload())

    def test_archive_rejects_rootful_and_traversal_paths(self):
        for name in ('usr/bin/ipresence-daemon', '/var/jb/evil', 'var/jb/../../evil'):
            with self.subTest(name=name), self.assertRaises(verify.VerificationError):
                verify.validate_archive(self.payload() + [member(name)])

    def test_archive_rejects_bad_ownership_modes_and_links(self):
        for attribute, value in (('uid', 501), ('gid', 20), ('mode', 0o777), ('mode', 0o4755), ('type', tarfile.SYMTYPE)):
            payload = self.payload()
            setattr(payload[-1], attribute, value)
            with self.subTest(attribute=attribute, value=value), self.assertRaises(verify.VerificationError):
                verify.validate_archive(payload)

    def test_archive_rejects_missing_binary_and_duplicates(self):
        payload = self.payload()
        with self.assertRaises(verify.VerificationError):
            verify.validate_archive([item for item in payload if item.name != verify.DAEMON])
        with self.assertRaises(verify.VerificationError):
            verify.validate_archive(payload + [member(verify.DAEMON)])

    def test_control_preserves_description_and_compatibility_limits(self):
        fields = verify.read_control((ROOT / 'packaging/control').read_text())
        verify.validate_control(fields)
        self.assertIn('\n', fields['Description'])
        for field, value in (('Architecture', 'iphoneos-arm'), ('Architecture', 'iphoneos-arm64e'),
                             ('Depends', 'firmware (>= 15.0), mobilesubstrate, uikittools')):
            modified = dict(fields, **{field: value})
            with self.subTest(field=field, value=value), self.assertRaises(verify.VerificationError):
                verify.validate_control(modified)

    def test_control_rejects_duplicate_architecture(self):
        with self.assertRaises(verify.VerificationError):
            verify.read_control('Architecture: iphoneos-arm64\nArchitecture: iphoneos-arm\n')

    def test_load_commands_reject_simulator_newer_minimum_and_unsigned_binary(self):
        commands = 'cmd LC_BUILD_VERSION\ncmdsize 32\nplatform 2\nminos 15.0\nsdk 27.1\ncmd LC_CODE_SIGNATURE\ncmdsize 16\ndataoff 4096\ndatasize 1024\n'
        verify.validate_load_commands(commands, 'helper', 'arm64e')
        mutations = (commands.replace('platform 2', 'platform 7'),
                     commands.replace('minos 15.0', 'minos 26.0'),
                     commands.replace('datasize 1024', 'datasize 0'),
                     commands + 'cmd LC_LOAD_DYLIB\ncmdsize 56\nname /Library/Frameworks/Legacy.framework/Legacy (offset 24)\n')
        for invalid in mutations:
            with self.subTest(commands=invalid), self.assertRaises(verify.VerificationError):
                verify.validate_load_commands(invalid, 'helper', 'arm64e')

    def test_layout_rejects_root_daemon_wrong_path_and_broad_injection(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sources = {f'{verify.APP}/Info.plist': ROOT / 'iPresence/iPresence/iPresence-Info.plist',
                       f'{verify.HELPER}.plist': ROOT / 'iPresence Springboard Helper/iPresence Springboard Helper/iPresence-Springboard-Helper.plist',
                       verify.LAUNCHD: ROOT / 'packaging/com.kainograze.iPresence-Daemon.plist'}
            for relative, source in sources.items():
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(source.read_bytes())
            verify.validate_layout(root)
            launchd_path = root / verify.LAUNCHD
            original = plistlib.loads(launchd_path.read_bytes())
            for mutation in ({'UserName': 'root'}, {'ProgramArguments': ['/usr/bin/ipresence-daemon']}, {'Umask': 0}):
                launchd_path.write_bytes(plistlib.dumps(dict(original, **mutation)))
                with self.subTest(mutation=mutation), self.assertRaises(verify.VerificationError):
                    verify.validate_layout(root)
            launchd_path.write_bytes(plistlib.dumps(original))
            (root / (verify.HELPER + '.plist')).write_bytes(plistlib.dumps({'Filter': {'Bundles': ['com.apple.UIKit']}}))
            with self.assertRaises(verify.VerificationError):
                verify.validate_layout(root)

    def test_maintainer_scripts_skip_offline_root_and_noop_lifecycle_actions(self):
        with tempfile.TemporaryDirectory() as temporary:
            for script, actions in {'postinst': ('configure', 'abort-upgrade'), 'prerm': ('remove', 'upgrade', 'deconfigure')}.items():
                path = ROOT / 'packaging' / script
                subprocess.run(['/bin/sh', '-n', str(path)], check=True)
                for action in actions:
                    result = subprocess.run(['/bin/sh', str(path), action], env=dict(os.environ, DPKG_ROOT=temporary),
                                            capture_output=True, text=True, timeout=5)
                    with self.subTest(script=script, action=action):
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(result.stdout, '')
                        self.assertEqual(result.stderr, '')
                result = subprocess.run(['/bin/sh', str(path), 'unhandled-action'], env=dict(os.environ, DPKG_ROOT=''),
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
