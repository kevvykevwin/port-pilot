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
# Home-directory fixture names are assembled the same way, so this file itself
# never contains a literal /Users/<name> that the audit would flag.
U="/Users/"
N_SOME="some""person"; N_QUOTE="quote""person"; N_EOF="eof""person"; N_STR="strings""person"
N_ALLOW1="some""one"; N_ALLOW2="exam""ple"; N_OTHER="other""person"

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
# timed: run a command with a hard 120 s limit (a hang is a failure, not a stuck suite).
timed() {
    python3 -I -c 'import subprocess,sys
try:
    p = subprocess.run(sys.argv[1:], stdout=subprocess.PIPE, timeout=120)
except subprocess.TimeoutExpired:
    print("TIMEOUT"); sys.exit(124)
sys.stdout.buffer.write(p.stdout); sys.exit(p.returncode)' "$@"
}
make_manifest() {
    timed python3 -I "$AUDIT" --print-manifest-template --repo "$REPO" --rev HEAD --ref main "$@" > "$MANIFEST"
}
# make_review [decision]: binds a review to the current manifest.
make_review() {
    printf '{"schemaVersion":1,"manifestSha256":"%s","decision":"%s","reviewer":"Test Reviewer","date":"2026-01-02","personalDataReviewedManually":true}\n' \
        "$(sha "$MANIFEST")" "${1:-approved}" > "$REVIEW"
}
# run_audit: sets OUT and RC (stdout+stderr combined).
run_audit() {
    OUT=$(timed python3 -I "$AUDIT" --manifest "$MANIFEST" --manual-review "$REVIEW" --receipt "$RECEIPT" 2>&1)
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
printf 'path %s%s/project/x\n' "$U" "$N_SOME" > "$REPO/b.txt"
printf 'ok /Users/Shared/ok\n' > "$REPO/c.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "s"; prepare
run_audit
assert_contains "github token" "$OUT" "secret_github_token"
assert_contains "home path" "$OUT" "home_path"
assert_not_contains "allowlisted /Users/Shared not flagged" "$OUT" "c.txt"
assert_not_contains "token value not printed" "$OUT" "ghp_abcdef"
assert_not_contains "name not printed" "$OUT" "$N_SOME"

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
printf '{"p": "%s%s"}\n' "$U" "$N_QUOTE" > "$REPO/q.json"
printf 'at end %s%s' "$U" "$N_EOF" > "$REPO/e.txt"
printf 'shared /Users/Shared/x and /Users/Shared\n' > "$REPO/s.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m h; prepare
run_audit
assert_contains "quoted path flagged" "$OUT" "q.json"
assert_contains "end-of-file path flagged" "$OUT" "e.txt"
assert_not_contains "Shared not flagged" "$OUT" "s.txt"
assert_not_contains "name not printed" "$OUT" "$N_QUOTE"
assert_not_contains "eof name not printed" "$OUT" "$N_EOF"

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
python3 -I - "$ART/Localizable.strings" "$U$N_STR" <<'PY'
import sys
open(sys.argv[1], "wb").write(('"k" = "%s/x";\n' % sys.argv[2]).encode("utf-16-le"))
PY
prepare --artifact "$ART/Localizable.strings"
run_audit
assert_eq "exit 1" "$RC" 1
assert_contains "home_path" "$OUT" "home_path"
assert_not_contains "name not printed" "$OUT" "$N_STR"

start "decompression bomb: tiny .gz/.bz2/.xz expanding past the 64 MiB cap fails closed as too_large"
# Bug caught: decompressing without a cap (memory blowup) or treating an over-cap stream as clean/unreadable.
new_case
python3 -I - "$ART" <<'PY'
import bz2, gzip, lzma, os, sys
blob = b"\0" * (65 * 1024 * 1024)  # 1 MiB over MAX_FILE_BYTES
open(os.path.join(sys.argv[1], "bomb.bin.gz"), "wb").write(gzip.compress(blob, 9))
open(os.path.join(sys.argv[1], "bomb.bin.bz2"), "wb").write(bz2.compress(blob, 9))
open(os.path.join(sys.argv[1], "bomb.bin.xz"), "wb").write(lzma.compress(blob))
PY
for k in gz bz2 xz; do
    size=$(wc -c < "$ART/bomb.bin.$k" | tr -d ' ')
    if [ "$size" -lt 1048576 ]; then ok "bomb.$k is small on disk ($size bytes)"; else bad "bomb.$k not small ($size bytes)"; fi
    make_manifest --artifact "$ART/bomb.bin.$k"; make_review
    expect_fail "bomb $k" "too_large"
    assert_not_contains "bomb $k: not misreported as unreadable" "$OUT" "archive_unreadable"
done

start "stream exactly at the 64 MiB cap is scanned, not rejected (cap boundary)"
# Bug caught: an off-by-one cap that rejects legitimate at-limit content.
new_case
python3 -I - "$ART" <<'PY'
import gzip, os, sys
open(os.path.join(sys.argv[1], "edge.bin.gz"), "wb").write(gzip.compress(b"\0" * (64 * 1024 * 1024), 9))
PY
prepare --artifact "$ART/edge.bin.gz"
run_audit
assert_eq "at-cap gz: exit 0" "$RC" 0
assert_not_contains "at-cap gz: no too_large" "$OUT" "too_large"

start "allowlisted placeholder home names pass; any other username still fails"
# Bug caught: allowlist matching too loosely (prefix/substring) or placeholders still flagged.
new_case
printf 'a %s%s/x\n' "$U" "$N_ALLOW1" > "$REPO/ok1.txt"
printf 'b %s%s/x\n' "$U" "$N_ALLOW2" > "$REPO/ok2.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "placeholders"; prepare
run_audit
assert_eq "placeholders only: exit 0" "$RC" 0
printf 'c %s%s/x\n' "$U" "$N_ALLOW1""x" > "$REPO/near.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "near miss"; prepare
rm -f "$RECEIPT"
expect_fail "placeholder-prefixed name" "home_path"
assert_contains "location names near.txt" "$OUT" "near.txt"
new_case
printf 'd %s%s/x\n' "$U" "$N_OTHER" > "$REPO/real.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "other"; prepare
expect_fail "other username" "home_path"
assert_not_contains "other name not printed" "$OUT" "$N_OTHER"

# ---- published base (already-public objects are not re-audited)
# pub_case: REPO's initial commit is made "public" by an origin/main ref; the
# base file and a forbidden-name file are added before that ref is cut.
mk_pub_ref() { git -C "$REPO" update-ref refs/remotes/origin/main HEAD; PUBSHA=$(git -C "$REPO" rev-parse HEAD); }
commit_all() { git -C "$REPO" add -A && git -C "$REPO" commit -q -m "$1"; }

start "secret only in a blob reachable from the published base passes, with a NOTE"
# Bug caught: published history re-scanned, blocking a release over already-public content.
new_case; printf 'note %s\n' "$SENT" > "$REPO/docs/old.md"; commit_all "old"; mk_pub_ref
git -C "$REPO" commit -q --allow-empty -m "next"; prepare --published-base origin/main
run_audit
assert_eq "exit 0" "$RC" 0
assert_contains "NOTE printed" "$OUT" "objects already public at ${PUBSHA%"${PUBSHA#????????????}"} were not re-audited"
assert_exists "receipt written" "$RECEIPT"
assert_eq "receipt records base sha" "$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["publishedBase"]["sha"])' "$RECEIPT")" "$PUBSHA"

start "same secret in a NEW candidate commit still fails with a base declared"
# Bug caught: the skip keyed on path/commit instead of object id, hiding new content.
new_case; mk_pub_ref; printf 'note %s\n' "$SENT" > "$REPO/docs/new.md"; commit_all "new"
prepare --published-base origin/main
expect_fail "new commit" "sentinel"
assert_contains "location names new.md" "$OUT" "docs/new.md"

start "secret in a base blob re-added in a new commit passes only because the blob is public"
# Documents the object-id semantics: identical bytes already public are skipped.
new_case; printf 'note %s\n' "$SENT" > "$REPO/docs/old.md"; commit_all "old"; mk_pub_ref
cp "$REPO/docs/old.md" "$REPO/docs/copy.md"; commit_all "copy"; prepare --published-base origin/main
run_audit
assert_eq "identical public bytes: exit 0" "$RC" 0

start "tree file unchanged from base is skipped; changed by one byte it is scanned"
# Bug caught: a tree entry skipped by path rather than by blob id, hiding edits.
new_case; printf 'note %s\n' "$SENT" > "$REPO/docs/old.md"; commit_all "old"; mk_pub_ref
printf 'x\n' >> "$REPO/docs/old.md"; commit_all "edit"; prepare --published-base origin/main
expect_fail "one-byte change" "sentinel"
assert_contains "location names old.md" "$OUT" "docs/old.md"

start "published base sha mismatch fails"
# Bug caught: trusting the manifest sha without checking what the ref points at.
new_case; mk_pub_ref; git -C "$REPO" commit -q --allow-empty -m "later"; prepare --published-base origin/main
git -C "$REPO" update-ref refs/remotes/origin/main HEAD
run_audit
assert_eq "exit 1" "$RC" 1
assert_contains "published_base_mismatch" "$OUT" "published_base_mismatch"
assert_absent "no receipt" "$RECEIPT"

start "published base ref that does not exist fails (and scans everything)"
# Bug caught: a missing base silently treated as 'nothing public' without failing.
new_case; mk_pub_ref; prepare --published-base origin/main
git -C "$REPO" update-ref -d refs/remotes/origin/main
run_audit
assert_eq "exit 1" "$RC" 1
assert_contains "published_base_mismatch" "$OUT" "published_base_mismatch"
python3 -I "$AUDIT" --print-manifest-template --repo "$REPO" --rev HEAD --ref main --published-base origin/nope >/dev/null 2>&1
assert_eq "template with unknown base exits 2" "$?" 2

start "forbidden filename existing only in the base still fails (name policy not skipped)"
# Bug caught: skipping a public object also skipping the filename check.
new_case; printf '{}' > "$REPO/credential-abc.json"; commit_all "cred"; mk_pub_ref
git -C "$REPO" commit -q --allow-empty -m "next"; prepare --published-base origin/main
run_audit
assert_eq "exit 1" "$RC" 1
assert_contains "forbidden_file" "$OUT" "forbidden_file"
assert_absent "no receipt" "$RECEIPT"

start "malformed publishedBase in manifest exits 2"
new_case; prepare
python3 -I - "$MANIFEST" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); m["publishedBase"] = {"ref": "origin/main", "sha": "nothex"}; json.dump(m, open(sys.argv[1], "w"))
PY
make_review
python3 -I "$AUDIT" --manifest "$MANIFEST" --manual-review "$REVIEW" --receipt "$RECEIPT" >/dev/null 2>&1
assert_eq "exit 2" "$?" 2

start "absent publishedBase keeps old behavior: history secret fails, no NOTE"
new_case; printf 'note %s\n' "$SENT" > "$REPO/docs/old.md"; commit_all "old"; mk_pub_ref; prepare
expect_fail "no base declared" "sentinel"
assert_not_contains "no NOTE" "$OUT" "already public"

start "sentinel only in an extended attribute of an artifact file fails"
if command -v xattr >/dev/null 2>&1; then
    new_case; printf 'clean\n' > "$ART/tagged.txt"; xattr -w com.example.note "$SENT" "$ART/tagged.txt"
    prepare --artifact "$ART/tagged.txt"
    expect_fail "xattr" "sentinel"
    assert_contains "location marks xattr" "$OUT" "xattr"
else
    echo "   SKIP xattr not available"
fi


# ---- fail-open regressions (each case names the bug it catches)
N_LOC="loc""person"
TOK="gh""p_abcdefghijklmnopqrstuvwxyz0123456789"

start "git replace ref hiding a dirty blob behind a clean one still fails (replace refs must not rewrite audited content)"
new_case; printf 'note %s\n' "$SENT" > "$REPO/docs/d.md"; printf 'clean\n' > "$REPO/docs/clean.md"; commit_all "pair"
DIRTY=$(git -C "$REPO" rev-parse HEAD:docs/d.md); CLEAN=$(git -C "$REPO" rev-parse HEAD:docs/clean.md)
git -C "$REPO" replace "$DIRTY" "$CLEAN"; prepare
expect_fail "replace ref" "sentinel"

start "shallow repository fails closed (missing history cannot be audited)"
new_case; git -C "$REPO" commit -q --allow-empty -m second; git -C "$REPO" rev-parse HEAD > "$REPO/.git/shallow"; prepare
expect_fail "shallow" "shallow_repo"

start "repository with info/grafts fails closed (grafts rewrite history the push does not see)"
new_case; git -C "$REPO" commit -q --allow-empty -m second; mkdir -p "$REPO/.git/info"
git -C "$REPO" rev-parse HEAD > "$REPO/.git/info/grafts"; prepare
expect_fail "grafts" "grafts_present"

start "unreadable subdirectory in an artifact dir is a finding (silently dropped from scan and hash otherwise)"
new_case; mkdir -p "$ART/Dir.app/locked"; printf '%s\n' "$SENT" > "$ART/Dir.app/locked/s.txt"
chmod 000 "$ART/Dir.app/locked"; prepare --artifact "$ART/Dir.app"
run_audit; chmod 755 "$ART/Dir.app/locked"
assert_eq "unreadable dir: exit 1" "$RC" 1
assert_contains "unreadable dir: reports unreadable" "$OUT" "FINDING unreadable"
assert_contains "unreadable dir: location names it" "$OUT" "locked"
assert_absent "unreadable dir: no receipt" "$RECEIPT"

start "tar.gz of two concatenated tars: second tar's contents are scanned (tarfile stops at first end-of-archive)"
new_case
python3 -I - "$ART/two.tar.gz" "$SENT" <<'PY'
import gzip, io, sys, tarfile
def mk(name, data):
    b = io.BytesIO()
    with tarfile.open(fileobj=b, mode="w:") as t:
        i = tarfile.TarInfo(name); i.size = len(data); t.addfile(i, io.BytesIO(data))
    return b.getvalue()
open(sys.argv[1], "wb").write(gzip.compress(mk("a.txt", b"clean\n") + mk("b.txt", sys.argv[2].encode())))
PY
prepare --artifact "$ART/two.tar.gz"
expect_fail "concatenated tars in gzip" "sentinel"

start "plain .tar of two concatenated tars: gzip nested inside the second tar is still opened"
new_case
python3 -I - "$ART/two.tar" "$SENT" <<'PY'
import gzip, io, sys, tarfile
def mk(name, data):
    b = io.BytesIO()
    with tarfile.open(fileobj=b, mode="w:") as t:
        i = tarfile.TarInfo(name); i.size = len(data); t.addfile(i, io.BytesIO(data))
    return b.getvalue()
hidden = gzip.compress(sys.argv[2].encode())
open(sys.argv[1], "wb").write(mk("a.txt", b"clean\n") + mk("n.txt.gz", hidden))
PY
prepare --artifact "$ART/two.tar"
expect_fail "concatenated plain tars" "sentinel"

start "sentinel in a tracked directory name or file name fails (tree objects were skipped)"
new_case; mkdir "$REPO/dir_$SENT"; printf 'ok\n' > "$REPO/dir_$SENT/x.txt"; commit_all "dirname"; prepare
expect_fail "directory name" "sentinel"
new_case; printf 'ok\n' > "$REPO/docs/$SENT.txt"; commit_all "filename"; prepare
expect_fail "file name" "sentinel"

start "tree with a sentinel name reachable from the published base is still not re-audited"
new_case; mkdir "$REPO/dir_$SENT"; printf 'ok\n' > "$REPO/dir_$SENT/x.txt"; commit_all "dirname"; mk_pub_ref
git -C "$REPO" commit -q --allow-empty -m next; prepare --published-base origin/main
run_audit
assert_eq "published tree: exit 0" "$RC" 0

start "sentinel in an artifact directory entry name or subdirectory name fails (names only hit the filename list)"
new_case; mkdir "$ART/Dir.app"; printf 'clean\n' > "$ART/Dir.app/$SENT.txt"; prepare --artifact "$ART/Dir.app"
expect_fail "artifact file name" "sentinel"
new_case; mkdir -p "$ART/Dir.app/${SENT}_d"; printf 'clean\n' > "$ART/Dir.app/${SENT}_d/x.txt"; prepare --artifact "$ART/Dir.app"
expect_fail "artifact subdirectory name" "sentinel"

start "sentinel in an archive member name fails (zip and tar.gz)"
new_case
python3 -I - "$ART" "$SENT" <<'PY'
import gzip, io, os, sys, tarfile, zipfile
d, s = sys.argv[1], sys.argv[2]
z = zipfile.ZipFile(os.path.join(d, "n.zip"), "w"); z.writestr(s + ".txt", "x"); z.close()
b = io.BytesIO()
with tarfile.open(fileobj=b, mode="w:") as t:
    i = tarfile.TarInfo(s + ".txt"); i.size = 1; t.addfile(i, io.BytesIO(b"x"))
open(os.path.join(d, "n.tar.gz"), "wb").write(gzip.compress(b.getvalue()))
PY
prepare --artifact "$ART/n.zip"
expect_fail "zip member name" "sentinel"
make_manifest --artifact "$ART/n.tar.gz"; make_review
expect_fail "tar.gz member name" "sentinel"

start "git cat-file stream cut short is object_unreadable, not scanned as complete (short read / EOF in skip loop)"
mk_fake_git() { # $1 = shell snippet run in place of `git ... cat-file ...`
    FAKEBIN="$CASE/fakebin"; mkdir -p "$FAKEBIN"
    printf '#!/bin/sh\ncase " $* " in *" cat-file "*) %s ;; esac\nexec "%s" "$@"\n' "$1" "$(command -v git)" > "$FAKEBIN/git"
    chmod +x "$FAKEBIN/git"
}
run_audit_fake() { OLDPATH=$PATH; PATH="$FAKEBIN:$PATH"; run_audit; PATH=$OLDPATH; }
new_case; prepare
mk_fake_git 'read line; printf "%s blob 100\n" "$line"; printf short; exit 0'
run_audit_fake
assert_eq "short read: exit 1" "$RC" 1
assert_contains "short read: object_unreadable" "$OUT" "object_unreadable"
assert_absent "short read: no receipt" "$RECEIPT"
mk_fake_git 'read line; printf "%s blob 99999999999\n" "$line"; printf short; exit 0'
run_audit_fake
assert_eq "EOF in skip loop: exit 1 (no hang)" "$RC" 1
assert_contains "EOF in skip loop: object_unreadable" "$OUT" "object_unreadable"
assert_not_contains "EOF in skip loop: no timeout" "$OUT" "TIMEOUT"

start "FIFO inside an artifact directory is a finding and does not hang (open() on a FIFO blocks forever)"
new_case; mkdir "$ART/Dir.app"; printf 'x\n' > "$ART/Dir.app/ok.txt"; mkfifo "$ART/Dir.app/pipe"
make_manifest --artifact "$ART/Dir.app"; make_review
assert_not_contains "manifest build did not hang" "$(cat "$MANIFEST")" "TIMEOUT"
run_audit
assert_eq "fifo: exit 1" "$RC" 1
assert_contains "fifo: reports special_file" "$OUT" "special_file"
assert_not_contains "fifo: no timeout" "$OUT" "TIMEOUT"

png_with() { # out, chunk type, python expression for the chunk body
    python3 -I - "$1" "$2" "$3" <<'PY'
import struct, sys, zlib
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
kind, body = sys.argv[2].encode(), eval(sys.argv[3])
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
png += chunk(kind, body) + chunk(b"IDAT", zlib.compress(b"\0\0\0\0")) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
PY
}
start "PNG zTXt payload over the cap is too_large, corrupt zTXt is unreadable, small valid zTXt passes (silent truncation)"
new_case
png_with "$ART/big.png" zTXt 'b"k\0\0" + zlib.compress(b"\0" * (65 * 1024 * 1024))'
prepare --artifact "$ART/big.png"
expect_fail "oversized zTXt" "too_large"
new_case
png_with "$ART/bad.png" zTXt 'b"k\0\0" + b"this is not zlib data"'
prepare --artifact "$ART/bad.png"
run_audit
assert_eq "corrupt zTXt: exit 1" "$RC" 1
assert_contains "corrupt zTXt: unreadable" "$OUT" "FINDING unreadable"
new_case
png_with "$ART/ok.png" zTXt 'b"k\0\0" + zlib.compress(b"hello")'
prepare --artifact "$ART/ok.png"
run_audit
assert_eq "valid zTXt: exit 0" "$RC" 0

start "more than 256 extended attributes is a too_large finding (list was silently cut at 256)"
if command -v xattr >/dev/null 2>&1; then
    new_case; printf 'clean\n' > "$ART/many.txt"
    i=0; while [ "$i" -lt 270 ]; do xattr -w "com.example.k$i" v "$ART/many.txt"; i=$((i + 1)); done
    prepare --artifact "$ART/many.txt"
    run_audit
    assert_eq "many xattrs: exit 1" "$RC" 1
    assert_contains "many xattrs: too_large" "$OUT" "too_large"
    assert_contains "many xattrs: location marks xattr" "$OUT" "xattr"
else
    echo "   SKIP xattr not available"
fi

start "locations never print secrets or home paths from names (redaction covered only sentinel and private patterns)"
new_case; mkdir -p "$REPO/a$U$N_LOC" "$REPO/$TOK"
printf 'x\n' > "$REPO/a$U$N_LOC/.env"; printf 'x\n' > "$REPO/$TOK/.env"; commit_all "named"; prepare
run_audit
assert_eq "redaction: exit 1" "$RC" 1
assert_contains "redaction: findings still reported" "$OUT" "forbidden_file"
assert_not_contains "home name not printed" "$OUT" "$N_LOC"
assert_not_contains "token not printed" "$OUT" "$TOK"

printf '\n== publication audit tests: %s passed, %s failed ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
