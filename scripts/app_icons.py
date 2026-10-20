#!/usr/bin/env python3
# Original project by kainograze. Updated by 3h6_1.
"""Stage and verify loose PNG app icons without Xcode or an asset catalog."""
from pathlib import Path
import plistlib
import struct
import subprocess
import zlib


IPHONE_ICONS = {
    'AppIcon20x20@2x.png': 40,
    'AppIcon20x20@3x.png': 60,
    'AppIcon29x29@2x.png': 58,
    'AppIcon29x29@3x.png': 87,
    'AppIcon40x40@2x.png': 80,
    'AppIcon40x40@3x.png': 120,
    'AppIcon60x60@2x.png': 120,
    'AppIcon60x60@3x.png': 180,
}
IPAD_ICONS = {
    'AppIcon20x20~ipad.png': 20,
    'AppIcon20x20@2x~ipad.png': 40,
    'AppIcon29x29~ipad.png': 29,
    'AppIcon29x29@2x~ipad.png': 58,
    'AppIcon40x40~ipad.png': 40,
    'AppIcon40x40@2x~ipad.png': 80,
    'AppIcon76x76~ipad.png': 76,
    'AppIcon76x76@2x~ipad.png': 152,
    'AppIcon83.5x83.5@2x~ipad.png': 167,
}
ICON_SIZES = {**IPHONE_ICONS, **IPAD_ICONS}


def opaque_png_size(path):
    """Read PNG dimensions and reject alpha channels or palette transparency."""
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 16 * 1024 * 1024:
        raise ValueError(f'Icon must be a regular PNG file: {path.name}')
    data = path.read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError(f'Icon is not a PNG: {path.name}')
    offset = 8
    dimensions = None
    image_data = False
    while offset + 12 <= len(data):
        length = struct.unpack_from('>I', data, offset)[0]
        end = offset + 12 + length
        if end > len(data):
            break
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        crc = struct.unpack_from('>I', data, offset + 8 + length)[0]
        if zlib.crc32(kind + payload) & 0xffffffff != crc:
            raise ValueError(f'Icon has an invalid PNG checksum: {path.name}')
        if dimensions is None and kind != b'IHDR':
            raise ValueError(f'Icon has no PNG header: {path.name}')
        if kind == b'IHDR':
            if dimensions is not None or length != 13:
                raise ValueError(f'Icon has an invalid PNG header: {path.name}')
            width, height, depth, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', payload)
            if color not in (0, 2, 3) or depth not in (1, 2, 4, 8, 16):
                raise ValueError(f'Icon must have no alpha channel: {path.name}')
            if not width or not height or compression or filtering or interlace not in (0, 1):
                raise ValueError(f'Icon has an invalid PNG header: {path.name}')
            dimensions = (width, height)
        elif kind in (b'tRNS', b'acTL'):
            raise ValueError(f'Icon must be opaque and static: {path.name}')
        elif kind == b'IDAT':
            image_data = True
        elif kind == b'IEND':
            if length or end != len(data) or not image_data:
                break
            return dimensions
        offset = end
    raise ValueError(f'Icon is an incomplete PNG: {path.name}')


def icon_metadata():
    return {
        key: {'CFBundlePrimaryIcon': {'CFBundleIconFiles': list(icons), 'UIPrerenderedIcon': True}}
        for key, icons in (('CFBundleIcons', IPHONE_ICONS), ('CFBundleIcons~ipad', IPAD_ICONS))
    }


def validate_icons(app_path, info=None):
    """Check the plist references and every required opaque image at its exact size."""
    app_path = Path(app_path)
    if info is None:
        info = plistlib.loads((app_path / 'Info.plist').read_bytes())
    for key, expected in icon_metadata().items():
        if info.get(key) != expected:
            raise ValueError(f'{key} does not reference the complete app icon set')
    for name, size in ICON_SIZES.items():
        if opaque_png_size(app_path / name) != (size, size):
            raise ValueError(f'{name} must be an opaque {size} by {size} PNG')


def stage_icons(master, app_path):
    """Resize the master with macOS sips and update an existing bundle's Info.plist."""
    master, app_path = Path(master), Path(app_path)
    if opaque_png_size(master) != (1024, 1024):
        raise ValueError('App icon master must be an opaque 1024 by 1024 PNG')
    info_path = app_path / 'Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    info.update(icon_metadata())
    for name, size in ICON_SIZES.items():
        subprocess.run(['sips', '--resampleHeightWidth', str(size), str(size), str(master),
                        '--out', str(app_path / name)], check=True, capture_output=True)
    validate_icons(app_path, info)
    info_path.write_bytes(plistlib.dumps(info, sort_keys=False))
