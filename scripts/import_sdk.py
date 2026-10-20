#!/usr/bin/env python3
# Original project by kainograze. Updated by 3h6_1.
"""Import the official Social SDK ZIP downloaded from Discord's Developer Portal."""
import argparse
from pathlib import Path, PurePosixPath
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('zip', type=Path)
    args = parser.parse_args()
    prefixes = ('discord_social_sdk/include/',
                'discord_social_sdk/lib/release/discord_partner_sdk.xcframework/')
    notice = 'discord_social_sdk/License-Notices.txt'
    with zipfile.ZipFile(args.zip) as archive:
        selected = [info for info in archive.infolist()
                    if info.filename.startswith(prefixes) or info.filename == notice]
        required = {'discord_social_sdk/include/discordpp.h', notice,
                    prefixes[1] + 'ios-arm64/discord_partner_sdk.framework/discord_partner_sdk'}
        if not required <= {info.filename for info in selected}:
            raise SystemExit('ZIP is missing the native iOS Social SDK')
        for info in selected:
            path = PurePosixPath(info.filename)
            if path.is_absolute() or '..' in path.parts or (info.external_attr >> 16) & 0o170000 == 0o120000:
                raise SystemExit('Unexpected path or symlink in SDK archive')
        destination = ROOT / 'vendor'
        destination.mkdir(exist_ok=True)
        for info in selected:
            archive.extract(info, destination)
    print('Imported official SDK into ignored vendor/ directory. SDK remains subject to Discord terms.')


if __name__ == '__main__':
    main()
