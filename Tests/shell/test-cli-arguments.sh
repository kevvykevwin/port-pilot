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
# AF_UNIX paths max out near 104 bytes, so the stub socket lives in its own short directory.
SOCKDIR="$(mktemp -d /tmp/ppcli.XXXX)"
trap 'rm -rf "$SANDBOX" "$SOCKDIR"' EXIT
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

# --- Wire-level checks: run the real CLI against a stub control socket and capture its request.
# Stub: accept one connection, store the length-prefixed JSON request, reply with a minimal
# valid completed response (4-byte big-endian length + JSON).
cat > "$SOCKDIR/stub.py" <<'PYEOF'
import os, socket, struct, sys
sock_path, out_path = sys.argv[1], sys.argv[2]
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(sock_path)
os.chmod(sock_path, 0o600)
srv.listen(1)
srv.settimeout(15)
conn, _ = srv.accept()
def read_exact(n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise SystemExit("short read")
        buf += chunk
    return buf
body = read_exact(struct.unpack(">I", read_exact(4))[0])
with open(out_path, "wb") as f:
    f.write(body)
reply = b'{"requestId":null,"status":"completed","revision":0,"retryable":false}'
conn.sendall(struct.pack(">I", len(reply)) + reply)
conn.close()
PYEOF
cat > "$SOCKDIR/field.py" <<'PYEOF'
import json, sys
req = json.load(open(sys.argv[1]))
print(json.dumps(req[sys.argv[2]]) if sys.argv[2] in req else "<absent>")
PYEOF

# wire NAME WANT_REVISION ARGS...  (WANT_REVISION is a number, or <absent> for no expectedRevision key)
wire() {
    local name="$1" want="$2"; shift 2
    local sock="$SOCKDIR/control.sock" captured="$SOCKDIR/req.json" stub rc got
    rm -f "$sock" "$captured"
    python3 -I "$SOCKDIR/stub.py" "$sock" "$captured" &
    stub=$!
    local i=0
    while [ ! -S "$sock" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
    "$CLI" --state-dir "$SOCKDIR" --credential-file "$CRED" "$@" >/dev/null 2>&1; rc=$?
    wait "$stub" 2>/dev/null
    if [ ! -s "$captured" ]; then
        printf 'FAIL: %s: stub captured no request (cli exit %s)\n' "$name" "$rc" >&2; FAILED=$((FAILED+1)); return
    fi
    got="$(python3 -I "$SOCKDIR/field.py" "$captured" expectedRevision)"
    if [ "$got" = "$want" ] && [ "$rc" -eq 0 ]; then
        PASSED=$((PASSED+1)); printf 'ok: %s (expectedRevision=%s)\n' "$name" "$got"
    else
        printf 'FAIL: %s: expectedRevision=%s (want %s), cli exit %s, request: %s\n' "$name" "$got" "$want" "$rc" "$(cat "$captured")" >&2
        FAILED=$((FAILED+1))
    fi
}

# Bug caught: dropping --revision for non-run commands would leave expectedRevision empty and
# the helper would reject every mutation as stale_revision.
SID="11111111-1111-1111-1111-111111111111"
OID="22222222-2222-2222-2222-222222222222"
wire "claim forwards --revision" 7 claim --revision 7 "$SID"
wire "release forwards --revision" 7 release --claim-id "$OID" --revision 7 "$SID"
wire "keep forwards --revision" 7 keep --value true --revision 7 "$SID"
wire "propose forwards --revision" 7 propose --action stop --revision 7 "$SID"
wire "acknowledge forwards --revision" 7 acknowledge --service-id "$SID" --revision 7 "$OID"
wire "decide forwards --revision" 7 decide --service-id "$SID" --approve true --revision 7 "$OID"
wire "execute forwards --revision" 7 execute --service-id "$SID" --revision 7 "$OID"
wire "tailnet-enroll forwards --revision" 7 tailnet-enroll --selector host.tailnet.ts.net:443 --revision 7 "$SID"
# Explicit --revision on run must pass through, not be replaced by the default.
wire "run forwards --revision" 7 run --service svc --port-env PORT --revision 7 -- /bin/echo hi
# Bug caught: run/adopt must default to revision 0 (create-if-absent) when --revision is omitted.
wire "run defaults to revision 0" 0 run --service svc --port-env PORT -- /bin/echo hi
wire "adopt defaults to revision 0" 0 adopt --service svc --pid $$ --port 8080
# Bug caught: the documented `run --port-arg=--port -- /abs/exe args` form must be accepted and
# append exactly one `--port {port}` pair, with no placeholder required in the child argv.
wire "run accepts --port-arg=--port" 0 run --service svc --port-arg=--port -- /bin/echo hi
got_args="$(python3 -I -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["payload"]["launch"]["arguments"]))' "$SOCKDIR/req.json" 2>/dev/null)"
if [ "$got_args" = '["hi", "--port", "{port}"]' ]; then PASSED=$((PASSED+1)); printf 'ok: --port-arg appends one port pair (%s)\n' "$got_args"
else printf 'FAIL: --port-arg arguments: %s\n' "$got_args" >&2; FAILED=$((FAILED+1)); fi
# Control (current behaviour): a mutation without --revision sends no expectedRevision key (null).
wire "claim without --revision sends no expectedRevision" "<absent>" claim "$SID"

if [ "$FAILED" -ne 0 ]; then printf '%s failed, %s passed\n' "$FAILED" "$PASSED" >&2; exit 1; fi
printf 'PASS: CLI argument edge cases (%s checks)\n' "$PASSED"
