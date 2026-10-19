#!/usr/bin/env python3
"""Inspect the built .deb without installing it or executing its payload."""
import argparse
import io
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = 'var/jb/Applications/iPresence.app'
DAEMON = 'var/jb/usr/bin/ipresence-daemon'
HELPER = 'var/jb/Library/MobileSubstrate/DynamicLibraries/iPresenceHelper'
LABEL = 'com.kainograze.iPresence-Daemon'
LAUNCHD = f'var/jb/Library/LaunchDaemons/{LABEL}.plist'
BINARIES = {f'{APP}/iPresence': {'arm64'}, DAEMON: {'arm64'},
            f'{HELPER}.dylib': {'arm64', 'arm64e'}}


class VerificationError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def read_control(text):
    fields = {}
    previous = None
    for line in text.splitlines():
        if not line:
            continue
        if line[0].isspace():
            require(previous is not None, 'Control continuation has no field')
            fields[previous] += '\n' + line.strip()
            continue
        key, separator, value = line.partition(':')
        require(separator and key not in fields, f'Malformed or duplicate control field: {key}')
        previous = key
        fields[key] = value.strip()
    return fields


def validate_control(fields):
    require(fields.get('Architecture') == 'iphoneos-arm64', 'Package must use iphoneos-arm64 architecture')
    require(fields.get('Package') == 'com.kainograze.ipresence', 'Unexpected package identifier')
    require(bool(fields.get('Version')), 'Package version is missing')
    dependencies = fields.get('Depends', '')
    require(re.search(r'firmware\s*\(>=\s*15\.0\)', dependencies), 'Missing iOS 15 minimum dependency')
    require(re.search(r'firmware\s*\(<<\s*26\.0\.2\)', dependencies), 'Missing iOS 26.0.1 upper boundary')
    for dependency in ('mobilesubstrate', 'uikittools'):
        require(re.search(r'(?:^|,)\s*' + dependency + r'(?:\s|,|$)', dependencies),
                f'Missing runtime dependency: {dependency}')


def archive_name(name):
    path = PurePosixPath(name)
    require(not path.is_absolute() and '..' not in path.parts, f'Unsafe archive path: {name}')
    return str(path)


def validate_archive(members, control=False):
    """Check tar headers before allowing dpkg-deb to extract anything."""
    seen = set()
    for member in members:
        name = archive_name(member.name)
        require(name not in seen, f'Duplicate archive member: {name}')
        seen.add(name)
        require(member.isdir() or member.isfile(), f'Unsupported archive member type: {name}')
        require(member.uid == 0 and member.gid == 0, f'Archive member is not root-owned: {name}')
        if not control:
            require(name in ('.', 'var', 'var/jb') or name.startswith('var/jb/'),
                    f'Payload escapes /var/jb: {name}')
        else:
            require(name in ('.', 'control', 'postinst', 'prerm'), f'Unexpected control archive member: {name}')
        expected_mode = 0o755 if member.isdir() or name in BINARIES or (control and name in ('postinst', 'prerm')) else 0o644
        require(member.mode == expected_mode,
                f'Incorrect mode for {name}: {member.mode:o}, expected {expected_mode:o}')
    required = {'control', 'postinst', 'prerm'} if control else set(BINARIES) | {f'{APP}/Info.plist', f'{HELPER}.plist', LAUNCHD}
    require(required <= seen, f'Missing archive members: {sorted(required - seen)}')


def load_plist(path):
    with path.open('rb') as source:
        result = plistlib.load(source)
    require(isinstance(result, dict), f'Expected plist dictionary: {path.name}')
    return result


def validate_layout(root):
    info = load_plist(root / APP / 'Info.plist')
    require(info.get('CFBundleExecutable') == 'iPresence', 'App executable differs from packaged binary')
    require(info.get('CFBundleIdentifier') == 'com.kainograze.iPresence', 'Unexpected app bundle identifier')
    require(info.get('MinimumOSVersion') == '15.0', 'App minimum OS must be 15.0')
    require('arm64' in info.get('UIRequiredDeviceCapabilities', []), 'App must require arm64')
    injection = load_plist(root / (HELPER + '.plist')).get('Filter', {})
    require(injection == {'Bundles': ['com.apple.springboard']}, 'Helper must inject only into SpringBoard')
    launchd = load_plist(root / LAUNCHD)
    require(launchd.get('Label') == LABEL, 'Unexpected launchd label')
    require(launchd.get('ProgramArguments') == ['/' + DAEMON], 'launchd references the wrong daemon path')
    require('Program' not in launchd or launchd['Program'] == '/' + DAEMON, 'Conflicting launchd Program')
    require(launchd.get('UserName') == 'mobile' and launchd.get('GroupName') == 'mobile', 'Daemon must run as mobile')
    require(launchd.get('EnvironmentVariables', {}).get('HOME') == '/var/mobile', 'Daemon HOME must match mobile preferences')
    require(launchd.get('RunAtLoad') is True and launchd.get('KeepAlive') is True, 'Daemon lifecycle configuration is missing')
    require(isinstance(launchd.get('Umask'), int) and launchd['Umask'] & 0o077 == 0o077, 'Daemon umask exposes private files')
    require(launchd.get('ThrottleInterval', 0) >= 10, 'Daemon needs a restart throttle')


