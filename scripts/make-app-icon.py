#!/usr/bin/env python3
"""Generate the Phleet app icon as a deterministic 1024x1024 opaque PNG.

The icon is committed, because Xcode needs the file to exist when it compiles the asset catalog.
This script is committed alongside it and is the SOURCE of that file: `make icon` regenerates it
byte-identically. That is not a convenience — with a generator present and no such guarantee,
`make icon` would silently replace an approved icon with a different one and every check would
still pass, because the gate gates validity, not identity.

Concept: **confluence** — coordinated agents acting as one fleet.

Three agents enter from the left, their paths converge at a single junction, and beyond it there
is one body moving as a unit. The idea is the silhouette, not decoration laid over it: remove an
agent and the mark changes shape. That is the correction from the first attempt, which put an
agent-node network over a letterform where the concept was ~8% of the ink and therefore invisible
at 40x40 — the size the icon is seen at most.

Two measured constraints the geometry has to satisfy, both verified by scripts/check-app-icon.sh
rather than asserted here:

  * Everything survives actool's 25.6:1 downsample to 40x40. Strokes and discs are sized so the
    mark stays one connected body at that size instead of breaking into specks.
  * The file carries no transparency in any form.

No third-party dependency: shapes are signed distance fields evaluated per pixel and the PNG is
written with zlib from the standard library. Anti-aliasing is coverage derived from the distance,
which is why the curves are clean without supersampling.

Usage:
    scripts/make-app-icon.py [output.png]
"""

from __future__ import annotations

import math
import struct
import sys
import zlib

SIZE = 1024

WHITE = (0xFF, 0xFF, 0xFF)
MARK = (0x11, 0x11, 0x11)
NODE = (0x22, 0x22, 0x22)
EDGE = (0xDD, 0xDD, 0xDD)
GRID = (0xEE, 0xEE, 0xEE)

# --- geometry -------------------------------------------------------------------------------
# One canvas unit is one pixel at 1024. Apple's guidance is to keep the mark inside roughly the
# central 80%; the bounding box below is x[118, 912], y[208, 816].
#
# Every number here was chosen against the 40x40 rendering, not the 1024 one. At 25.6:1 the disc
# diameter is 6.1 px, the trunk 5.9 px and the tributaries 3.6 px — all comfortably above the
# point where a shape greys out and fragments.

AGENTS = [(196.0, 286.0), (196.0, 512.0), (196.0, 738.0)]
AGENT_R = 78.0          # the agents themselves
TRIBUTARY = 92.0        # each agent's path into the junction

JUNCTION = (600.0, 512.0)
TRUNK_END = (836.0, 512.0)
TRUNK = 152.0           # deliberately heavier than a tributary: this is the one body, not a fourth path


def clamp01(value: float) -> float:
    return 0.0 if value < 0.0 else (1.0 if value > 1.0 else value)


def coverage(distance: float) -> float:
    """Pixel coverage from a signed distance, negative inside.

    The 0.5-pixel ramp either side of the boundary is the whole anti-aliasing story; it is why
    this renders clean curves from one sample per pixel instead of a supersampling grid.
    """
    return clamp01(0.5 - distance)


class Canvas:
    def __init__(self, size: int, background: tuple[int, int, int]) -> None:
        self.size = size
        self.pixels = [[float(c) for c in background] for _ in range(size * size)]

    def paint(self, bounds, sdf, colour) -> None:
        """Composite `colour` over the canvas wherever `sdf` reports coverage.

        `bounds` restricts evaluation to the shape's bounding box. Without it this is a million
        pixels times every shape, which turns a one-second script into a minute-long one.
        """
        x0, y0, x1, y1 = bounds
        x0 = max(0, int(math.floor(x0)))
        y0 = max(0, int(math.floor(y0)))
        x1 = min(self.size - 1, int(math.ceil(x1)))
        y1 = min(self.size - 1, int(math.ceil(y1)))
        cr, cg, cb = colour

        for py in range(y0, y1 + 1):
            row = py * self.size
            sample_y = py + 0.5
            for px in range(x0, x1 + 1):
                alpha = coverage(sdf(px + 0.5, sample_y))
                if alpha <= 0.0:
                    continue
                pixel = self.pixels[row + px]
                inverse = 1.0 - alpha
                pixel[0] = pixel[0] * inverse + cr * alpha
                pixel[1] = pixel[1] * inverse + cg * alpha
                pixel[2] = pixel[2] * inverse + cb * alpha

    def to_rgb_bytes(self) -> bytes:
        out = bytearray()
        for pixel in self.pixels:
            out.append(int(pixel[0] + 0.5))
            out.append(int(pixel[1] + 0.5))
            out.append(int(pixel[2] + 0.5))
        return bytes(out)


