#!/bin/bash
# Argument-parsing regressions for the debug CLI. Builds nothing: run `swift build` first.
# Always the exact PortPilotCLI path: on a case-insensitive filesystem `portpilot` can
# resolve to the GUI PortPilot binary.
set -uo pipefail
PROJECT="$(cd "$(dirname "$0")/../.." && pwd)"
CLI="$PROJECT/.build/debug/PortPilotCLI"
if [ ! -x "$CLI" ]; then
    printf 'FAIL: %s is missing; run `swift build` first\n' "$CLI" >&2
    exit 1
fi
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
CRED="$SANDBOX/credential.json"
printf '{"actor":"tester","credential":"not-a-real-secret"}\n' > "$CRED"
chmod 600 "$CRED"
FAILED=0
PASSED=0

# check NAME EXPECTED_ERROR_OR_EMPTY ARGS...  (runs with the sandboxed state dir)
check() {
    local name="$1" want="$2"; shift 2
    local out rc
    out="$("$CLI" --state-dir "$SANDBOX/state" "$@" 2>/dev/null)"; rc=$?
    if [ "$rc" -ge 128 ]; then
        printf 'FAIL: %s: died from signal (exit %s), output: %s\n' "$name" "$rc" "$out" >&2; FAILED=$((FAILED+1)); return
    fi
    if [ "$rc" -ne 2 ]; then
        printf 'FAIL: %s: exit %s, want 2, output: %s\n' "$name" "$rc" "$out" >&2; FAILED=$((FAILED+1)); return
    fi
    case "$out" in
        *"\"error\":\"$want\""*) PASSED=$((PASSED+1)); printf 'ok: %s\n' "$name" ;;
        *) printf 'FAIL: %s: output lacks error %s: %s\n' "$name" "$want" "$out" >&2; FAILED=$((FAILED+1)) ;;
    esac
}

# Bug caught: options but no command made `args.removeFirst()` trap on an empty array
# (SIGILL/SIGTRAP, exit >= 128, no JSON) instead of a structured invalid_input.
check "--json alone with credential" invalid_input --credential-file "$CRED" --json
check "credential only, no command" invalid_input --credential-file "$CRED"
# Control: a bad command word already failed cleanly; it must keep doing so.
check "unknown command" invalid_input --credential-file "$CRED" no-such-command
# Control: without a credential the CLI refuses before looking at the command.
check "--json alone without credential" unauthorized --json

if [ "$FAILED" -ne 0 ]; then printf '%s failed, %s passed\n' "$FAILED" "$PASSED" >&2; exit 1; fi
printf 'PASS: CLI argument edge cases (%s checks)\n' "$PASSED"
