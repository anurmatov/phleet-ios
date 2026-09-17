#!/usr/bin/env bash
#
# App icon gate.
#
# The first real TestFlight upload archived and signed cleanly and was then rejected by App
# Store Connect for a missing CFBundleIconName and a missing 120x120 icon. The project already
# declared ASSETCATALOG_COMPILER_APPICON_NAME, but the icon set referenced no file, so actool
# compiled an empty set, emitted no icon metadata, and nothing in the build said so. This gate
# exists so that failure is caught on a pull request in seconds rather than after a signed
# archive has been built and uploaded.
#
# What it asserts about the referenced icon:
#   1. Contents.json names a file for the 1024x1024 universal iOS entry.
#   2. That file exists inside the icon set.
#   3. It is a real PNG, by signature and IHDR, not something merely named .png.
#   4. It is exactly 1024x1024.
#   5. It can carry no transparency in any form. App Store Connect rejects a transparent icon, so
#      accepting one would trade the rejection this gate fixes for a different rejection at the
#      same stage.
#   6. The mark still holds together at 40x40. The icon is decoded, box-filtered down through
#      actool's 25.6:1 ratio to the Spotlight size, thresholded, and its connected regions of ink
#      are counted; the expected count is committed below.
#
# Point 6 exists because "valid PNG of the right size" says nothing about whether the artwork
# survives being seen. Thin strokes grey out and fragment at 40x40, and a mark that breaks into
# specks there is a failure the other five checks cannot see. The first icon proposed for this app
# was rejected for exactly that class of problem.
#
# Point 5 is an ALLOWLIST plus a chunk scan, and both halves are load-bearing. An earlier revision
# denylisted PNG colour types 4 and 6 (grey+alpha and RGBA) only, which is the obvious reading of
# "no alpha channel" and is wrong: a palette image (colour type 3) has no alpha CHANNEL and is
# still transparent if it carries a tRNS chunk. A fully transparent 1024x1024 palette+tRNS PNG
# passed that gate while this header, the PR description and docs/signing-and-release.md all
# claimed it could not. So the colour type must now be one of the two that cannot carry alpha
# (0 grey, 2 truecolour), and tRNS is rejected wherever it appears -- including on those two
# types, where it marks one grey level or one RGB value fully transparent.
#
# Runs on bash and python3 only, like every other gate here, so it works identically on a
# contributor's Linux box and on the macOS runner.
#
# Usage:
#   check-app-icon.sh [appiconset-dir]   check an icon set (default: the app's)
#   check-app-icon.sh --self-test        prove it passes and fails on known fixtures

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DEFAULT_ICONSET="Phleet/Resources/Assets.xcassets/AppIcon.appiconset"
FIXTURE_DIR="tests/fixtures/appicon"
REQUIRED_SIZE=1024

# The size the icon is judged at: iOS Spotlight, and the smallest actool derives from the 1024
# master. 1024/40 is 25.6, so the downsample below is a true box filter, not integer decimation.
JUDGE_SIZE=40

# The mark is ONE connected body at 40x40: three agent paths converging into a single trunk. If a
# stroke ever thins enough to grey out and break, this count rises and the gate fails -- which is
# the whole point, because nothing else here can see that happen.
EXPECTED_INK_REGIONS=1