def validate_load_commands(text, binary, architecture):
    description = f'{binary} ({architecture})'
    versions = re.findall(r'cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform (\S+)\s+minos (\S+)', text)
    require(len(versions) == 1, f'{description}: missing or ambiguous LC_BUILD_VERSION')
    platform, minimum = versions[0]
    require(platform in ('2', 'IOS'), f'{description}: not an iOS device binary')
    require(tuple(map(int, minimum.split('.'))) in ((15, 0), (15, 0, 0)), f'{description}: minimum OS is {minimum}, expected 15.0')
    signature = re.search(r'cmd LC_CODE_SIGNATURE\s+cmdsize \d+\s+dataoff (\d+)\s+datasize (\d+)', text)
    require(signature is not None and int(signature[1]) > 0 and int(signature[2]) > 0,
            f'{description}: embedded code signature is missing')
    for name in re.findall(r'cmd LC_(?:LOAD|LOAD_WEAK|REEXPORT)_DYLIB\s+cmdsize \d+\s+name (.+?) \(offset', text):
        require(name.startswith(('/System/Library/', '/usr/lib/', '@rpath/')),
                f'{description}: non-rootless library dependency: {name}')


def output(*command):
    return subprocess.check_output([str(item) for item in command], stderr=subprocess.PIPE)


def verify_binaries(root):
    for relative, required_architectures in BINARIES.items():
        path = root / relative
        architectures = set(output('xcrun', 'lipo', '-archs', path).decode().split())
        require(required_architectures <= architectures <= {'arm64', 'arm64e'},
                f'{relative}: incorrect slices {sorted(architectures)}')
        for architecture in sorted(architectures):
            commands = output('xcrun', 'otool', '-arch', architecture, '-l', path).decode()
            validate_load_commands(commands, relative, architecture)
        # ldid signatures are jailbreak signatures, not Apple distribution signatures.
        # LC_CODE_SIGNATURE checks their presence; device trust still requires a jailbreak.
        entitlements = output('ldid', '-e', path).strip()
        parsed = plistlib.loads(entitlements) if entitlements else {}
        if relative == f'{APP}/iPresence':
            require(parsed.get('com.apple.private.security.no-container') is True,
                    'App cannot access shared preferences without no-container entitlement')
        if relative in (f'{APP}/iPresence', DAEMON):
            require(parsed.get('platform-application') is True, f'{relative}: platform entitlement missing')
        else:
            require(not parsed, 'Injected helper should inherit host privileges, not carry entitlements')
        require(not parsed.get('get-task-allow') and not parsed.get('task_for_pid-allow'),
                f'{relative}: unexpected debug entitlement')
        print(f'  {relative}: {", ".join(sorted(architectures))}; iOS 15.0; embedded signature')


def verify_package(package):
    require(package.is_file(), f'Package does not exist: {package}')
    for argument, control in (('--fsys-tarfile', False), ('--ctrl-tarfile', True)):
        with tarfile.open(fileobj=io.BytesIO(output('dpkg-deb', argument, package)), mode='r:') as archive:
            validate_archive(archive.getmembers(), control=control)
    with tempfile.TemporaryDirectory(prefix='ipresence-verify-') as temporary:
        root = Path(temporary)
        output('dpkg-deb', '--extract', package, root)
        output('dpkg-deb', '--control', package, root / 'DEBIAN')
        fields = read_control((root / 'DEBIAN/control').read_text())
        validate_control(fields)
        validate_layout(root)
        for script in ('postinst', 'prerm'):
            path = root / 'DEBIAN' / script
            require(path.read_text().startswith('#!/var/jb/bin/sh\n'), f'{script}: incorrect rootless interpreter')
            output('/bin/sh', '-n', path)
        verify_binaries(root)
    print(f'Verified {package.name}: rootless layout, metadata, permissions, plists, and Mach-O slices.')
    print('Runtime behavior and jailbreak signature trust still require testing on a device.')


def main():
    fields = read_control((ROOT / 'packaging/control').read_text())
    default = ROOT / 'packages' / f"{fields['Package']}_{fields['Version']}_{fields['Architecture']}.deb"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package', nargs='?', type=Path, default=default)
    args = parser.parse_args()
    for tool in ('dpkg-deb', 'xcrun', 'ldid'):
        require(shutil.which(tool), f'Missing verification tool: {tool}')
    verify_package(args.package.resolve())


if __name__ == '__main__':
    try:
        main()
    except (VerificationError, subprocess.CalledProcessError, OSError, plistlib.InvalidFileException) as error:
        raise SystemExit(f'Package verification failed: {error}')
