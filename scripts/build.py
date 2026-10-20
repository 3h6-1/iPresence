#!/usr/bin/env python3
# Original project by kainograze. Updated by 3h6_1.
"""Build with Apple's modern arm64e ABI and stage a standard /var/jb package."""
import argparse
from pathlib import Path
import shutil
import subprocess

from app_icons import stage_icons

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
    for tool in ('xcrun', 'ldid', 'sips') + (('dpkg-deb',) if args.package else ()):
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
              '-miphoneos-version-min=15.1', '-fobjc-arc', '-fblocks', '-O2',
              '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
              '-Wno-deprecated-declarations', '-framework', 'Foundation', '-framework', 'CoreFoundation']
    app_source = ROOT / 'iPresence/iPresence'
    daemon_source = ROOT / 'iPresence Daemon/iPresence Daemon'
    helper_source = ROOT / 'iPresence Springboard Helper/iPresence Springboard Helper'
    framework_source = ROOT / 'vendor/discord_social_sdk/lib/release/discord_partner_sdk.xcframework/ios-arm64/discord_partner_sdk.framework'
    if not (framework_source / 'discord_partner_sdk').is_file():
        raise SystemExit('Missing official Discord iOS SDK; run scripts/import_sdk.py with your Developer Portal ZIP download')
    framework = PREFIX / 'Library/Frameworks/discord_partner_sdk.framework'
    shutil.copytree(framework_source, framework)
    sdk_binary = framework / 'discord_partner_sdk'
    # Compile language-specific units separately, then link the C++ SDK wrapper.
    def build_client(name, source, destination, extra_frameworks=()):
        objects = []
        object_dir = BUILD / 'objects' / name
        object_dir.mkdir(parents=True, exist_ok=True)
        sources = sorted(source.glob('*.m')) + sorted(source.glob('*.mm')) + [ROOT / 'shared/IPOAuthStore.m']
        if name == 'app':
            sources += [ROOT / 'shared/IPAuthorizationAttempt.m', ROOT / 'shared/IPDiscordOAuthRequest.m',
                        ROOT / 'shared/IPDiagnostics.m']
        for unit in sources:
            obj = object_dir / (unit.name + '.o')
            flags = ['-std=c++20'] if unit.suffix == '.mm' else []
            run(*common[:-4], '-arch', 'arm64', '-I', ROOT / 'shared',
                '-isystem', ROOT / 'vendor/discord_social_sdk/include', *flags,
                '-c', unit, '-o', obj)
            objects.append(obj)
        run('xcrun', '--sdk', 'iphoneos', 'clang++', '-isysroot', sdk,
            '-miphoneos-version-min=15.1', '-arch', 'arm64', *objects,
            '-framework', 'Foundation', '-framework', 'CoreFoundation',
            *(['-F', framework_source.parent, '-framework', 'discord_partner_sdk',
               '-Wl,-rpath,/var/jb/Library/Frameworks'] if name == 'daemon' else []),
            *[part for item in extra_frameworks for part in ('-framework', item)], '-o', destination)
    build_client('app', app_source, app / 'iPresence', ('UIKit', 'AuthenticationServices', 'Security'))
    build_client('daemon', daemon_source, daemon, ('UIKit',))
    run(*common, '-arch', 'arm64', '-arch', 'arm64e', '-dynamiclib',
        '-Wl,-install_name,@rpath/iPresenceHelper.dylib',
        helper_source / 'iPresence_Springboard_Helper.m', '-o', helper)
    shutil.copy2(app_source / 'iPresence-Info.plist', app / 'Info.plist')
    stage_icons(ROOT / 'assets/ipresence-icon.png', app)
    shutil.copy2(helper_source / 'iPresence-Springboard-Helper.plist', helper.with_suffix('.plist'))
    shutil.copy2(ROOT / 'packaging/com.kainograze.iPresence-Daemon.plist', PREFIX / 'Library/LaunchDaemons/com.kainograze.iPresence-Daemon.plist')
    license_directory = PREFIX / 'usr/share/doc/com.kainograze.ipresence'
    license_directory.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / 'LICENSE', license_directory / 'copyright')
    shutil.copy2(ROOT / 'AUTHORS', license_directory / 'AUTHORS')
    run('ldid', '-S' + str(ROOT / 'packaging/app.entitlements.plist'), app / 'iPresence')
    run('ldid', '-S' + str(ROOT / 'packaging/daemon.entitlements.plist'), daemon)
    shutil.copy2(ROOT / 'vendor/discord_social_sdk/License-Notices.txt', license_directory / 'Discord-SDK-Notices.txt')
    run('ldid', '-S', sdk_binary)
    run('ldid', '-S', helper)
    for path in STAGE.rglob('*'):
        path.chmod(0o755 if path.is_dir() or path in (app / 'iPresence', daemon, helper, sdk_binary) else 0o644)
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
