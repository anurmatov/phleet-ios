#!/usr/bin/env bash
#
# Asserts that every input the signed release needs is present before anything is created.
#
# release.yml calls this as its first step, so a release with a missing secret stops here
# rather than part-way through building a keychain. It lives in a script, not inline in the
# workflow, so that ci.yml can prove on an ordinary pull request that it actually fails --
# workflow_dispatch never runs on a PR, so an inline check could never be exercised.
#
# The check path uses shell builtins only. The self-test runs this script under `env -i`, which
# leaves it with no PATH, and an external command would fail for the wrong reason.
#
# Usage:
#   check-release-inputs.sh              print missing input names, exit 1 if any
#   check-release-inputs.sh --self-test  prove it fails with an empty environment

set -uo pipefail

# The eight inputs of the pinned release signing model. Values are supplied at run time as
# GitHub secrets and repository variables; none of them is in this repository.
REQUIRED_INPUTS="
APP_STORE_CONNECT_KEY_ID
APP_STORE_CONNECT_ISSUER_ID
APP_STORE_CONNECT_PRIVATE_KEY
DISTRIBUTION_CERTIFICATE_P12
DISTRIBUTION_CERTIFICATE_PASSWORD
PROVISIONING_PROFILE
KEYCHAIN_PASSWORD
DEVELOPMENT_TEAM
"

check_inputs() {
    local name value missing=0

    for name in $REQUIRED_INPUTS; do
        value="${!name:-}"
        # Whitespace-only counts as missing: an empty secret is a common way for this to go
        # wrong quietly, and it is not a usable value. Stripping every [[:space:]] character
        # and testing what is left covers tabs, newlines and runs of any length -- enumerating
        # a few literal space patterns would let a tab through as if it were a real value.
        if [ -z "${value//[[:space:]]/}" ]; then
            printf '%s\n' "$name"
            missing=$((missing + 1))
        fi
    done

    if [ "$missing" -ne 0 ]; then
        printf 'error: %d release input(s) missing; see docs/signing-and-release.md\n' \
            "$missing" >&2
        return 1
    fi
    return 0
}

self_test() {
    local script out status failures=0 expected_count=8 reported sorted_expected sorted_actual

    script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

    out="$(env -i "${BASH:-/bin/bash}" "$script" 2>/dev/null)"
    status=$?

    if [ "$status" -eq 1 ]; then
        printf 'ok    exits 1 with an empty environment\n'
    else
        printf 'NOT OK expected exit 1 with an empty environment, got %d\n' "$status" >&2
        failures=$((failures + 1))
    fi

    reported="$(printf '%s\n' "$out" | grep -c '[^[:space:]]' || true)"
    if [ "$reported" -eq "$expected_count" ]; then
        printf 'ok    names exactly %d missing inputs\n' "$expected_count"
    else
        printf 'NOT OK expected %d missing input names, got %d\n' \
            "$expected_count" "$reported" >&2
        failures=$((failures + 1))
    fi

    sorted_expected="$(printf '%s\n' $REQUIRED_INPUTS | sort)"
    sorted_actual="$(printf '%s\n' "$out" | grep '[^[:space:]]' | sort || true)"
    if [ "$sorted_expected" = "$sorted_actual" ]; then
        printf 'ok    names exactly the inputs of the release signing model\n'
    else
        printf 'NOT OK missing-input list does not match the release signing model\n' >&2
        printf 'expected:\n%s\nactual:\n%s\n' "$sorted_expected" "$sorted_actual" >&2
        failures=$((failures + 1))
    fi

    if [ "$failures" -ne 0 ]; then
        printf 'check-release-inputs.sh --self-test: %d assertion(s) failed\n' "$failures" >&2
        exit 1
    fi
    printf 'check-release-inputs.sh --self-test: all assertions passed\n'
}

case "${1:-}" in
    --self-test)
        self_test
        ;;
    "")
        check_inputs
        ;;
    *)
        printf 'usage: %s [--self-test]\n' "${BASH_SOURCE[0]}" >&2
        exit 2
        ;;
esac
