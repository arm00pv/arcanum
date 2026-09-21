#!/usr/bin/env python3
'''Draw Arcanum's app icon, at every size the web build asks for.

Why this exists: the web build shipped the Flutter template's icon, which is the
Flutter logo - and on iOS the home screen takes its copy of the icon at the moment
the app is added, so a collector who adds Arcanum to their home screen gets somebody
else's logo. There is no image library in this repository and none is wanted for one
asset: a PNG is a header, a zlib stream and three checksums, and the mark is a handful
of geometric predicates, so this draws it directly and stays reproducible - re-running
it writes the same bytes.

The mark is the vault: a faceted gem in the app's own violet on the near-black the
manifest already names. It is the glyph the app's own bottom bar uses for the vault
tab, which is what makes it read as this app, and it is legible at 32 px because it is
four tones and one silhouette.

    python3 tool/make_app_icons.py

A maskable icon is the same mark inside the safe zone - four fifths of the width,
which is what Android's mask can crop to a circle without eating the gem - on a
full-bleed background, because a maskable icon is a background plus a mark and never a
rounded rectangle of its own.

The Android launcher icons are drawn here too, for the same reason and from the same
mark: the phone build was carrying Flutter's launcher icon on the home screen, and one
mark that is generated beats two that drift apart. Those are legacy icons - there is no
adaptive icon in this project - so they keep the rounded square and let the corners stay
transparent.
'''

from __future__ import annotations

import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
WEB = os.path.join(REPO, 'web')
RES = os.path.join(REPO, 'android', 'app', 'src', 'main', 'res')

# The launcher icon sizes Android expects, by density directory.
MIPMAPS = [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]

# The near-black the manifest names, and the violet the app draws its vault tab in.
BACK_TOP = (0x17, 0x12, 0x20)
BACK_BOTTOM = (0x07, 0x07, 0x0C)
FACET_LIGHT = (0xC9, 0xB6, 0xFF)
FACET_MID = (0x7C, 0x5C, 0xFF)
FACET_DARK = (0x4B, 0x32, 0xB8)
FACET_DEEP = (0x2E, 0x1F, 0x74)

# The gem, in fractions of the icon: a square rotated 45 degrees with its girdle at
# 41.5% of the height. Straight edges rather than curves, which is what keeps it crisp
# at 32 px.
TOP = 0.185
GIRDLE = 0.415
BOTTOM = 0.815
LEFT = 0.175
RIGHT = 0.825

# How much of that box the gem actually uses. The box is already inside Android's safe
# zone - a maskable icon is cropped to four fifths of its width - so the gem is drawn
# nearly to the box's edges: a diamond of half-diagonal 0.33 sits well inside the safe
# circle's 0.4, and a mark that fills its icon is what stays legible at 32 px.
SCALE = 0.92


def _png(width, height, rows):
    '''One PNG file, from rows of RGBA bytes.'''
    raw = b''.join(b'\x00' + row for row in rows)

    def chunk(tag, payload):
        body = tag + payload
        return (struct.pack('>I', len(payload)) + body
                + struct.pack('>I', zlib.crc32(body) & 0xFFFFFFFF))

    header = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', header)
            + chunk(b'IDAT', zlib.compress(raw, 9))
            + chunk(b'IEND', b''))


def _background(y):
    '''The near-black, graded very slightly so a flat fill does not band.'''
    return tuple(int(BACK_TOP[i] + (BACK_BOTTOM[i] - BACK_TOP[i]) * y)
                 for i in range(3))


def _inside_round_rect(x, y, radius):
    '''Whether a point is inside the icon's own rounded square.'''
    if radius <= 0:
        return True
    if x < radius or x > 1 - radius:
        if y < radius or y > 1 - radius:
            cx = radius if x < radius else 1 - radius
            cy = radius if y < radius else 1 - radius
            if (x - cx) ** 2 + (y - cy) ** 2 > radius ** 2:
                return False
    return True


def _gem(x, y, scale):
    '''The gem at one point: in or out, and which facet.'''
    cx = 0.5
    cy = 0.5
    half_height = (BOTTOM - TOP) / 2 * scale
    half_width = (RIGHT - LEFT) / 2 * scale
    top = cy - half_height
    bottom = cy + half_height
    girdle = cy - (0.5 - GIRDLE) * scale
    if y < top or y > bottom:
        return False, None
    # A diamond: the width available at this height falls linearly to nothing at the
    # two points.
    remaining = 1 - abs(y - cy) / half_height
    if remaining <= 0 or abs(x - cx) > half_width * remaining:
        return False, None
    if y < girdle:
        return True, (FACET_LIGHT if x < cx else FACET_MID)
    if y > girdle + (bottom - girdle) * 0.45:
        return True, FACET_DEEP
    return True, FACET_DARK


def draw(size, maskable=False, supersample=4):
    '''One icon, as rows of RGBA bytes, 4x supersampled.'''
    scale = SCALE if not maskable else SCALE * 0.92
    radius = 0.0 if maskable else 0.22
    samples = supersample * supersample
    rows = []
    for py in range(size):
        row = bytearray()
        for px in range(size):
            channels = [0, 0, 0, 0]
            for sy in range(supersample):
                for sx in range(supersample):
                    x = (px + (sx + 0.5) / supersample) / size
                    y = (py + (sy + 0.5) / supersample) / size
                    if not _inside_round_rect(x, y, radius):
                        continue
                    inside, colour = _gem(x, y, scale)
                    c = colour if inside else _background(y)
                    channels[0] += c[0]
                    channels[1] += c[1]
                    channels[2] += c[2]
                    channels[3] += 255
            row += bytes(v // samples for v in channels)
        rows.append(bytes(row))
    return rows


def write(path, size, maskable=False):
    blob = _png(size, size, draw(size, maskable=maskable))
    with open(path, 'wb') as fh:
        fh.write(blob)
    print('  %-46s %6d bytes' % (os.path.relpath(path, REPO), len(blob)))


def main():
    write(os.path.join(WEB, 'favicon.png'), 32)
    write(os.path.join(WEB, 'icons', 'Icon-192.png'), 192)
    write(os.path.join(WEB, 'icons', 'Icon-512.png'), 512)
    write(os.path.join(WEB, 'icons', 'Icon-maskable-192.png'), 192, maskable=True)
    write(os.path.join(WEB, 'icons', 'Icon-maskable-512.png'), 512, maskable=True)
    for density, size in MIPMAPS:
        write(os.path.join(RES, 'mipmap-' + density, 'ic_launcher.png'), size)


if __name__ == '__main__':
    main()
