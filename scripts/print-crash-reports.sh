#!/usr/bin/env bash
#
# Prints why a test process died.
#
# When the app-hosted test process exits unexpectedly, the xcodebuild log says only "Restarting
# after unexpected exit, crash, or test timeout". The report that says why is written on the
# runner. The result bundle carries it too, but that is a hundred megabytes to download for the
# forty lines that matter, so CI prints those lines when a test run fails.
#
# This is a diagnostic, not a gate: it never fails the job, and it prints only the fields that
# explain a crash — the exception, the termination reason, any runtime message, and the frames of
# the thread that died.
#
# Usage:
#   print-crash-reports.sh              reports for Phleet from the last two hours
#   print-crash-reports.sh FILE...      these reports
#   print-crash-reports.sh --self-test  prove the extraction on a known fixture

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPORTS_DIR="${PHLEET_CRASH_REPORTS_DIR:-$HOME/Library/Logs/DiagnosticReports}"
MAX_FRAMES=40

describe() {
    python3 - "$1" "$MAX_FRAMES" <<'PY'
import json, sys

path, max_frames = sys.argv[1], int(sys.argv[2])
try:
    text = open(path, encoding="utf-8", errors="replace").read()
except OSError as error:
    print(f"  could not read: {error}")
    sys.exit(0)

# An .ips report is two JSON documents: one line of metadata, then the report.
head, _, rest = text.partition("\n")
try:
    meta = json.loads(head)
    body = json.loads(rest)
except ValueError:
    # Not that shape (an older .crash, a spindump). Its opening lines are still worth having.
    print("  not a two-part JSON report; first lines follow")
    for line in text.splitlines()[:60]:
        print("  " + line[:200])
    sys.exit(0)

print(f"  process:     {meta.get('app_name') or body.get('procName')}")
print(f"  when:        {meta.get('timestamp')}")
exception = body.get("exception") or {}
print(f"  exception:   {exception.get('type')} {exception.get('signal', '')} {exception.get('subtype', '')}".rstrip())
termination = body.get("termination") or {}
if termination:
    print(f"  termination: {termination.get('namespace')} {termination.get('indicator', '')} "
          f"{'; '.join(termination.get('reasons') or [])}".rstrip())
for library, messages in (body.get("asi") or {}).items():
    for message in messages:
        print(f"  message:     [{library}] {message}")

images = body.get("usedImages") or []
def frame_text(frame):
    index = frame.get("imageIndex")
    image = images[index].get("name", "?") if isinstance(index, int) and index < len(images) else "?"
    symbol = frame.get("symbol")
    if symbol:
        return f"{image}  {symbol} + {frame.get('symbolLocation', 0)}"
    return f"{image}  +{frame.get('imageOffset', '?')}"

threads = body.get("threads") or []
faulting = body.get("faultingThread")
chosen = [t for t in threads if t.get("triggered")] or (
    [threads[faulting]] if isinstance(faulting, int) and faulting < len(threads) else [])
for thread in chosen:
    label = thread.get("queue") or thread.get("name") or "unnamed"
    print(f"  thread that died ({label}):")
    for frame in (thread.get("frames") or [])[:max_frames]:
        print("    " + frame_text(frame)[:220])

backtrace = body.get("lastExceptionBacktrace") or []
if backtrace:
    print("  last exception backtrace:")
    for frame in backtrace[:max_frames]:
        print("    " + frame_text(frame)[:220])
PY
}

self_test() {
    local fixture="$ROOT/tests/fixtures/crashreport/synthetic.ips" out failures=0
    out="$(describe "$fixture")"

    expect() {
        if printf '%s\n' "$out" | grep -qF -- "$1"; then
            printf 'ok    report shows: %s\n' "$1"
        else
            printf 'NOT OK report is missing: %s\n' "$1" >&2
            failures=$((failures + 1))
        fi
    }
    expect "exception:   EXC_BREAKPOINT SIGTRAP"
    expect "message:     [libswiftCore.dylib] Fatal error: a synthetic failure"
    expect "thread that died (com.apple.main-thread):"
    expect "Phleet  syntheticFunction() + 12"
    # The thread that did not die is not printed: forty lines, not four thousand.
    if printf '%s\n' "$out" | grep -qF "bystanderFunction"; then
        printf 'NOT OK a thread that did not die was printed\n' >&2
        failures=$((failures + 1))
    else
        printf 'ok    a thread that did not die is left out\n'
    fi

    # Something that is not a report must be shown as itself, not swallowed.
    out="$(describe "$ROOT/tests/fixtures/crashreport/not-a-report.txt")"
    expect "not a two-part JSON report"
    expect "some other kind of diagnostic"

    if [ "$failures" -eq 0 ]; then
        echo "print-crash-reports.sh --self-test: all assertions passed"
    else
        echo "print-crash-reports.sh --self-test: $failures assertion(s) failed" >&2
        return 1
    fi
}

if [ "${1:-}" = "--self-test" ]; then
    self_test
    exit $?
fi

files=()
if [ "$#" -gt 0 ]; then
    files=("$@")
else
    while IFS= read -r file; do
        files+=("$file")
    done < <(find "$REPORTS_DIR" -maxdepth 2 -type f \
        \( -name 'Phleet*' -o -name 'xctest*' \) -mmin -120 2>/dev/null | sort)
fi

if [ "${#files[@]}" -eq 0 ]; then
    echo "No crash or hang report for Phleet was written in the last two hours under $REPORTS_DIR."
    echo "A process that was killed for not responding may leave none."
    ls -la "$REPORTS_DIR" 2>/dev/null | tail -20
    exit 0
fi

for file in "${files[@]}"; do
    echo "=== $(basename "$file")"
    describe "$file"
done
exit 0
