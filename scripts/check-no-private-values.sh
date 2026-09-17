#!/usr/bin/env bash
#
# Tracked-file invariant scan.
#
# Fails the build when a tracked file carries secret-shaped content, a signing-material file
# extension, an absolute address, or a second copy of the build-gate branch.
#
# Every pattern here is generic. There is deliberately no list of real hostnames, addresses,
# team identifiers or account names to match against: this repository is public, and a
# published list of the things we are hiding is itself the leak.
#
# Usage:
#   check-no-private-values.sh              scan the tracked tree
#   check-no-private-values.sh --self-test  prove the checks pass and fail on known fixtures

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Assembled from two pieces on purpose. Written whole, this script would contain the literal it
# searches for, and the scanner would fail on its own source.
PRIVATE_KEY_PATTERN="BE""GIN [A-Z ]*PRIVATE KEY"

SIGNING_EXTENSIONS="p8 p12 cer certSigningRequest mobileprovision pem key"
ALLOWED_HOSTS="github.com docs.github.com developer.apple.com"
BUILD_GATE_FILE="Phleet/Configuration/ServerProfileResolution.swift"

findings=0

note() {
    printf 'FAIL  %s\n' "$*" >&2
    findings=$((findings + 1))
}

# Exempt from every group. tests/fixtures/** is exempt precisely so the deliberately-failing
# fixtures do not fail the real scan; the prose files are exempt so documentation can link out.
is_exempt() {
    case "$1" in
        docs/*|README.md|CONTRIBUTING.md|SECURITY.md|LICENSE|.gitignore|\
.github/pull_request_template.md|tests/fixtures/*)
            return 0
            ;;
    esac
    return 1
}

in_group2_scope() {
    case "$1" in
        Phleet/*|PhleetTests/*|PhleetUITests/*|project.yml|Config/*|.github/workflows/*)
            return 0
            ;;
    esac
    return 1
}

lowercase() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

host_of_url() {
    local rest="${1#*://}"
    rest="${rest%%/*}"
    rest="${rest%%\?*}"
    rest="${rest%%#*}"
    rest="${rest##*@}"      # drop any user-info
    rest="${rest%%:*}"      # drop any port
    lowercase "$rest"
}

host_allowed() {
    local host="$1" allowed
    for allowed in $ALLOWED_HOSTS; do
        if [ "$host" = "$allowed" ]; then
            return 0
        fi
    done
    case "$host" in
        *.invalid) return 0 ;;
    esac
    return 1
}

# --- Group 1: secret-shaped content -----------------------------------------------------------
# Returns 0 when clean, 1 when something was found. Prints each finding.
content_group1_findings() {
    local file="$1" hit found=0
    hit="$(grep -EIn "$PRIVATE_KEY_PATTERN" "$file" 2>/dev/null || true)"
    if [ -n "$hit" ]; then
        printf '%s: private key header\n' "$file"
        found=1
    fi
    return $found
}

# --- Group 2: absolute addresses --------------------------------------------------------------
content_group2_findings() {
    local file="$1" url host found=0 ipv4

    while IFS= read -r url; do
        [ -n "$url" ] || continue
        host="$(host_of_url "$url")"
        if [ -z "$host" ] || ! host_allowed "$host"; then
            printf '%s: absolute URL with host %s\n' "$file" "${host:-<empty>}"
            found=1
        fi
    done <<< "$(grep -EIoh "https?://[^[:space:]\"'\\\`<>)]+" "$file" 2>/dev/null || true)"

    ipv4="$(grep -EIoh "(^|[^0-9.])[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}([^0-9.]|$)" \
        "$file" 2>/dev/null || true)"
    if [ -n "$ipv4" ]; then
        printf '%s: bare IPv4 literal\n' "$file"
        found=1
    fi

    return $found
}

# --- Group 3: exactly one build-gate branch, in the one file allowed to have it ----------------
# Matched at line start so that prose mentioning the directive in a comment is not counted.
check_group3() {
    local file count total=0 elsewhere=""

    while IFS= read -r -d '' file; do
        case "$file" in
            Phleet/*) ;;
            *) continue ;;
        esac
        count="$(grep -Ec '^[[:space:]]*#if DEBUG' "$file" 2>/dev/null || true)"
        [ -n "$count" ] || count=0
        if [ "$count" -gt 0 ]; then
            total=$((total + count))
            if [ "$file" != "$BUILD_GATE_FILE" ]; then
                elsewhere="$elsewhere $file"
            fi
        fi
    done < <(git ls-files -z)

    if [ "$total" -ne 1 ]; then
        note "expected exactly one build-gate branch under Phleet/, found $total"
    fi
    if [ -n "$elsewhere" ]; then
        note "build-gate branch outside $BUILD_GATE_FILE:$elsewhere"
    fi
}

scan_tracked_tree() {
    local file ext base out

    while IFS= read -r -d '' file; do
        base="${file##*/}"
        ext="${base##*.}"

        # Path rules apply to every tracked file, exempt or not: an exemption is about content,
        # never about whether a certificate may be committed.
        case " $SIGNING_EXTENSIONS " in
            *" $ext "*) note "$file: signing-material file extension .$ext is tracked" ;;
        esac
        case "$file" in
            Config/*.local.xcconfig)
                note "$file: local signing config is tracked"
                ;;
        esac
        case "$file" in
            *.xcodeproj|*.xcodeproj/*|*.xcworkspace|*.xcworkspace/*)
                note "$file: generated Xcode project is tracked; regenerate with make generate"
                ;;
        esac

        if is_exempt "$file"; then
            continue
        fi

        if out="$(content_group1_findings "$file")"; then :; else
            note "$out"
        fi

        if in_group2_scope "$file"; then
            if out="$(content_group2_findings "$file")"; then :; else
                note "$out"
            fi
        fi
    done < <(git ls-files -z)

    check_group3
}

# --- self-test --------------------------------------------------------------------------------
# Runs the content checks directly against fixtures, bypassing the exemption that keeps those
# same fixtures from failing the real scan.
self_test() {
    local dir="tests/fixtures/scanner" failures=0

    expect_clean() {
        if content_group1_findings "$1" >/dev/null && content_group2_findings "$1" >/dev/null; then
            printf 'ok    %s is clean\n' "$1"
        else
            printf 'NOT OK %s should be clean but was flagged\n' "$1" >&2
            failures=$((failures + 1))
        fi
    }

    expect_flagged() {
        local file="$1" group="$2"
        if "content_${group}_findings" "$file" >/dev/null; then
            printf 'NOT OK %s should have been flagged by %s and was not\n' "$file" "$group" >&2
            failures=$((failures + 1))
        else
            printf 'ok    %s is flagged by %s\n' "$file" "$group"
        fi
    }

    expect_clean "$dir/clean.fixture"
    expect_flagged "$dir/private-key.fixture" group1
    expect_flagged "$dir/absolute-url.fixture" group2

    if [ "$failures" -ne 0 ]; then
        printf 'check-no-private-values.sh --self-test: %d assertion(s) failed\n' "$failures" >&2
        exit 1
    fi
    printf 'check-no-private-values.sh --self-test: all assertions passed\n'
}

main() {
    case "${1:-}" in
        --self-test)
            self_test
            ;;
        "")
            scan_tracked_tree
            if [ "$findings" -ne 0 ]; then
                printf '\n%d invariant violation(s); see CONTRIBUTING.md\n' "$findings" >&2
                exit 1
            fi
            printf 'check-no-private-values.sh: tracked tree is clean\n'
            ;;
        *)
            printf 'usage: %s [--self-test]\n' "${BASH_SOURCE[0]}" >&2
            exit 2
            ;;
    esac
}

main "$@"
