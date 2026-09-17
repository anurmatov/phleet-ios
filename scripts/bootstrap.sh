#!/usr/bin/env bash
#
# Prepares a machine to build Phleet: verifies the pinned Xcode, then fetches and
# hash-verifies the pinned XcodeGen release.
#
# Every step fails closed. There is no fallback to the runner's default Xcode, and no fallback
# to a Homebrew or PATH XcodeGen -- a version string alone does not guarantee that two machines
# generate the same project, so an unverified binary is refused rather than used.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# D9. Pinned to the default Xcode of the pinned runner image (macos-26), which is the
# best-tested combination available and the only one whose installed simulator runtimes are all
# at or above the iOS 17.0 floor. Moving this pin is a two-line change here and in the two
# workflows; see docs/development.md for the lookup procedure.
readonly PINNED_XCODE_APP="/Applications/Xcode_26.6.app"

# Escape hatch for an operator Mac, where Xcode lives at a different path. CI never sets it, and
# the value actually used is always logged.
XCODE_APP="${PHLEET_XCODE_APP:-$PINNED_XCODE_APP}"

readonly LOCK_FILE=".xcodegen.lock"
readonly TOOLS_DIR=".tools"
readonly XCODEGEN_BIN="$TOOLS_DIR/xcodegen/bin/xcodegen"
readonly DOWNLOAD_ATTEMPTS=3   # one attempt plus at most two retries

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

# --- Xcode ------------------------------------------------------------------------------------

verify_xcode() {
    if [ "$(uname -s)" != "Darwin" ]; then
        if [ -n "${CI:-}" ]; then
            die "CI must run on macOS; this host reports $(uname -s)"
        fi
        printf 'note: not macOS, skipping Xcode verification. `make generate` and `make test`\n'
        printf '      require a Mac; `make lint` and `make selftest` do not.\n'
        return 0
    fi

    if [ ! -d "$XCODE_APP" ]; then
        printf 'error: pinned Xcode not found at %s\n' "$XCODE_APP" >&2
        printf 'Xcode installations on this machine:\n' >&2
        ls -d /Applications/Xcode*.app >&2 2>/dev/null || printf '  (none)\n' >&2
        printf 'Set PHLEET_XCODE_APP to build against a different one, deliberately.\n' >&2
        exit 1
    fi

    if [ "$XCODE_APP" != "$PINNED_XCODE_APP" ]; then
        printf 'note: using PHLEET_XCODE_APP=%s instead of the pin %s\n' \
            "$XCODE_APP" "$PINNED_XCODE_APP"
    fi

    local developer_dir="$XCODE_APP/Contents/Developer"
    if [ "$(xcode-select -p 2>/dev/null || true)" != "$developer_dir" ]; then
        if ! sudo xcode-select -s "$developer_dir" 2>/dev/null; then
            die "could not select $developer_dir, and it is not already active"
        fi
    fi

    # Logged so the toolchain that actually produced a build is auditable after the fact.
    sw_vers
    xcodebuild -version
}

# --- XcodeGen ---------------------------------------------------------------------------------

read_lock_value() {
    local key="$1" value
    value="$(grep -E "^${key}=" "$LOCK_FILE" | head -n 1 | cut -d= -f2- || true)"
    [ -n "$value" ] || die "$LOCK_FILE has no ${key}="
    printf '%s' "$value"
}

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        die "no shasum or sha256sum available to verify the download"
    fi
}

download() {
    local url="$1" target="$2" attempt=1
    while [ "$attempt" -le "$DOWNLOAD_ATTEMPTS" ]; do
        if curl -fsSL --connect-timeout 20 --max-time 300 -o "$target" "$url"; then
            return 0
        fi
        printf 'warning: download attempt %d of %d failed\n' "$attempt" "$DOWNLOAD_ATTEMPTS" >&2
        attempt=$((attempt + 1))
    done
    return 1
}

extract() {
    local archive="$1" into="$2"
    if command -v unzip >/dev/null 2>&1; then
        unzip -q -o "$archive" -d "$into"
    else
        python3 -m zipfile -e "$archive" "$into"
    fi
}

install_xcodegen() {
    local version expected actual url archive

    version="$(read_lock_value version)"
    expected="$(read_lock_value sha256)"
    url="https://github.com/yonaskolb/XcodeGen/releases/download/${version}/xcodegen.zip"

    if [ -x "$XCODEGEN_BIN" ] && [ "$("$XCODEGEN_BIN" --version 2>/dev/null | tail -n 1)" = "Version: $version" ]; then
        printf 'XcodeGen %s already installed at %s\n' "$version" "$XCODEGEN_BIN"
        return 0
    fi

    rm -rf "$TOOLS_DIR"
    mkdir -p "$TOOLS_DIR"
    archive="$TOOLS_DIR/xcodegen.zip"

    printf 'Fetching XcodeGen %s\n' "$version"
    printf '  %s\n' "$url"
    if ! download "$url" "$archive"; then
        die "could not download the pinned XcodeGen $version from $url after $DOWNLOAD_ATTEMPTS attempts"
    fi

    actual="$(sha256_of "$archive")"
    if [ "$actual" != "$expected" ]; then
        printf 'error: XcodeGen artifact hash mismatch\n' >&2
        printf '  expected %s\n' "$expected" >&2
        printf '  actual   %s\n' "$actual" >&2
        printf 'Refusing to use an unverified binary. There is no Homebrew or PATH fallback.\n' >&2
        rm -f "$archive"
        exit 1
    fi
    printf 'Verified XcodeGen sha256 %s\n' "$actual"

    extract "$archive" "$TOOLS_DIR"
    rm -f "$archive"

    [ -f "$XCODEGEN_BIN" ] || die "archive did not contain $XCODEGEN_BIN"
    chmod +x "$XCODEGEN_BIN"
    printf 'Installed %s\n' "$XCODEGEN_BIN"
}

verify_xcode
install_xcodegen
printf 'bootstrap.sh: ready\n'
