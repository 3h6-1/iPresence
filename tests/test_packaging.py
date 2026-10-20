# Original project by kainograze. Updated by 3h6_1.
"""Regression checks for package safety and compatibility boundaries; no device needed."""
import importlib.util
import os
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import app_icons

spec = importlib.util.spec_from_file_location('verify_package', ROOT / 'scripts/verify_package.py')
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


def member(name, directory=False):
    result = tarfile.TarInfo(name)
    result.type = tarfile.DIRTYPE if directory else tarfile.REGTYPE
    result.mode = 0o755 if directory or name in verify.BINARIES else 0o644
    result.uid = result.gid = 0
    return result


def png_bytes(size, alpha=False, transparency=False):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    header = struct.pack('>IIBBBBB', size, size, 8, 6 if alpha else 2, 0, 0, 0)
    row = b'\x00' + bytes((255, 40, 110, 255) if alpha else (255, 40, 110)) * size
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) +
            (chunk(b'tRNS', b'\x00\xff\x00\x28\x00\x6e') if transparency else b'') +
            chunk(b'IDAT', zlib.compress(row * size)) + chunk(b'IEND', b''))


def write_icon_fixture(app):
    info_path = app / 'Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    info.update(app_icons.icon_metadata())
    info_path.write_bytes(plistlib.dumps(info))
    for name, size in app_icons.ICON_SIZES.items():
        (app / name).write_bytes(png_bytes(size))


