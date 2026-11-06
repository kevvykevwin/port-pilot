#!/bin/sh
#
# P0 fixture tests for scripts/audit-publication.py (PC03, PC04).
# Every case builds a throwaway git repo + protected dir under mktemp -d.
# No network. Run: sh Tests/shell/test-publication-audit.sh
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

# Sentinel is assembled at runtime so this file never contains the full value.
SENT="PRIVATE_SENTINEL_""01"

ok()  { PASS=$((PASS + 1)); printf '   ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '   FAIL %s\n' "$1"; }
start() { printf '\n-- %s\n' "$1"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (output missing '$3')" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) bad "$1 (output leaked a forbidden string)" ;; *) ok "$1" ;; esac; }
assert_absent() { if [ ! -e "$2" ]; then ok "$1"; else bad "$1 ($2 exists)"; fi; }
assert_exists() { if [ -e "$2" ]; then ok "$1"; else bad "$1 ($2 missing)"; fi; }

sha() { python3 -I -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

# new_case: fresh sandbox. REPO is the candidate, PROT holds protected files.
new_case() {
    CASE=$(mktemp -d "$ROOT/case.XXXXXX")
    REPO="$CASE/repo"; PROT="$CASE/protected"; ART="$CASE/artifacts"
    mkdir -p "$REPO/docs" "$PROT" "$ART"
    git init -q -b main "$REPO"
    printf '# demo\nGeneric public readme.\n' > "$REPO/README.md"
    printf 'print("hi")\n' > "$REPO/docs/app.py"
    git -C "$REPO" add -A && git -C "$REPO" commit -q -m "initial"
    MANIFEST="$PROT/manifest.json"; REVIEW="$PROT/review.json"; RECEIPT="$PROT/receipt.json"
}

# make_manifest [template args...]: writes $MANIFEST for HEAD of main.
make_manifest() {
    python3 -I "$AUDIT" --print-manifest-template --repo "$REPO" --rev HEAD --ref main "$@" > "$MANIFEST"
}
# make_review [decision]: binds a review to the current manifest.
make_review() {
    printf '{"schemaVersion":1,"manifestSha256":"%s","decision":"%s","reviewer":"Test Reviewer","date":"2026-01-02","personalDataReviewedManually":true}\n' \
        "$(sha "$MANIFEST")" "${1:-approved}" > "$REVIEW"
}
# run_audit: sets OUT and RC (stdout+stderr combined).
run_audit() {
    OUT=$(python3 -I "$AUDIT" --manifest "$MANIFEST" --manual-review "$REVIEW" --receipt "$RECEIPT" 2>&1)
    RC=$?
}
prepare() { make_manifest "$@"; make_review; }

expect_fail() { # label, finding code
    run_audit
    assert_eq "$1: exit 1" "$RC" 1
    assert_contains "$1: reports $2" "$OUT" "$2"
    assert_not_contains "$1: value not printed" "$OUT" "$SENT"
    assert_absent "$1: no receipt written" "$RECEIPT"
}

start "clean candidate passes and writes a 0600 receipt (false-positive on clean tree)"
new_case; prepare
run_audit
assert_eq "exit 0" "$RC" 0
assert_exists "receipt written" "$RECEIPT"
assert_contains "reminder printed" "$OUT" "do not certify absence"
MODE=$(python3 -I -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode&0o777))' "$RECEIPT")
assert_eq "receipt mode 0600 (receipt must not be world readable)" "$MODE" "0o600"

start "sentinel in tracked doc fails without printing value (PC03)"
new_case; printf 'note %s here\n' "$SENT" > "$REPO/docs/notes.md"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "doc"; prepare
expect_fail "tracked doc" "sentinel"
assert_contains "location names the path" "$OUT" "docs/notes.md"

start "history-only sentinel is not skipped (older commit of published ref)"
new_case; printf '%s\n' "$SENT" > "$REPO/old.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "add"
git -C "$REPO" rm -q old.txt && git -C "$REPO" commit -q -m "remove"; prepare
expect_fail "history" "sentinel"

start "sentinel in commit message of published ref is caught"
new_case; git -C "$REPO" commit -q --allow-empty -m "oops $SENT"; prepare
expect_fail "commit message" "sentinel"

start "sentinel only in untracked included file fails (untracked not ignored)"
new_case; printf '%s\n' "$SENT" > "$REPO/extra.txt"; prepare --include-untracked extra.txt
expect_fail "untracked" "sentinel"
assert_contains "location names the file" "$OUT" "extra.txt"

start "undeclared dirty tracked change fails (dirty content must be pinned)"
new_case; printf 'changed\n' >> "$REPO/README.md"; prepare
run_audit
assert_eq "exit 1" "$RC" 1
assert_contains "reports undeclared_dirty" "$OUT" "undeclared_dirty"

start "sentinel only inside a zip artifact member fails"
new_case; mkdir "$CASE/zsrc"; printf '%s\n' "$SENT" > "$CASE/zsrc/inner.txt"
(cd "$CASE/zsrc" && python3 -I -c 'import zipfile,sys;z=zipfile.ZipFile(sys.argv[1],"w");z.write("inner.txt");z.close()' "$ART/rel.zip")
prepare --artifact "$ART/rel.zip"
expect_fail "zip member" "sentinel"
assert_contains "location names member" "$OUT" "inner.txt"

start "sentinel only inside a tar.gz artifact member fails"
new_case; mkdir "$CASE/tsrc"; printf '%s\n' "$SENT" > "$CASE/tsrc/inner.txt"
tar -czf "$ART/rel.tar.gz" -C "$CASE/tsrc" inner.txt; prepare --artifact "$ART/rel.tar.gz"
expect_fail "tar member" "sentinel"

start "sentinel only in PNG tEXt metadata fails (image metadata scanned)"
new_case
python3 -I - "$ART/shot.png" "$SENT" <<'PY'
import struct, sys, zlib
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
png += chunk(b"tEXt", b"Comment\0" + sys.argv[2].encode())
png += chunk(b"IDAT", zlib.compress(b"\0\0\0\0"))
png += chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
PY
prepare --artifact "$ART/shot.png"
expect_fail "png metadata" "sentinel"

start "private-config.json inside fake .app bundle fails (PC04)"
new_case; mkdir -p "$ART/Fake.app/Contents/Resources"
printf '{}' > "$ART/Fake.app/Contents/Resources/private-config.json"
prepare --artifact "$ART/Fake.app"
run_audit
assert_eq "exit 1" "$RC" 1
assert_contains "reports forbidden_file" "$OUT" "forbidden_file"
assert_contains "location names the file" "$OUT" "private-config.json"
assert_absent "no receipt" "$RECEIPT"

start "forbidden file committed to a published ref fails (credential-*.json)"
new_case; printf '{}' > "$REPO/credential-abc.json"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "cred"; prepare
run_audit; assert_eq "exit 1" "$RC" 1; assert_contains "forbidden_file" "$OUT" "forbidden_file"

start "generic secrets and home paths are caught (patterns not silently dropped)"
new_case
printf 'token ghp_%s\n' "abcdefghijklmnopqrstuvwxyz0123456789" > "$REPO/a.txt"
printf 'path /Use''rs/someperson/project/x\n' > "$REPO/b.txt"
printf 'ok /Users/Shared/ok\n' > "$REPO/c.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "s"; prepare
run_audit
assert_contains "github token" "$OUT" "secret_github_token"
assert_contains "home path" "$OUT" "home_path"
assert_not_contains "allowlisted /Users/Shared not flagged" "$OUT" "c.txt"
assert_not_contains "token value not printed" "$OUT" "ghp_abcdef"
assert_not_contains "name not printed" "$OUT" "someperson"

start "undeclared nested repository fails (gitlink/embedded repo not skipped)"
new_case; mkdir "$CASE/inner"; git init -q -b main "$CASE/inner"
printf 'x\n' > "$CASE/inner/f"; git -C "$CASE/inner" add -A; git -C "$CASE/inner" commit -q -m i
INNER=$(git -C "$CASE/inner" rev-parse HEAD)
git -C "$REPO" update-index --add --cacheinfo "160000,$INNER,vendor/inner"
git -C "$REPO" commit -q -m "gitlink"; prepare
run_audit
assert_eq "exit 1" "$RC" 1
assert_contains "reports nested_repo" "$OUT" "nested_repo"

start "missing or empty args exit 2 (incomplete inputs never audited)"
new_case; prepare
python3 -I "$AUDIT" >/dev/null 2>&1; assert_eq "no args" "$?" 2
python3 -I "$AUDIT" --manifest "$MANIFEST" --manual-review "$REVIEW" >/dev/null 2>&1; assert_eq "missing receipt" "$?" 2
python3 -I "$AUDIT" --manifest "$MANIFEST" --manual-review "" --receipt "$RECEIPT" >/dev/null 2>&1; assert_eq "empty review path" "$?" 2
python3 -I "$AUDIT" --manifest "$PROT/nope.json" --manual-review "$REVIEW" --receipt "$RECEIPT" >/dev/null 2>&1; assert_eq "nonexistent manifest" "$?" 2
assert_absent "no receipt" "$RECEIPT"

start "review bound to a different manifest fails (review replay)"
new_case; prepare
sed 's/"manifestSha256":"[0-9a-f]*"/"manifestSha256":"0000"/' "$REVIEW" > "$REVIEW.x" && mv "$REVIEW.x" "$REVIEW"
run_audit
assert_eq "exit 1" "$RC" 1; assert_contains "review_mismatch" "$OUT" "review_mismatch"; assert_absent "no receipt" "$RECEIPT"

start "review decision not approved fails"
new_case; make_manifest; make_review rejected
run_audit
assert_eq "exit 1" "$RC" 1; assert_contains "review_not_approved" "$OUT" "review_not_approved"; assert_absent "no receipt" "$RECEIPT"

start "review without manual personal-data acknowledgement fails"
new_case; make_manifest
printf '{"schemaVersion":1,"manifestSha256":"%s","decision":"approved","reviewer":"R","date":"2026-01-02"}\n' "$(sha "$MANIFEST")" > "$REVIEW"
run_audit
assert_eq "exit 1" "$RC" 1; assert_contains "review_incomplete" "$OUT" "review_incomplete"

start "receipt / manifest paths inside the repo exit 2 (protected paths)"
new_case; prepare
python3 -I "$AUDIT" --manifest "$MANIFEST" --manual-review "$REVIEW" --receipt "$REPO/receipt.json" >/dev/null 2>&1
assert_eq "receipt in repo" "$?" 2; assert_absent "receipt not created" "$REPO/receipt.json"
cp "$MANIFEST" "$REPO/manifest.json"
python3 -I "$AUDIT" --manifest "$REPO/manifest.json" --manual-review "$REVIEW" --receipt "$RECEIPT" >/dev/null 2>&1
assert_eq "manifest in repo" "$?" 2

start "private patterns file match fails without printing value"
new_case; printf 'contains zebra-person-name here\n' > "$REPO/who.md"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m w
printf 'zebra-person-name\n' > "$CASE/private-patterns.txt"
prepare --private-patterns "$CASE/private-patterns.txt"
run_audit
assert_eq "exit 1" "$RC" 1
assert_contains "private_pattern" "$OUT" "private_pattern"
assert_not_contains "pattern value not printed" "$OUT" "zebra-person-name"
assert_absent "no receipt" "$RECEIPT"

start "artifact tampered after manifest fails hash check"
new_case; printf 'one\n' > "$ART/a.bin"; prepare --artifact "$ART/a.bin"
printf 'two\n' > "$ART/a.bin"
run_audit
assert_eq "exit 1" "$RC" 1; assert_contains "hash_mismatch" "$OUT" "hash_mismatch"

start "failing audit never overwrites a receipt for another manifest"
new_case; prepare; run_audit
cp "$RECEIPT" "$CASE/receipt.orig"
printf '%s\n' "$SENT" > "$REPO/n.md"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m n; prepare
run_audit
assert_eq "exit 1" "$RC" 1
assert_eq "old receipt untouched" "$(cat "$RECEIPT")" "$(cat "$CASE/receipt.orig")"

start "zip with path traversal member fails"
new_case
python3 -I - "$ART/evil.zip" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w"); z.writestr("../escape.txt", "x"); z.close()
PY
prepare --artifact "$ART/evil.zip"
run_audit
assert_eq "exit 1" "$RC" 1; assert_contains "archive_traversal" "$OUT" "archive_traversal"

start "symlink out of artifact dir is reported, not followed"
new_case; mkdir "$ART/Dir.app"; printf '%s\n' "$SENT" > "$CASE/outside.txt"; ln -s "$CASE/outside.txt" "$ART/Dir.app/link"
prepare --artifact "$ART/Dir.app"
expect_fail "symlink" "symlink_escape"

start "plain .gz (not tar) holding the sentinel fails (compressed non-tar content scanned)"
new_case; printf 'note %s\n' "$SENT" > "$CASE/notes.md"; gzip -c "$CASE/notes.md" > "$ART/notes.md.gz"
prepare --artifact "$ART/notes.md.gz"
expect_fail "plain gzip" "sentinel"

start "truncated .tar.gz fails closed as archive_unreadable (corrupt archive not raw-scanned only)"
new_case; mkdir "$CASE/tsrc"; head -c 200000 /dev/urandom > "$CASE/tsrc/rand.bin"
tar -czf "$CASE/full.tgz" -C "$CASE/tsrc" rand.bin; head -c 100000 "$CASE/full.tgz" > "$ART/cut.tar.gz"
prepare --artifact "$ART/cut.tar.gz"
expect_fail "truncated tgz" "archive_unreadable"

start "sentinel inside plain .bz2 and .xz fails"
new_case; printf 'note %s\n' "$SENT" > "$CASE/notes.md"
python3 -I - "$CASE/notes.md" "$ART/n.md.bz2" "$ART/n.md.xz" <<'PY'
import bz2, lzma, sys
d = open(sys.argv[1], "rb").read()
open(sys.argv[2], "wb").write(bz2.compress(d)); open(sys.argv[3], "wb").write(lzma.compress(d))
PY
prepare --artifact "$ART/n.md.bz2"
expect_fail "bz2" "sentinel"
make_manifest --artifact "$ART/n.md.xz"; make_review
expect_fail "xz" "sentinel"

start "archive nested deeper than the depth limit reports archive_depth (not silently skipped)"
new_case; printf '%s\n' "$SENT" > "$CASE/inner.txt"
python3 -I - "$CASE/inner.txt" "$ART/deep.zip" <<'PY'
import io, sys, zipfile
data, name = open(sys.argv[1], "rb").read(), "inner.txt"
for i in range(6):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z: z.writestr(name, data)
    data, name = buf.getvalue(), "l%d.zip" % i
open(sys.argv[2], "wb").write(data)
PY
prepare --artifact "$ART/deep.zip"
expect_fail "deep nesting" "archive_depth"

start "forbidden name renamed away in a later commit is still caught in history (blob dedup must not skip name policy)"
new_case; printf '{"k":1}\n' > "$REPO/private-config.json"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "cfg"
git -C "$REPO" mv private-config.json settings-example.json && git -C "$REPO" commit -q -m "rename"; prepare
run_audit
assert_eq "exit 1" "$RC" 1
assert_contains "reports forbidden_file" "$OUT" "forbidden_file"
assert_absent "no receipt" "$RECEIPT"

start "home paths terminated by quote or end of file are flagged; /Users/Shared is not"
new_case
printf '{"p": "/Use''rs/quoteperson"}\n' > "$REPO/q.json"
printf 'at end /Use''rs/eofperson' > "$REPO/e.txt"
printf 'shared /Users/Shared/x and /Users/Shared\n' > "$REPO/s.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m h; prepare
run_audit
assert_contains "quoted path flagged" "$OUT" "q.json"
assert_contains "end-of-file path flagged" "$OUT" "e.txt"
assert_not_contains "Shared not flagged" "$OUT" "s.txt"
assert_not_contains "name not printed" "$OUT" "quoteperson"
assert_not_contains "eof name not printed" "$OUT" "eofperson"

start "UTF-16LE file with BOM holding the sentinel fails"
new_case
python3 -I - "$ART/u16.txt" "$SENT" <<'PY'
import sys
open(sys.argv[1], "wb").write(b"\xff\xfe" + ("note %s\n" % sys.argv[2]).encode("utf-16-le"))
PY
prepare --artifact "$ART/u16.txt"
expect_fail "utf16 bom" "sentinel"

start "UTF-16 .strings file without BOM holding a home path fails"
new_case
python3 -I - "$ART/Localizable.strings" <<'PY'
import sys
open(sys.argv[1], "wb").write(('"k" = "/Use' 'rs/stringsperson/x";\n').encode("utf-16-le"))
PY
prepare --artifact "$ART/Localizable.strings"
run_audit
assert_eq "exit 1" "$RC" 1
assert_contains "home_path" "$OUT" "home_path"
assert_not_contains "name not printed" "$OUT" "stringsperson"

start "sentinel only in an extended attribute of an artifact file fails"
if command -v xattr >/dev/null 2>&1; then
    new_case; printf 'clean\n' > "$ART/tagged.txt"; xattr -w com.example.note "$SENT" "$ART/tagged.txt"
    prepare --artifact "$ART/tagged.txt"
    expect_fail "xattr" "sentinel"
    assert_contains "location marks xattr" "$OUT" "xattr"
else
    echo "   SKIP xattr not available"
fi

printf '\n== publication audit tests: %s passed, %s failed ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