# The inspection is a here-doc rather than a separate file so the gate is one reviewable unit.
# It prints a single machine-readable reason on failure and nothing on success.
inspect() {
    python3 - "$1" "$REQUIRED_SIZE" "$JUDGE_SIZE" "$EXPECTED_INK_REGIONS" <<'PY'
import json
import os
import struct
import sys
import zlib

iconset, required = sys.argv[1], int(sys.argv[2])
judge_size, expected_regions = int(sys.argv[3]), int(sys.argv[4])

# Every reason is collected and printed, not just the first. A palette+tRNS file breaks two rules
# at once, and reporting only one of them hides half of what is wrong with it.
reasons = []


def fail(message):
    reasons.append(message)


def finish():
    for message in reasons:
        print(message)
    raise SystemExit(1 if reasons else 0)


contents = os.path.join(iconset, "Contents.json")
if not os.path.isfile(contents):
    fail(f"{iconset}: Contents.json is missing")
    finish()

try:
    with open(contents, "rb") as handle:
        manifest = json.load(handle)
except (ValueError, OSError) as error:
    fail(f"{contents}: unreadable ({error})")
    finish()

wanted = f"{required}x{required}"
entries = [
    image for image in manifest.get("images", [])
    if image.get("size") == wanted and image.get("idiom") == "universal"
]
if not entries:
    fail(f"{contents}: no universal {wanted} entry")
    finish()

filename = (entries[0].get("filename") or "").strip()
if not filename:
    # The exact state that produced the 90713/90022 rejection: the entry is present and looks
    # populated, but names no file, so actool compiles an empty set without complaining.
    fail(f"{contents}: the {wanted} entry names no file")
    finish()

path = os.path.join(iconset, filename)
if not os.path.isfile(path):
    fail(f"{path}: referenced by Contents.json but not present")
    finish()

with open(path, "rb") as handle:
    blob = handle.read()

if blob[:8] != b"\x89PNG\r\n\x1a\n":
    fail(f"{path}: not a PNG (bad signature)")
    finish()

# Walk the chunk stream rather than reading a fixed prefix: tRNS can sit anywhere between IHDR
# and IDAT, so a prefix read cannot see it.
chunks = []
offset = 8
while offset + 8 <= len(blob):
    (length,) = struct.unpack(">I", blob[offset:offset + 4])
    tag = blob[offset + 4:offset + 8]
    payload = blob[offset + 8:offset + 8 + length]
    if len(payload) != length:
        fail(f"{path}: truncated PNG chunk {tag.decode('ascii', 'replace')}")
        finish()
    chunks.append((tag, payload))
    offset += 12 + length
    if tag == b"IEND":
        break

if not chunks or chunks[0][0] != b"IHDR" or len(chunks[0][1]) != 13:
    fail(f"{path}: not a PNG (missing IHDR)")
    finish()

width, height, _depth, colour_type = struct.unpack(">IIBB", chunks[0][1][:10])

if (width, height) != (required, required):
    fail(f"{path}: is {width}x{height}, expected {required}x{required}")

# ALLOWLIST, not a denylist. 0 is greyscale and 2 is truecolour; those are the only two PNG
# colour types with no alpha channel. 3 (palette), 4 (grey+alpha) and 6 (RGBA) are all rejected,
# and anything else is a colour type this gate has never been reasoned about.
if colour_type not in (0, 2):
    fail(f"{path}: PNG colour type {colour_type} can carry transparency; only 0 and 2 cannot")

# tRNS makes an image transparent WITHOUT an alpha channel: a transparent palette index on type
# 3, or a single fully transparent grey/RGB value on types 0 and 2. It is rejected wherever it
# appears, which is why this is checked even when the colour type is already allowed.
if any(tag == b"tRNS" for tag, _ in chunks):
    fail(f"{path}: carries a tRNS transparency chunk")

# Anything above is fatal for the rendering check below, which needs a decodable image.
if reasons:
    finish()

bit_depth = chunks[0][1][8]
interlace = chunks[0][1][12]

# Both are required for the decode below to be well defined, and both are what the generator
# writes and what actool expects. Failing loudly beats a check that quietly does not run.
if bit_depth != 8:
    fail(f"{path}: bit depth {bit_depth}; the 40x40 check decodes 8-bit images only")
if interlace != 0:
    fail(f"{path}: interlaced; the 40x40 check decodes non-interlaced images only")
if reasons:
    finish()

channels = 1 if colour_type == 0 else 3
stride = width * channels
raw = zlib.decompress(b"".join(p for t, p in chunks if t == b"IDAT"))

# Undo the per-scanline filters. All five types appear in real PNGs, and treating an unexpected
# one as "no filter" would silently produce garbage that the region count would then measure.
rows, previous, offset = [], bytearray(stride), 0
for y in range(height):
    ftype = raw[offset]; offset += 1
    line = bytearray(raw[offset:offset + stride]); offset += stride
    for i in range(stride):
        a = line[i - channels] if i >= channels else 0
        b = previous[i]
        c = previous[i - channels] if i >= channels else 0
        if ftype == 0:   line[i] = line[i]
        elif ftype == 1: line[i] = (line[i] + a) & 0xFF
        elif ftype == 2: line[i] = (line[i] + b) & 0xFF
        elif ftype == 3: line[i] = (line[i] + ((a + b) >> 1)) & 0xFF
        elif ftype == 4:
            pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
            line[i] = (line[i] + (a if pa <= pb and pa <= pc else (b if pb <= pc else c))) & 0xFF
        else:
            print(f"{path}: unknown PNG filter type {ftype} on row {y}")
            raise SystemExit(1)
    rows.append(line); previous = line

# Box-filter to the judging size. Buckets are computed per source pixel rather than by integer
# decimation, because 1024/40 is 25.6 and dropping the remainder would ignore the last 24 columns.
total = [0] * (judge_size * judge_size)
count = [0] * (judge_size * judge_size)
for y in range(height):
    by = y * judge_size // height
    line = rows[y]
    for x in range(width):
        cell = by * judge_size + x * judge_size // width
        total[cell] += line[x * channels]
        count[cell] += 1

ink = [total[i] // count[i] < 128 for i in range(judge_size * judge_size)]

# Count connected regions, 8-connected.
seen = [False] * len(ink)
found = 0
for start in range(len(ink)):
    if not ink[start] or seen[start]:
        continue
    found += 1
    stack = [start]
    seen[start] = True
    while stack:
        cell = stack.pop()
        cy, cx = divmod(cell, judge_size)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                ny, nx = cy + dy, cx + dx
                if 0 <= ny < judge_size and 0 <= nx < judge_size:
                    neighbour = ny * judge_size + nx
                    if ink[neighbour] and not seen[neighbour]:
                        seen[neighbour] = True
                        stack.append(neighbour)

if found != expected_regions:
    fail(f"{path}: {found} connected ink region(s) at {judge_size}x{judge_size}, "
         f"expected {expected_regions}; the mark does not hold together at icon size")

finish()
PY
}

check_icon() {
    local iconset="${1:-$DEFAULT_ICONSET}" reason

    cd "$REPO_ROOT" || return 1

    if reason="$(inspect "$iconset")"; then
        return 0
    fi

    while IFS= read -r line; do
        [ -n "$line" ] && printf 'FAIL  %s\n' "$line" >&2
    done <<< "$reason"
    printf 'error: the app icon set is not usable; App Store Connect will reject the upload.\n' >&2
    printf 'Regenerate with scripts/make-app-icon.py; see docs/signing-and-release.md\n' >&2
    return 1
}

self_test() {
    local failures=0 out

    cd "$REPO_ROOT" || exit 1

    # Positive control FIRST. A gate that has only ever been shown to go red is not a gate: it
    # could be failing for a reason unrelated to what it claims to check.
    if out="$(inspect "$DEFAULT_ICONSET")"; then
        printf 'ok    the real icon set passes\n'
    else
        printf 'NOT OK the real icon set should pass but was rejected: %s\n' "$out" >&2
        failures=$((failures + 1))
    fi

    # Each fixture is a mutation of exactly one property of a working icon set, so a green
    # assertion here names the specific failure mode it proved.
    expect_fail() {
        local fixture="$FIXTURE_DIR/$1" expected="$2" reason
        if reason="$(inspect "$fixture")"; then
            printf 'NOT OK %s should have been rejected but passed\n' "$fixture" >&2
            failures=$((failures + 1))
            return
        fi
        case "$reason" in
            *"$expected"*)
                printf 'ok    %s rejected: %s\n' "$1" "$expected"
                ;;
            *)
                printf 'NOT OK %s rejected for the wrong reason: %s\n' "$fixture" "$reason" >&2
                failures=$((failures + 1))
                ;;
        esac
    }

    expect_fail no-filename      "names no file"
    expect_fail absent-file      "not present"
    expect_fail not-a-png        "bad signature"
    expect_fail wrong-size       "expected 1024x1024"
    expect_fail has-alpha        "colour type 6 can carry transparency"

    # The two transparency forms that have no alpha channel. palette-trns is a FULLY TRANSPARENT
    # 1024x1024 icon that an earlier revision of this gate accepted; truecolour-trns proves the
    # tRNS rule still fires on a colour type the allowlist permits, so the two rules are shown to
    # be independent rather than one masking the other.
    expect_fail palette-trns     "colour type 3 can carry transparency"
    expect_fail palette-trns     "tRNS transparency chunk"
    expect_fail truecolour-trns  "tRNS transparency chunk"

    # A valid 1024x1024 opaque PNG that nonetheless falls apart at icon size. Without this the
    # region count is an assertion nobody has ever seen fail.
    expect_fail fragmented       "connected ink region"

    if [ "$failures" -ne 0 ]; then
        printf 'check-app-icon.sh --self-test: %d assertion(s) failed\n' "$failures" >&2
        exit 1
    fi
    printf 'check-app-icon.sh --self-test: all assertions passed\n'
}

case "${1:-}" in
    --self-test)
        self_test
        ;;
    --help|-h)
        printf 'usage: %s [appiconset-dir | --self-test]\n' "${BASH_SOURCE[0]}" >&2
        exit 2
        ;;
    *)
        check_icon "${1:-}"
        ;;
esac
