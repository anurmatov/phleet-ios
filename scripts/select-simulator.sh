#!/usr/bin/env bash
#
# Prints an xcodebuild destination for a deterministically chosen iOS simulator:
#
#   platform=iOS Simulator,id=<UDID>
#
# Two runs against identical input always print the same UDID. That matters because the
# alternative -- resolving a destination by device name -- silently builds for whatever the
# runner image happens to ship this month.
#
# Usage:
#   select-simulator.sh                      read `xcrun simctl list --json`
#   select-simulator.sh --simctl-json PATH   read the same document shape from a file
#   select-simulator.sh --self-test          assert the pick rule against fixtures
#
# `simctl list` takes at most one section argument, so the unfiltered form above is the only
# invocation that returns runtimes and devices in one document.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIN_IOS_MAJOR=17
MIN_IOS_MINOR=0

# Reads a simctl document on argv[1] and prints the chosen UDID, or exits 1 with a reason.
pick_udid() {
    python3 - "$1" "$MIN_IOS_MAJOR" "$MIN_IOS_MINOR" <<'PY'
import json
import re
import sys

path, min_major, min_minor = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
minimum = (min_major, min_minor)

try:
    with open(path) as handle:
        document = json.load(handle)
except (OSError, ValueError) as error:
    sys.stderr.write("error: could not read simctl JSON from %s: %s\n" % (path, error))
    sys.exit(1)

if not isinstance(document, dict):
    sys.stderr.write("error: simctl JSON is not an object\n")
    sys.exit(1)

devices = document.get("devices")
if not isinstance(devices, dict):
    # `devices` is an object keyed by runtime identifier. A list here means either a different
    # simctl invocation or a fixture that mirrors a shape the real tool never emits.
    sys.stderr.write("error: simctl JSON has no 'devices' object keyed by runtime identifier\n")
    sys.exit(1)

RUNTIME_KEY = re.compile(r"^com\.apple\.CoreSimulator\.SimRuntime\.iOS-(\d+)-(\d+)$")


def natural_key(name):
    """Order names so that 'iPhone 16' sorts above 'iPhone 9', which ASCII order does not."""
    chunks = re.split(r"(\d+)", name)
    return [(1, int(c), "") if c.isdigit() else (0, 0, c) for c in chunks]


candidates = []
for runtime_key, entries in devices.items():
    match = RUNTIME_KEY.match(runtime_key)
    if match is None:
        # Not an iOS runtime, or a key shape we will not guess the version from.
        continue
    version = (int(match.group(1)), int(match.group(2)))
    if version < minimum:
        continue
    if not isinstance(entries, list):
        continue
    for device in entries:
        if not isinstance(device, dict):
            continue
        if device.get("isAvailable") is not True:
            continue
        # Device type, never `name`: a simulator can be renamed by whoever created it.
        if "SimDeviceType.iPhone" not in (device.get("deviceTypeIdentifier") or ""):
            continue
        udid = device.get("udid")
        if not isinstance(udid, str) or not udid:
            continue
        name = device.get("name") or ""
        candidates.append((version, natural_key(name), udid, name))

if not candidates:
    sys.stderr.write(
        "error: no available iPhone simulator on an iOS %d.%d or newer runtime\n"
        % minimum
    )
    sys.stderr.write("runtimes reported by simctl:\n")
    runtimes = document.get("runtimes")
    reported = False
    if isinstance(runtimes, list):
        for runtime in runtimes:
            if isinstance(runtime, dict):
                reported = True
                sys.stderr.write(
                    "  %s  version=%s  available=%s\n"
                    % (
                        runtime.get("identifier"),
                        runtime.get("version"),
                        runtime.get("isAvailable"),
                    )
                )
    if not reported:
        sys.stderr.write("  (none)\n")
    sys.exit(1)

# Highest runtime, then highest device name in natural order, then greatest UDID. Total by
# construction: no two candidates can compare equal, because UDIDs are unique.
candidates.sort(key=lambda candidate: (candidate[0], candidate[1], candidate[2]))
version, _, udid, name = candidates[-1]
sys.stderr.write(
    "selected %s (%s) on iOS %d.%d\n" % (name, udid, version[0], version[1])
)
sys.stdout.write(udid + "\n")
PY
}

destination_for() {
    local udid status=0
    # Checked explicitly rather than left to errexit: this function is called from inside a
    # command substitution, where an enclosing `set +e` applies and a failing pick would
    # otherwise fall through to printing a destination with an empty id.
    udid="$(pick_udid "$1")" || status=$?
    if [ "$status" -ne 0 ] || [ -z "$udid" ]; then
        return 1
    fi
    printf 'platform=iOS Simulator,id=%s\n' "$udid"
}

from_xcrun() {
    local tmp status=0
    tmp="$(mktemp -t simctl-list.XXXXXX)"

    if ! xcrun simctl list --json > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        printf 'error: `xcrun simctl list --json` failed\n' >&2
        return 1
    fi

    # Cleaned up explicitly rather than with `trap ... RETURN`: bash pops the function's locals
    # before running a RETURN trap, so the trap body referenced an unbound $tmp and `set -u`
    # killed the script after a successful pick.
    destination_for "$tmp" || status=$?
    rm -f "$tmp"
    return $status
}

self_test() {
    local dir="$REPO_ROOT/tests/fixtures/simctl" failures=0 out status
    local expected="platform=iOS Simulator,id=00000000-0000-0000-0000-000000000012"

    expect_exit_1() {
        local fixture="$1" reason="$2"
        set +e
        out="$(destination_for "$fixture" 2>/dev/null)"
        status=$?
        set -e
        if [ "$status" -eq 1 ] && [ -z "$out" ]; then
            printf 'ok    %s exits 1 (%s) and prints no destination\n' "${fixture##*/}" "$reason"
        else
            printf 'NOT OK %s: expected exit 1 and empty output, got exit %d output %s\n' \
                "${fixture##*/}" "$status" "${out:-<empty>}" >&2
            failures=$((failures + 1))
        fi
    }

    expect_exit_1 "$dir/empty.json" "no runtimes at all"
    expect_exit_1 "$dir/ios16-only.json" "every runtime below the iOS 17.0 floor"

    set +e
    out="$(destination_for "$dir/multi-runtime.json" 2>/dev/null)"
    status=$?
    set -e
    if [ "$status" -eq 0 ] && [ "$out" = "$expected" ]; then
        printf 'ok    multi-runtime.json selects %s\n' "$expected"
    else
        printf 'NOT OK multi-runtime.json: expected exit 0 and %s, got exit %d and %s\n' \
            "$expected" "$status" "${out:-<empty>}" >&2
        failures=$((failures + 1))
    fi

    if [ "$failures" -ne 0 ]; then
        printf 'select-simulator.sh --self-test: %d assertion(s) failed\n' "$failures" >&2
        exit 1
    fi
    printf 'select-simulator.sh --self-test: all assertions passed\n'
}

main() {
    case "${1:-}" in
        --self-test)
            self_test
            ;;
        --simctl-json)
            if [ "${2:-}" = "" ]; then
                printf 'usage: %s --simctl-json PATH\n' "${BASH_SOURCE[0]}" >&2
                exit 2
            fi
            destination_for "$2"
            ;;
        "")
            from_xcrun
            ;;
        *)
            printf 'usage: %s [--simctl-json PATH | --self-test]\n' "${BASH_SOURCE[0]}" >&2
            exit 2
            ;;
    esac
}

main "$@"
