#!/usr/bin/env python3
"""Build with Apple's modern arm64e ABI and stage a standard /var/jb package."""
import argparse
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'build'
STAGE = BUILD / 'stage'
PREFIX = STAGE / 'var/jb'

def run(*args):
    print('+', ' '.join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), check=True, cwd=ROOT)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', action='store_true')
    args = parser.parse_args()
    for tool in ('xcrun', 'ldid') + (('dpkg-deb',) if args.package else ()):
        if not shutil.which(tool):
            raise SystemExit(f'Missing {tool}; see README.md build requirements')
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
    shutil.rmtree(STAGE, ignore_errors=True)
    app = PREFIX / 'Applications/iPresence.app'
    daemon = PREFIX / 'usr/bin/ipresence-daemon'
    helper = PREFIX / 'Library/MobileSubstrate/DynamicLibraries/iPresenceHelper.dylib'
    for directory in (app, daemon.parent, helper.parent, PREFIX / 'Library/LaunchDaemons'):
        directory.mkdir(parents=True, exist_ok=True)
    STAGE.chmod(0o755)
    common = ['xcrun', '--sdk', 'iphoneos', 'clang', '-isysroot', sdk,
              '-miphoneos-version-min=15.0', '-fobjc-arc', '-fblocks', '-O2',
              '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
              '-Wno-deprecated-declarations', '-framework', 'Foundation', '-framework', 'CoreFoundation']
    app_source = ROOT / 'iPresence/iPresence'
    daemon_source = ROOT / 'iPresence Daemon/iPresence Daemon'
    helper_source = ROOT / 'iPresence Springboard Helper/iPresence Springboard Helper'
    # CLI/app processes use arm64 on both device families. SpringBoard needs its native arm64e slice.
    run(*common, '-arch', 'arm64', '-framework', 'UIKit',
        *(app_source / name for name in ('main.m', 'AppDelegate.m', 'ViewController.m')),
        '-o', app / 'iPresence')
    run(*common, '-arch', 'arm64', *sorted(daemon_source.glob('*.m')), '-o', daemon)
    run(*common, '-arch', 'arm64', '-arch', 'arm64e', '-dynamiclib',
        '-Wl,-install_name,@rpath/iPresenceHelper.dylib',
        helper_source / 'iPresence_Springboard_Helper.m', '-o', helper)
    shutil.copy2(app_source / 'iPresence-Info.plist', app / 'Info.plist')
    shutil.copy2(helper_source / 'iPresence-Springboard-Helper.plist', helper.with_suffix('.plist'))
    shutil.copy2(ROOT / 'packaging/com.kainograze.iPresence-Daemon.plist', PREFIX / 'Library/LaunchDaemons/com.kainograze.iPresence-Daemon.plist')
    license_directory = PREFIX / 'usr/share/doc/com.kainograze.ipresence'
    license_directory.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / 'LICENSE', license_directory / 'copyright')
    run('ldid', '-S' + str(ROOT / 'packaging/app.entitlements.plist'), app / 'iPresence')
    run('ldid', '-S' + str(ROOT / 'packaging/daemon.entitlements.plist'), daemon)
    run('ldid', '-S', helper)
    for path in STAGE.rglob('*'):
        path.chmod(0o755 if path.is_dir() or path in (app / 'iPresence', daemon, helper) else 0o644)
    if not args.package:
        return
    control = STAGE / 'DEBIAN'
    control.mkdir()
    control.chmod(0o755)
    for name in ('control', 'postinst', 'prerm'):
        shutil.copy2(ROOT / 'packaging' / name, control / name)
        (control / name).chmod(0o644 if name == 'control' else 0o755)
    fields = dict(line.split(': ', 1) for line in (control / 'control').read_text().splitlines() if ': ' in line and not line.startswith(' '))
    size = sum(p.stat().st_size for p in PREFIX.rglob('*') if p.is_file())
    with (control / 'control').open('a') as output:
        output.write(f'Installed-Size: {(size + 1023) // 1024}\n')
    packages = ROOT / 'packages'
    packages.mkdir(exist_ok=True)
    output = packages / f"{fields['Package']}_{fields['Version']}_{fields['Architecture']}.deb"
    run('dpkg-deb', '--root-owner-group', '-Zgzip', '--build', STAGE, output)
    print(f'Package: {output}')

if __name__ == '__main__':
    main()
