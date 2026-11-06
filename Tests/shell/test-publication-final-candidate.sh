#!/bin/sh
#
# P4 / PC20 tests: a passing audit receipt is only valid for the exact final
# candidate. Changing source, the published ref, an artifact or the manual
# review afterwards must invalidate acceptance (verify-receipt AND fresh audit).
# No network. Run: sh Tests/shell/test-publication-final-candidate.sh
#
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
AUDIT="$SCRIPT_DIR/../../scripts/audit-publication.py"
[ -f "$AUDIT" ] || { echo "cannot find scripts/audit-publication.py" >&2; exit 1; }

PASS=0
FAIL=0
ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$ROOT"' EXIT INT TERM
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

ok()  { PASS=$((PASS + 1)); printf '   ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '   FAIL %s\n' "$1"; }
start() { printf '\n-- %s\n' "$1"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }
assert_ne() { if [ "$2" != "$3" ]; then ok "$1"; else bad "$1 (both were '$2')"; fi; }
sha() { python3 -I -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

audit()  { python3 -I "$AUDIT" --manifest "$MANIFEST" --manual-review "$REVIEW" --receipt "$RECEIPT" >/dev/null 2>&1; }
verify() { python3 -I "$AUDIT" --verify-receipt --manifest "$MANIFEST" --manual-review "$REVIEW" --receipt "$RECEIPT" >/dev/null 2>&1; }

# build_passing: fresh candidate (repo + .app artifact), audited once -> receipt.
build_passing() {
    CASE=$(mktemp -d "$ROOT/case.XXXXXX")
    REPO="$CASE/repo"; PROT="$CASE/protected"; ART="$CASE/artifacts"
    mkdir -p "$REPO/Sources" "$PROT" "$ART/PortPilot.app/Contents/MacOS"
    git init -q -b main "$REPO"
    printf 'let x = 1\n' > "$REPO/Sources/main.swift"
    printf '# demo\n' > "$REPO/README.md"
    git -C "$REPO" add -A && git -C "$REPO" commit -q -m "candidate"
    printf 'binary-bytes\n' > "$ART/PortPilot.app/Contents/MacOS/PortPilot"
    MANIFEST="$PROT/manifest.json"; REVIEW="$PROT/review.json"; RECEIPT="$PROT/receipt.json"
    python3 -I "$AUDIT" --print-manifest-template --repo "$REPO" --rev HEAD --ref main \
        --artifact "$ART/PortPilot.app" > "$MANIFEST"
    printf '{"schemaVersion":1,"manifestSha256":"%s","decision":"approved","reviewer":"Test Reviewer","date":"2026-01-02","personalDataReviewedManually":true}\n' \
        "$(sha "$MANIFEST")" > "$REVIEW"
    audit
}

must_invalidate() { # label
    verify; assert_ne "$1: --verify-receipt rejects" "$?" 0
    audit;  assert_ne "$1: fresh audit rejects" "$?" 0
}

start "baseline: passing audit produces a receipt that verifies"
build_passing
assert_eq "audit exit 0" "$(audit; echo $?)" 0
assert_eq "verify exit 0" "$(verify; echo $?)" 0

start "tracked source edited after audit invalidates acceptance (stale source)"
build_passing
printf 'let x = 2\n' > "$REPO/Sources/main.swift"
must_invalidate "source edit"

start "published ref moved to a new commit invalidates acceptance (ref drift)"
build_passing
printf 'let y = 3\n' >> "$REPO/Sources/main.swift"
git -C "$REPO" commit -q -am "post-audit change"
must_invalidate "ref moved"

start "artifact modified after audit invalidates acceptance (swapped artifact)"
build_passing
printf 'tampered\n' >> "$ART/PortPilot.app/Contents/MacOS/PortPilot"
must_invalidate "artifact edit"

start "artifact gains a file after audit invalidates acceptance (added bundle member)"
build_passing
printf 'x\n' > "$ART/PortPilot.app/Contents/MacOS/extra"
must_invalidate "artifact add"

start "manual review decision changed invalidates acceptance"
build_passing
sed 's/"approved"/"rejected"/' "$REVIEW" > "$REVIEW.x" && mv "$REVIEW.x" "$REVIEW"
must_invalidate "review decision"

start "manual review rebound to another manifest invalidates acceptance"
build_passing
sed 's/"manifestSha256":"[0-9a-f]*"/"manifestSha256":"abcd"/' "$REVIEW" > "$REVIEW.x" && mv "$REVIEW.x" "$REVIEW"
must_invalidate "review rebind"

start "benign review edit still invalidates the old receipt (re-review required)"
build_passing
sed 's/Test Reviewer/Someone Else/' "$REVIEW" > "$REVIEW.x" && mv "$REVIEW.x" "$REVIEW"
verify; assert_ne "verify rejects edited review" "$?" 0

start "manifest edited after audit invalidates acceptance"
build_passing
sed 's/"schemaVersion": 1/"schemaVersion": 1, "note": "x"/' "$MANIFEST" > "$MANIFEST.x" && mv "$MANIFEST.x" "$MANIFEST"
must_invalidate "manifest edit"

start "missing receipt blocks verification (no receipt = no publication)"
build_passing
rm -f "$RECEIPT"
verify; assert_ne "verify rejects missing receipt" "$?" 0

start "missing env inputs block the plan's verify command"
build_passing
OUT=$(env -u PORTPILOT_PUBLICATION_MANIFEST -u PORTPILOT_MANUAL_PRIVACY_REVIEW -u PORTPILOT_PUBLICATION_RECEIPT \
    sh -c 'python3 -I "$1" --manifest "${PORTPILOT_PUBLICATION_MANIFEST:?required}" --manual-review "${PORTPILOT_MANUAL_PRIVACY_REVIEW:?required}" --receipt "${PORTPILOT_PUBLICATION_RECEIPT:?required}"' _ "$AUDIT" 2>&1)
assert_ne "unset env exits nonzero" "$?" 0
OUT=$(PORTPILOT_PUBLICATION_MANIFEST="" PORTPILOT_MANUAL_PRIVACY_REVIEW="$REVIEW" PORTPILOT_PUBLICATION_RECEIPT="$RECEIPT" \
    sh -c 'python3 -I "$1" --manifest "${PORTPILOT_PUBLICATION_MANIFEST:-}" --manual-review "$PORTPILOT_MANUAL_PRIVACY_REVIEW" --receipt "$PORTPILOT_PUBLICATION_RECEIPT"' _ "$AUDIT" 2>&1)
assert_eq "empty manifest path exits 2" "$?" 2

start "missing manual review file blocks (unreviewed candidate)"
build_passing
rm -f "$RECEIPT" "$REVIEW"
python3 -I "$AUDIT" --manifest "$MANIFEST" --manual-review "$REVIEW" --receipt "$RECEIPT" >/dev/null 2>&1
assert_eq "exit 2" "$?" 2
[ ! -e "$RECEIPT" ] && ok "no receipt written" || bad "receipt written without review"

# build_with_patterns: like build_passing, plus a private patterns file outside the repo.
build_with_patterns() {
    CASE=$(mktemp -d "$ROOT/case.XXXXXX")
    REPO="$CASE/repo"; PROT="$CASE/protected"
    mkdir -p "$REPO" "$PROT"
    git init -q -b main "$REPO"
    printf '# demo\n' > "$REPO/README.md"
    git -C "$REPO" add -A && git -C "$REPO" commit -q -m "candidate"
    PATTERNS="$PROT/patterns.txt"; printf 'zebra-person-name\n' > "$PATTERNS"
    MANIFEST="$PROT/manifest.json"; REVIEW="$PROT/review.json"; RECEIPT="$PROT/receipt.json"
    python3 -I "$AUDIT" --print-manifest-template --repo "$REPO" --rev HEAD --ref main \
        --private-patterns "$PATTERNS" > "$MANIFEST"
    printf '{"schemaVersion":1,"manifestSha256":"%s","decision":"approved","reviewer":"Test Reviewer","date":"2026-01-02","personalDataReviewedManually":true}\n' \
        "$(sha "$MANIFEST")" > "$REVIEW"
    audit
}

start "private patterns file weakened after a pass invalidates acceptance (unpinned patterns)"
build_with_patterns
assert_eq "baseline verify exit 0" "$(verify; echo $?)" 0
printf 'something-else\n' > "$PATTERNS"
must_invalidate "patterns weakened"

start "private patterns file emptied after a pass invalidates acceptance"
build_with_patterns
: > "$PATTERNS"
must_invalidate "patterns emptied"

start "receipt stores the patterns digest"
build_with_patterns
assert_eq "receipt privatePatternsSha256 matches file" \
    "$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["privatePatternsSha256"])' "$RECEIPT")" "$(sha "$PATTERNS")"

start "manifest naming a patterns file without a digest is rejected (exit 2)"
build_with_patterns
python3 -I - "$MANIFEST" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); del m["privatePatternsSha256"]; json.dump(m, open(sys.argv[1], "w"))
PY
printf '{"schemaVersion":1,"manifestSha256":"%s","decision":"approved","reviewer":"R","date":"2026-01-02","personalDataReviewedManually":true}\n' "$(sha "$MANIFEST")" > "$REVIEW"
rm -f "$RECEIPT"
python3 -I "$AUDIT" --manifest "$MANIFEST" --manual-review "$REVIEW" --receipt "$RECEIPT" >/dev/null 2>&1
assert_eq "exit 2" "$?" 2
[ ! -e "$RECEIPT" ] && ok "no receipt written" || bad "receipt written without pinned patterns"

printf '\n== final candidate tests: %s passed, %s failed ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