# --- signed distance fields -----------------------------------------------------------------


def sdf_capsule(ax: float, ay: float, bx: float, by: float, half_width: float):
    """A segment with round caps. Used for the stem, the edges and the accent rule."""
    dx, dy = bx - ax, by - ay
    length_sq = dx * dx + dy * dy

    def field(x: float, y: float) -> float:
        px, py = x - ax, y - ay
        t = 0.0 if length_sq == 0.0 else clamp01((px * dx + py * dy) / length_sq)
        qx, qy = px - t * dx, py - t * dy
        return math.hypot(qx, qy) - half_width

    return field


def sdf_disc(cx: float, cy: float, radius: float):
    def field(x: float, y: float) -> float:
        return math.hypot(x - cx, y - cy) - radius

    return field


def render() -> Canvas:
    canvas = Canvas(SIZE, WHITE)
    jx, jy = JUNCTION

    # Tributaries first. Each agent's path runs into the one junction; drawing them before the
    # trunk and the agents means the joins are covered rather than showing as seams.
    for ax, ay in AGENTS:
        canvas.paint(
            (min(ax, jx) - TRIBUTARY, min(ay, jy) - TRIBUTARY,
             max(ax, jx) + TRIBUTARY, max(ay, jy) + TRIBUTARY),
            sdf_capsule(ax, ay, jx, jy, TRIBUTARY / 2.0),
            MARK,
        )

    # The trunk: past the junction there is one body, not three.
    canvas.paint(
        (min(jx, TRUNK_END[0]) - TRUNK, jy - TRUNK, max(jx, TRUNK_END[0]) + TRUNK, jy + TRUNK),
        sdf_capsule(jx, jy, TRUNK_END[0], TRUNK_END[1], TRUNK / 2.0),
        MARK,
    )

    # The agents last, so each sits at full weight on top of its own path.
    for ax, ay in AGENTS:
        canvas.paint(
            (ax - AGENT_R - 1, ay - AGENT_R - 1, ax + AGENT_R + 1, ay + AGENT_R + 1),
            sdf_disc(ax, ay, AGENT_R),
            MARK,
        )

    return canvas


# --- PNG ------------------------------------------------------------------------------------


def chunk(tag: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + tag
        + payload
        + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
    )


def encode_png(rgb: bytes, size: int) -> bytes:
    """8-bit truecolour, no alpha channel and no transparency chunk.

    Colour type 2 is not a stylistic choice. App Store Connect rejects a transparent app icon, so
    emitting RGBA here would trade the rejection this issue fixes for a different one. Nothing
    below writes a tRNS chunk either: on colour type 2 that would mark one RGB value fully
    transparent without any alpha channel being involved, which is the form that slipped past an
    earlier revision of the gate. scripts/check-app-icon.sh asserts both.
    """
    raw = bytearray()
    stride = size * 3
    for y in range(size):
        raw.append(0)  # filter: None
        raw.extend(rgb[y * stride:(y + 1) * stride])

    header = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )


def main(argv: list[str]) -> int:
    destination = (
        argv[1]
        if len(argv) > 1
        else "Phleet/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
    )
    png = encode_png(render().to_rgb_bytes(), SIZE)
    with open(destination, "wb") as handle:
        handle.write(png)
    print(f"wrote {destination} ({len(png)} bytes, {SIZE}x{SIZE}, no alpha)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