class PackageRegressionTests(unittest.TestCase):
    def payload(self):
        names = (list(verify.BINARIES) + [f'{verify.APP}/Info.plist', f'{verify.HELPER}.plist', verify.LAUNCHD] +
                 [f'{verify.APP}/{name}' for name in app_icons.ICON_SIZES])
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

    def test_archive_rejects_missing_home_screen_icon(self):
        payload = self.payload()
        with self.assertRaises(verify.VerificationError):
            verify.validate_archive([item for item in payload if item.name != f'{verify.APP}/AppIcon60x60@3x.png'])

    def test_control_preserves_description_and_compatibility_limits(self):
        fields = verify.read_control((ROOT / 'packaging/control').read_text())
        verify.validate_control(fields)
        self.assertIn('\n', fields['Description'])
        for field, value in (('Architecture', 'iphoneos-arm'), ('Architecture', 'iphoneos-arm64e'),
                             ('Depends', 'firmware (>= 15.1), mobilesubstrate, uikittools'),
                             ('Depends', 'firmware (>= 15.1), firmware (<< 26.0.2), mobilesubstrate, uikittools')):
            modified = dict(fields, **{field: value})
            with self.subTest(field=field, value=value), self.assertRaises(verify.VerificationError):
                verify.validate_control(modified)

    def test_control_rejects_duplicate_architecture(self):
        with self.assertRaises(verify.VerificationError):
            verify.read_control('Architecture: iphoneos-arm64\nArchitecture: iphoneos-arm\n')

    def test_load_commands_reject_simulator_newer_minimum_and_unsigned_binary(self):
        commands = 'cmd LC_BUILD_VERSION\ncmdsize 32\nplatform 2\nminos 15.1\nsdk 27.1\ncmd LC_CODE_SIGNATURE\ncmdsize 16\ndataoff 4096\ndatasize 1024\n'
        verify.validate_load_commands(commands, 'helper', 'arm64e')
        mutations = (commands.replace('platform 2', 'platform 7'),
                     commands.replace('minos 15.1', 'minos 26.0'),
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
            write_icon_fixture(root / verify.APP)
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

    def test_icons_validate_both_device_families_and_required_sizes(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary)
            (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleVersion': 'fixture'}))
            write_icon_fixture(app)
            app_icons.validate_icons(app)
            self.assertTrue({120, 180} <= set(app_icons.IPHONE_ICONS.values()))
            self.assertTrue({76, 152, 167} <= set(app_icons.IPAD_ICONS.values()))
            self.assertEqual(app_icons.opaque_png_size(ROOT / 'assets/ipresence-icon.png'), (1024, 1024))

    def test_icons_reject_missing_reference_wrong_size_and_transparency(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary)
            info_path = app / 'Info.plist'
            info_path.write_bytes(plistlib.dumps({}))
            write_icon_fixture(app)
            original_info = info_path.read_bytes()
            info = plistlib.loads(original_info)
            info['CFBundleIcons']['CFBundlePrimaryIcon']['CFBundleIconFiles'].remove('AppIcon60x60@3x.png')
            info_path.write_bytes(plistlib.dumps(info))
            with self.assertRaises(ValueError):
                app_icons.validate_icons(app)
            info_path.write_bytes(original_info)
            icon = app / 'AppIcon60x60@3x.png'
            for content in (png_bytes(120), png_bytes(180, alpha=True), png_bytes(180, transparency=True), b'not PNG'):
                icon.write_bytes(content)
                with self.subTest(content=content[:32]), self.assertRaises(ValueError):
                    app_icons.validate_icons(app)
            icon.unlink()
            with self.assertRaises(ValueError):
                app_icons.validate_icons(app)

    def test_icons_reject_truncation_corruption_and_links(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary)
            icon = app / 'icon.png'
            valid = png_bytes(120)
            for invalid in (valid[:-12], valid + b'extra', valid[:20] + b'\xff' + valid[21:]):
                icon.write_bytes(invalid)
                with self.subTest(length=len(invalid)), self.assertRaises(ValueError):
                    app_icons.opaque_png_size(icon)
            icon.write_bytes(valid)
            link = app / 'link.png'
            link.symlink_to(icon)
            with self.assertRaises(ValueError):
                app_icons.opaque_png_size(link)

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


class MaintainerScriptTests(unittest.TestCase):
    launchctl_paths = ('/var/jb/bin/launchctl', '/var/jb/usr/bin/launchctl', '/bin/launchctl')
    label = 'system/com.kainograze.iPresence-Daemon'
    plist = '/var/jb/Library/LaunchDaemons/com.kainograze.iPresence-Daemon.plist'
    app = '/var/jb/Applications/iPresence.app'

    def run_script(self, script, action, locations=None, bootout_status=0, bootstrap_status=0, uicache_status=0):
        # Rewrite absolute paths in a temporary copy, never in the shipped
        # scripts. Every possible launchctl and uicache invocation is a stub;
        # the host's launchd and applications cannot be reached by this fixture.
        if locations is None:
            locations = {self.launchctl_paths[0]: 'file'}
        with tempfile.TemporaryDirectory(prefix='ipresence-maintainer-') as temporary:
            root = Path(temporary)
            log = root / 'commands.log'
            stub = '''#!/bin/sh
printf '%s' "$0" >> "$IP_TEST_COMMAND_LOG"
printf '\\t%s' "$@" >> "$IP_TEST_COMMAND_LOG"
printf '\\n' >> "$IP_TEST_COMMAND_LOG"
case "$1" in
    bootout) exit "$IP_TEST_BOOTOUT_STATUS" ;;
    bootstrap) exit "$IP_TEST_BOOTSTRAP_STATUS" ;;
    -p|-u) exit "$IP_TEST_UICACHE_STATUS" ;;
esac
exit 99
'''
            commands = dict(locations, **{'/var/jb/usr/bin/uicache': 'file'})
            for absolute, kind in commands.items():
                path = root / absolute.lstrip('/')
                path.parent.mkdir(parents=True, exist_ok=True)
                if kind == 'directory':
                    path.mkdir()
                elif kind == 'symlink':
                    path.symlink_to(root / 'var/jb/usr/bin/launchctl')
                else:
                    path.write_text(stub)
                    path.chmod(0o755 if kind == 'file' else 0o644)
            original = (ROOT / 'packaging' / script).read_text()
            isolated = re.sub(r'/var/jb(?:/[A-Za-z0-9._+-]+)*|/bin/launchctl',
                              lambda match: str(root / match.group().lstrip('/')), original)
            fixture = root / script
            fixture.write_text(isolated)
            environment = {'PATH': str(root / 'empty-path'), 'DPKG_ROOT': '',
                           'IP_TEST_COMMAND_LOG': str(log), 'IP_TEST_BOOTOUT_STATUS': str(bootout_status),
                           'IP_TEST_BOOTSTRAP_STATUS': str(bootstrap_status),
                           'IP_TEST_UICACHE_STATUS': str(uicache_status)}
            result = subprocess.run(['/bin/sh', str(fixture), action], env=environment,
                                    capture_output=True, text=True, timeout=5)
            calls = [[part.removeprefix(str(root)) for part in line.split('\t')]
                     for line in log.read_text().splitlines()] if log.exists() else []
            return result, calls

    def test_launchctl_selection_prefers_rootless_and_checks_executability(self):
        choices = [
            ({path: 'file' for path in self.launchctl_paths}, self.launchctl_paths[0]),
            ({path: 'file' for path in self.launchctl_paths[1:]}, self.launchctl_paths[1]),
            ({self.launchctl_paths[2]: 'file'}, self.launchctl_paths[2]),
            ({self.launchctl_paths[0]: 'nonexecutable', self.launchctl_paths[1]: 'file'}, self.launchctl_paths[1]),
            ({self.launchctl_paths[0]: 'directory', self.launchctl_paths[1]: 'file'}, self.launchctl_paths[1]),
            ({self.launchctl_paths[0]: 'symlink', self.launchctl_paths[1]: 'file'}, self.launchctl_paths[0]),
        ]
        for script, action in (('postinst', 'configure'), ('prerm', 'remove')):
            for locations, expected in choices:
                with self.subTest(script=script, locations=locations):
                    result, calls = self.run_script(script, action, locations)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    launch_calls = [call for call in calls if call[0].endswith('/launchctl')]
                    self.assertTrue(launch_calls)
                    self.assertTrue(all(call[0] == expected for call in launch_calls), calls)

    def test_configure_bootstraps_correct_job_after_optional_unload(self):
        result, calls = self.run_script('postinst', 'configure', bootout_status=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [
            ['/var/jb/usr/bin/uicache', '-p', self.app],
            [self.launchctl_paths[0], 'bootout', self.label],
            [self.launchctl_paths[0], 'bootstrap', 'system', self.plist],
        ])
        self.assertIn('iPresence installed.', result.stdout)

    def test_configure_preserves_bootstrap_failure_and_never_prints_success(self):
        result, calls = self.run_script('postinst', 'configure', bootstrap_status=42)
        self.assertEqual(result.returncode, 42)
        self.assertEqual(calls[-1], [self.launchctl_paths[0], 'bootstrap', 'system', self.plist])
        self.assertIn('bootstrap failed (status 42)', result.stderr)
        self.assertNotIn('iPresence installed.', result.stdout)

    def test_configure_without_launchctl_fails_before_changing_registration(self):
        result, calls = self.run_script('postinst', 'configure', {})
        self.assertEqual(result.returncode, 1)
        self.assertIn('launchctl was not found', result.stderr)
        self.assertEqual(calls, [])
        self.assertNotIn('iPresence installed.', result.stdout)

    def test_icon_registration_failure_prevents_daemon_start(self):
        result, calls = self.run_script('postinst', 'configure', uicache_status=23)
        self.assertEqual(result.returncode, 23)
        self.assertEqual(calls, [['/var/jb/usr/bin/uicache', '-p', self.app]])
        self.assertNotIn('iPresence installed.', result.stdout)

    def test_removal_unloads_and_unregisters_only_on_remove(self):
        for action in ('remove', 'upgrade', 'deconfigure'):
            with self.subTest(action=action):
                result, calls = self.run_script('prerm', action, bootout_status=3)
                self.assertEqual(result.returncode, 0, result.stderr)
                expected = [[self.launchctl_paths[0], 'bootout', self.label]]
                if action == 'remove':
                    expected.append(['/var/jb/usr/bin/uicache', '-u', self.app])
                self.assertEqual(calls, expected)

    def test_missing_launchctl_warns_without_trapping_package_removal(self):
        for action in ('remove', 'upgrade', 'deconfigure'):
            with self.subTest(action=action):
                result, calls = self.run_script('prerm', action, {})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('daemon could not be unloaded', result.stderr)
                self.assertEqual(calls, [['/var/jb/usr/bin/uicache', '-u', self.app]] if action == 'remove' else [])


if __name__ == '__main__':
    unittest.main()
