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
#   5. It carries no alpha channel. App Store Connect rejects an icon with one, so an RGBA file
#      would trade the rejection this gate fixes for a different rejection at the same stage.
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

# The inspection is a here-doc rather than a separate file so the gate is one reviewable unit.
# It prints a single machine-readable reason on failure and nothing on success.
inspect() {
    python3 - "$1" "$REQUIRED_SIZE" <<'PY'
import json
import os
import struct
import sys

iconset, required = sys.argv[1], int(sys.argv[2])

contents = os.path.join(iconset, "Contents.json")
if not os.path.isfile(contents):
    print(f"{iconset}: Contents.json is missing")
    raise SystemExit(1)

try:
    with open(contents, "rb") as handle:
        manifest = json.load(handle)
except (ValueError, OSError) as error:
    print(f"{contents}: unreadable ({error})")
    raise SystemExit(1)

wanted = f"{required}x{required}"
entries = [
    image for image in manifest.get("images", [])
    if image.get("size") == wanted and image.get("idiom") == "universal"
]
if not entries:
    print(f"{contents}: no universal {wanted} entry")
    raise SystemExit(1)

filename = (entries[0].get("filename") or "").strip()
if not filename:
    # The exact state that produced the 90713/90022 rejection: the entry is present and looks
    # populated, but names no file, so actool compiles an empty set without complaining.
    print(f"{contents}: the {wanted} entry names no file")
    raise SystemExit(1)

path = os.path.join(iconset, filename)
if not os.path.isfile(path):
    print(f"{path}: referenced by Contents.json but not present")
    raise SystemExit(1)

with open(path, "rb") as handle:
    head = handle.read(33)

if head[:8] != b"\x89PNG\r\n\x1a\n":
    print(f"{path}: not a PNG (bad signature)")
    raise SystemExit(1)

# IHDR is required by the spec to be the first chunk, so its position is fixed.
if len(head) < 33 or head[12:16] != b"IHDR":
    print(f"{path}: not a PNG (missing IHDR)")
    raise SystemExit(1)

width, height = struct.unpack(">II", head[16:24])
colour_type = head[25]

if (width, height) != (required, required):
    print(f"{path}: is {width}x{height}, expected {required}x{required}")
    raise SystemExit(1)

# Colour types 4 (grey+alpha) and 6 (RGBA) carry an alpha channel.
if colour_type in (4, 6):
    print(f"{path}: has an alpha channel (PNG colour type {colour_type})")
    raise SystemExit(1)

raise SystemExit(0)
PY
}

check_icon() {
    local iconset="${1:-$DEFAULT_ICONSET}" reason

    cd "$REPO_ROOT" || return 1

    if reason="$(inspect "$iconset")"; then
        return 0
    fi

    printf 'FAIL  %s\n' "$reason" >&2
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

    expect_fail no-filename   "names no file"
    expect_fail absent-file   "not present"
    expect_fail not-a-png     "bad signature"
    expect_fail wrong-size    "expected 1024x1024"
    expect_fail has-alpha     "alpha channel"

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
