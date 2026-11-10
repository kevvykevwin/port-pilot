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
trap 'chmod -R u+rwx "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ -n "$TRAP_PROBE" ]; then # self-test of the signal traps (see end of file)
    echo "PROBE_ROOT=$ROOT"; kill -"$TRAP_PROBE" $$; echo PROBE_CONTINUED; exit 0
fi
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

start "forbidden names match regardless of case (the macOS volume is case-insensitive)"
new_case; mkdir -p "$ART/Case.app/Contents/Resources"
printf 'x\n' > "$ART/Case.app/Contents/Resources/.ENV"
prepare --artifact "$ART/Case.app"
run_audit; assert_eq "upper-case .ENV: exit 1" "$RC" 1; assert_contains "upper-case .ENV: forbidden_file" "$OUT" "forbidden_file"
new_case
python3 -I - "$ART/case.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("cfg/Private-Config.JSON", "{}")
PY
prepare --artifact "$ART/case.zip"
run_audit; assert_eq "mixed-case zip member: exit 1" "$RC" 1; assert_contains "mixed-case zip member: forbidden_file" "$OUT" "forbidden_file"
new_case; printf 'ok\n' > "$REPO/notes.txt"; commit_all "clean"; prepare
run_audit; assert_eq "control: ordinary names stay clean" "$RC" 0

start "a tar link named like a forbidden file is reported (links skipped the name check)"
for kind in hard sym; do
new_case
python3 -I - "$ART/links.tar" "$kind" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w") as t:
    data = b"API=abc\n"
    i = tarfile.TarInfo("notes.txt"); i.size = len(data); t.addfile(i, io.BytesIO(data))
    link = tarfile.TarInfo("cfg/.env")
    link.type = tarfile.LNKTYPE if sys.argv[2] == "hard" else tarfile.SYMTYPE
    link.linkname = "notes.txt" if sys.argv[2] == "hard" else "../notes.txt"
    t.addfile(link)
PY
prepare --artifact "$ART/links.tar"
run_audit; assert_eq "$kind link: exit 1" "$RC" 1; assert_contains "$kind link: forbidden_file" "$OUT" "forbidden_file"
done

start "a trailing \".\" component does not hide a forbidden name or a .strings file (bsdtar drops it)"
new_case
python3 -I - "$ART/dot.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("cfg/.env/.", "API=abc\n")
PY
prepare --artifact "$ART/dot.zip"
run_audit; assert_eq "zip cfg/.env/.: exit 1" "$RC" 1; assert_contains "zip cfg/.env/.: forbidden_file" "$OUT" "forbidden_file"
new_case
python3 -I - "$ART/dot.tar" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w") as t:
    data = b"API=abc\n"
    i = tarfile.TarInfo("notes.txt"); i.size = len(data); t.addfile(i, io.BytesIO(data))
    link = tarfile.TarInfo("cfg/.env/."); link.type = tarfile.LNKTYPE; link.linkname = "notes.txt"; t.addfile(link)
PY
prepare --artifact "$ART/dot.tar"
run_audit; assert_eq "tar hard link cfg/.env/.: exit 1" "$RC" 1; assert_contains "tar hard link cfg/.env/.: forbidden_file" "$OUT" "forbidden_file"
new_case
python3 -I - "$ART/strings.zip" "$SENT" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("en.lproj/Localizable.strings/.", ('"k" = "' + sys.argv[2] + '";').encode("utf-16-le"))
PY
prepare --artifact "$ART/strings.zip"
expect_fail "UTF-16 .strings behind a trailing dot" "sentinel"

start "a symlink in a directory artifact named like a forbidden file is reported"
new_case; mkdir -p "$ART/Link.app/Contents"; printf 'API=abc\n' > "$ART/Link.app/Contents/notes.txt"
ln -s notes.txt "$ART/Link.app/Contents/.env"
prepare --artifact "$ART/Link.app"
run_audit; assert_eq "symlink .env: exit 1" "$RC" 1; assert_contains "symlink .env: forbidden_file" "$OUT" "forbidden_file"

start "tar members of an unknown type are scanned (bsdtar writes them as regular files)"
new_case
python3 -I - "$ART/typez.tar" "$SENT" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w", format=tarfile.USTAR_FORMAT) as t:
    for name, data in (("cfg/.env", b"API=abc\n"),
                       ("en.lproj/Localizable.strings", ('"k" = "' + sys.argv[2] + '";').encode("utf-16-le"))):
        i = tarfile.TarInfo(name); i.size = len(data); i.type = b"Z"; t.addfile(i, io.BytesIO(data))
PY
prepare --artifact "$ART/typez.tar"
run_audit
assert_eq "type Z: exit 1" "$RC" 1
assert_contains "type Z: forbidden_file" "$OUT" "forbidden_file"
assert_contains "type Z: UTF-16 sentinel found" "$OUT" "sentinel"

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

# ---- review round: zip layouts the stream extractor reads but zipfile does not
# mk_zip_layout KIND OUT: builds a zip whose bytes hold an entry the central
# directory does not list. The sentinel is deflated so the raw scan cannot see it.
mk_zip_layout() {
    python3 -I - "$1" "$2" "$SENT" <<'PY'
import io, sys, zipfile
kind, out, sent = sys.argv[1], sys.argv[2], sys.argv[3].encode()
def build(entries):
    b = io.BytesIO()
    with zipfile.ZipFile(b, "w", zipfile.ZIP_DEFLATED) as z:
        for n, d in entries:
            z.writestr(n, d)
        start = z.start_dir
    return b.getvalue(), start
dirty, dstart = build([("s.txt", b"note " + sent + b"\n")])
clean, _ = build([("c.txt", b"clean text " * 20)])
local_only = dirty[:dstart]
assert sent not in dirty, "sentinel must be hidden by deflate"
if kind == "concat":
    data = dirty + clean
elif kind == "prefix":
    data = local_only + clean
elif kind == "middle":
    import struct
    base, cd = build([("a.txt", b"clean a " * 20), ("b.txt", b"clean b " * 20)])
    z = zipfile.ZipFile(io.BytesIO(base))
    off_b = z.infolist()[1].header_offset
    ins = len(local_only)
    data = bytearray(base[:off_b] + local_only + base[off_b:])
    cd += ins
    # patch b's central-directory header_offset and the end-of-directory offset
    pos = data.index(b"PK\x01\x02", cd)
    pos = data.index(b"PK\x01\x02", pos + 4)
    struct.pack_into("<I", data, pos + 42, off_b + ins)
    eocd = data.rindex(b"PK\x05\x06")
    struct.pack_into("<I", data, eocd + 16, cd)
    data = bytes(data)
open(out, "wb").write(data)
PY
}

start "zip A concatenated with clean zip B: A's deflated entry is not in B's central directory but a stream extractor reads it (archive_unreadable)"
new_case; mk_zip_layout concat "$ART/cat.zip"; prepare --artifact "$ART/cat.zip"
expect_fail "concatenated zips" "archive_unreadable"

start "unlisted deflated local entry placed before a clean zip is archive_unreadable (lowest central-directory offset not 0)"
new_case; mk_zip_layout prefix "$ART/pre.zip"; prepare --artifact "$ART/pre.zip"
expect_fail "unlisted prefix entry" "archive_unreadable"

start "unlisted deflated local entry between two listed entries is archive_unreadable (local-header signature at an offset no directory entry owns)"
new_case; mk_zip_layout middle "$ART/mid.zip"; prepare --artifact "$ART/mid.zip"
expect_fail "unlisted middle entry" "archive_unreadable"

start "ordinary zips with many deflated entries, a stored nested zip and data descriptors still pass (no false positive)"
new_case; mkdir "$CASE/zs"
python3 -I - "$CASE/zs" "$ART/ctl.zip" <<'PY'
import io, os, sys, zipfile
d, out = sys.argv[1], sys.argv[2]
for i in range(6):
    open(os.path.join(d, f"f{i}.txt"), "w").write(f"line {i}\n" * 50)
inner = io.BytesIO()
with zipfile.ZipFile(inner, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("in.txt", "inner clean\n" * 30)
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for i in range(6):
        z.write(os.path.join(d, f"f{i}.txt"), f"f{i}.txt")
    z.writestr(zipfile.ZipInfo("nested.zip"), inner.getvalue(), zipfile.ZIP_STORED)
PY
prepare --artifact "$ART/ctl.zip"
run_audit
assert_eq "python zip control: exit 0" "$RC" 0
if command -v ditto >/dev/null 2>&1; then
    mkdir -p "$CASE/zs/Fake.app/Contents"; cp "$CASE/zs"/f*.txt "$CASE/zs/Fake.app/Contents/"
    ditto -c -k --keepParent "$CASE/zs/Fake.app" "$ART/ditto.zip"
    rm -f "$RECEIPT"; make_manifest --artifact "$ART/ditto.zip"; make_review; run_audit
    assert_eq "ditto zip control: exit 0" "$RC" 0
fi
if command -v zip >/dev/null 2>&1; then
    (cd "$CASE/zs" && zip -q -r "$ART/cli.zip" Fake.app f0.txt)
    rm -f "$RECEIPT"; make_manifest --artifact "$ART/cli.zip"; make_review; run_audit
    assert_eq "zip CLI control: exit 0" "$RC" 0
fi

# ---- review round: symlink targets inside artifact directories
start "in-bundle symlink whose target holds the sentinel fails (targets were hashed, never scanned)"
new_case; mkdir "$ART/Dir.app"; ln -s "inner_$SENT" "$ART/Dir.app/link"
prepare --artifact "$ART/Dir.app"
expect_fail "symlink target sentinel" "sentinel"
new_case; mkdir "$ART/Dir.app"; ln -s "tok-$TOK" "$ART/Dir.app/link"
prepare --artifact "$ART/Dir.app"
run_audit
assert_contains "symlink target token: secret_github_token" "$OUT" "secret_github_token"
assert_not_contains "symlink target token: not printed" "$OUT" "$TOK"
new_case; mkdir "$ART/Dir.app"; ln -s "$U$N_LOC/x/y" "$ART/Dir.app/link"
prepare --artifact "$ART/Dir.app"
run_audit
assert_contains "symlink absolute home target: home_path" "$OUT" "home_path"
assert_not_contains "symlink absolute home target: name not printed" "$OUT" "$N_LOC"

start "an artifact that is itself a symlink has its target scanned (top-level symlink case)"
new_case; ln -s "inner_$SENT" "$ART/top.link"; prepare --artifact "$ART/top.link"
expect_fail "top-level symlink target" "sentinel"

# ---- review round: redaction keeps the useful part of a location
start "artifact finding location keeps the in-artifact file name while the home name and token are replaced"
new_case; D="$ART$U$N_LOC/Dir.app"; mkdir -p "$D"; printf 'x\n' > "$D/.env"; printf 'x\n' > "$D/n-$TOK.txt"
prepare --artifact "$D"
run_audit
assert_eq "redaction keeps path: exit 1" "$RC" 1
assert_contains "location still shows relative file name" "$OUT" "Dir.app/.env"
assert_not_contains "location is not wholly replaced" "$OUT" "<redacted-location>"
assert_not_contains "home name not printed" "$OUT" "$N_LOC"
assert_not_contains "token not printed" "$OUT" "$TOK"
assert_contains "token replaced in place" "$OUT" "/n-<redacted>.txt"

# ---- review round: unreadable files do not crash the audit
start "chmod 000 file inside an artifact directory is an unreadable finding, not a traceback (template and audit)"
if [ "$(id -u)" -eq 0 ]; then
    echo "   SKIP running as root"
else
    new_case; D="$ART$U$N_LOC/Dir.app"; mkdir -p "$D"; printf 'x\n' > "$D/ok.txt"; printf '%s\n' "$SENT" > "$D/locked.txt"
    chmod 000 "$D/locked.txt"
    make_manifest --artifact "$D"; TRC=$?; make_review
    assert_eq "template exits 0" "$TRC" 0
    assert_contains "manifest is not empty" "$(cat "$MANIFEST")" "artifacts"
    run_audit; chmod 644 "$D/locked.txt"
    assert_eq "unreadable file: exit 1" "$RC" 1
    assert_contains "unreadable file: reports unreadable" "$OUT" "FINDING unreadable"
    assert_contains "unreadable file: location names it" "$OUT" "locked.txt"
    assert_not_contains "unreadable file: no traceback" "$OUT" "Traceback"
    assert_not_contains "unreadable file: home name not printed" "$OUT" "$N_LOC"
    assert_absent "unreadable file: no receipt" "$RECEIPT"
fi

# ---- review round: home path split across tracked directories
start "tracked path fixtures/Users/<name>/x.txt fails (tree objects store one component at a time)"
new_case; mkdir -p "$REPO/fixtures/Users/$N_LOC"; printf 'x\n' > "$REPO/fixtures/Users/$N_LOC/x.txt"
commit_all "split path"; prepare
run_audit
assert_eq "split home path: exit 1" "$RC" 1
assert_contains "split home path: home_path" "$OUT" "home_path"
assert_not_contains "split home path: name not printed" "$OUT" "$N_LOC"

start "split home path in a file already public (published base) is not re-flagged"
new_case; mkdir -p "$REPO/fixtures/Users/$N_LOC"; printf 'x\n' > "$REPO/fixtures/Users/$N_LOC/x.txt"
commit_all "split path"; mk_pub_ref; prepare --published-base origin/main
run_audit
assert_eq "public split path: exit 0" "$RC" 0

# ---- review round: first-object short read
start "short cat-file read reports the FIRST object requested (a revert of the length check would drop this location)"
new_case; prepare
mk_fake_git 'read line; printf "%s blob 100\n" "$line"; printf short; exit 0'
run_audit_fake
SHORT=$(git -C "$REPO" rev-parse --short=10 HEAD)
assert_contains "first object flagged" "$OUT" "FINDING object_unreadable tree@$SHORT:README.md"

# ---- review round 2: walk local headers like a streaming extractor
cat > "$ROOT/mkzip.py" <<'PY'
import io, struct, sys, zlib, zipfile
kind, out, sent = sys.argv[1], sys.argv[2], sys.argv[3].encode()
def deflate(b):
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    return c.compress(b) + c.flush()
def crc(b): return zlib.crc32(b) & 0xFFFFFFFF
def local(name, method, flags, c, cs, us, data, extra=b""):
    return b"PK\x03\x04" + struct.pack("<HHHHHIIIHH", 20, flags, method, 0, 0x21, c, cs, us, len(name), len(extra)) + name + extra + data
def cdent(name, method, flags, c, cs, us, off, extra=b""):
    return b"PK\x01\x02" + struct.pack("<HHHHHHIIIHHHHHII", 20, 20, flags, method, 0, 0x21, c, cs, us, len(name), len(extra), 0, 0, 0, 0, off) + name + extra
def upath(name, target, version=1, crc_of=None):
    body = struct.pack("<BI", version, crc(name if crc_of is None else crc_of)) + target
    return struct.pack("<HH", 0x7075, len(body)) + body
def z64tail(cd_off, cd_size, n, e32, loc_delta=0):
    """zip64 end record + locator + 32-bit end record. e32 'marker' puts the
    see-zip64 markers in every 32-bit field; a tuple (disk, cddisk, nd, nt, size, off) is used verbatim."""
    rec_pos = cd_off + cd_size
    rec = b"PK\x06\x06" + struct.pack("<QHHIIQQQQ", 44, 45, 45, 0, 0, n, n, cd_size, cd_off)
    loc = b"PK\x06\x07" + struct.pack("<IQI", 0, rec_pos + loc_delta, 1)
    f = (0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF) if e32 == "marker" else e32
    return rec + loc + b"PK\x05\x06" + struct.pack("<HHHHIIH", *f, 0)
def eocd(n, size, off): return b"PK\x05\x06" + struct.pack("<HHHHIIH", 0, 0, n, n, size, off, 0)
clean = b"clean text " * 20
hid = b"note " + sent + b"\n"
ad, hd = deflate(clean), deflate(hid)
assert sent not in ad + hd
H = local(b"h.txt", 8, 0, crc(hid), len(hd), len(hid), hd)
def finish(body, cd_entries):
    cd = b"".join(cd_entries)
    return body + cd + eocd(len(cd_entries), len(cd), len(body))
def plain_zip(entries):
    b = io.BytesIO()
    with zipfile.ZipFile(b, "w", zipfile.ZIP_DEFLATED) as z:
        for n, d in entries: z.writestr(n, d)
    return b.getvalue()
if kind == "csize_cover":
    A = local(b"a.txt", 8, 0, crc(clean), len(ad), len(clean), ad)
    data = finish(A + H, [cdent(b"a.txt", 8, 0, crc(clean), len(ad) + len(H), len(clean), 0)])
elif kind == "csize_cover_dd":
    dd = b"PK\x07\x08" + struct.pack("<III", crc(clean), len(ad), len(clean))
    A = local(b"a.txt", 8, 8, 0, 0, 0, ad + dd)
    data = finish(A + H, [cdent(b"a.txt", 8, 8, crc(clean), len(ad) + len(dd) + len(H), len(clean), 0)])
elif kind == "local_csize_lie":
    # Bug caught: a deflated entry (no descriptor) whose LOCAL csize runs past its
    # real deflate stream. The directory and the inflated data agree, but a
    # streaming extractor skips by the local csize and lands on the hidden
    # complete local entry h.txt inside b.bin's stored data.
    pad = b"pad"
    B_data = pad + H
    Bh = local(b"b.bin", 0, 0, crc(B_data), len(B_data), len(B_data), b"")
    lie = len(ad) + len(Bh) + len(pad)
    A = local(b"a.txt", 8, 0, crc(clean), lie, len(clean), ad)
    B = Bh + B_data
    data = finish(A + B, [cdent(b"a.txt", 8, 0, crc(clean), len(ad), len(clean), 0),
                          cdent(b"b.bin", 0, 0, crc(B_data), len(B_data), len(B_data), len(A))])
elif kind in ("dd_inflate_overrun", "dd_wellformed"):
    # Bug caught: a deflated entry WITH a data descriptor whose directory and
    # descriptor both claim the clean prefix (64 'A' bytes) while the real stream
    # inflates further into a token. zipfile reads 64 bytes; ditto/unzip extract
    # the token. The inflated length/CRC must be compared to the directory.
    fake = b"sk-ant-" + b"api03-FAKEFAKEFAKEFAKE0000"
    pre = b"A" * 64
    full = pre + b"\n" + fake if kind == "dd_inflate_overrun" else pre
    st = deflate(full)
    dd = b"PK\x07\x08" + struct.pack("<III", crc(pre), len(st), len(pre))
    nm = b"Contents/Resources/notes.txt"
    A = local(nm, 8, 8, 0, 0, 0, st + dd)
    data = finish(A, [cdent(nm, 8, 8, crc(pre), len(st), len(pre), 0)])
elif kind == "local_csize_small":
    # Bug caught: a deflated entry (no descriptor) whose LOCAL csize is too SMALL.
    # The real stream is one final stored block holding padding and then a complete
    # hidden local entry; the directory has the true size, but a streaming extractor
    # skips by the short local csize and lands on the hidden entry inside the block.
    pad = b"pad"
    payload = pad + H
    n = len(payload)
    stream = b"\x01" + struct.pack("<HH", n, n ^ 0xFFFF) + payload
    short = len(stream) - len(H)
    A = local(b"a.bin", 8, 0, crc(payload), short, n, stream)
    data = finish(A, [cdent(b"a.bin", 8, 0, crc(payload), len(stream), n, 0)])
elif kind == "local_usize_lie":
    # Bug caught: an honest deflated entry whose only lie is the LOCAL uncompressed
    # size (+7); dropping the len(body) == usize comparison would accept it.
    A = local(b"a.txt", 8, 0, crc(clean), len(ad), len(clean) + 7, ad)
    data = finish(A, [cdent(b"a.txt", 8, 0, crc(clean), len(ad), len(clean), 0)])
elif kind == "stored_cover":
    A = local(b"a.txt", 0, 0, crc(clean), len(clean), len(clean), clean)
    cov = clean + H
    data = finish(A + H, [cdent(b"a.txt", 0, 0, crc(cov), len(cov), len(cov), 0)])
elif kind == "twoeocd":
    # Bug caught: the zip64 end record points at the real directory (one stored
    # entry x.bin) while the 32-bit end record points at a second directory
    # inside x.bin's data that lists the hidden deflated entry h.txt. zipfile
    # follows zip64 (sees x.bin only); unzip follows the 32-bit record (h.txt).
    xh = len(local(b"x.bin", 0, 0, 0, 0, 0, b""))
    # The inner bytes start with padding so x.bin is not itself sniffed as a zip.
    pad = b"padding "
    cd2 = cdent(b"h.txt", 8, 0, crc(hid), len(hd), len(hid), xh + len(pad))
    inner = pad + H + cd2
    X = local(b"x.bin", 0, 0, crc(inner), len(inner), len(inner), inner)
    cd1 = cdent(b"x.bin", 0, 0, crc(inner), len(inner), len(inner), 0)
    e32 = (0, 0, 1, 1, len(cd2), xh + len(pad) + len(H))
    data = X + cd1 + z64tail(len(X), len(cd1), 1, e32)
elif kind in ("z64_marker", "z64_equal", "z64_loc_off", "z64_disk", "z64_count"):
    # Bug caught: a zip64 end record whose 32-bit twin is all markers or agrees
    # with it is ordinary; a locator pointing elsewhere, or any 32-bit field that
    # disagrees with zip64, lets two extractors read different directories.
    A = local(b"a.txt", 0, 0, crc(clean), len(clean), len(clean), clean)
    cd1 = cdent(b"a.txt", 0, 0, crc(clean), len(clean), len(clean), 0)
    e32 = {"z64_equal": (0, 0, 1, 1, len(cd1), len(A)), "z64_disk": (1, 0, 1, 1, len(cd1), len(A)),
           "z64_count": (0, 0, 1, 2, len(cd1), len(A))}.get(kind, "marker")
    data = A + cd1 + z64tail(len(A), len(cd1), 1, e32, 1 if kind == "z64_loc_off" else 0)
elif kind == "dir_data":
    # Bug caught: a directory entry (name ends in /) that carries a deflated body;
    # zipfile skips it as a directory but unzip -p prints the bytes.
    D = local(b"d/", 8, 0, crc(hid), len(hd), len(hid), hd)
    data = finish(D, [cdent(b"d/", 8, 0, crc(hid), len(hd), len(hid), 0)])
elif kind in ("upath_local", "upath_cd", "upath_ok", "upath_badcrc", "upath_badver"):
    # Bug caught: a Unicode Path extra (0x7075) renaming notes.txt to .env;
    # bsdtar honours it while zipfile and the filename check see notes.txt.
    n = b"notes.txt"
    tgt = b"notes.txt" if kind in ("upath_ok", "upath_badcrc", "upath_badver") else b".env"  # badcrc/badver: right name, only the CRC/version is wrong
    ex = upath(n, tgt, version=2 if kind == "upath_badver" else 1, crc_of=b"other" if kind == "upath_badcrc" else None)
    plain = kind == "upath_cd"
    A = local(n, 8, 0, crc(hid), len(hd), len(hid), hd, b"" if plain else ex)
    data = finish(A, [cdent(n, 8, 0, crc(hid), len(hd), len(hid), 0, ex if kind in ("upath_cd", "upath_ok") else b"")])
elif kind == "method_mismatch":
    A = local(b"s.txt", 8, 0, crc(hid), len(hd), len(hid), hd)
    data = finish(A, [cdent(b"s.txt", 0, 0, crc(hd), len(hd), len(hd), 0)])
elif kind == "sfx_prefix":
    data = b"#!/bin/sh\nexit 0\n" + plain_zip([("s.txt", hid)])
elif kind == "png_polyglot":
    def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"\0\0\0\0")) + chunk(b"IEND", b"")
    data = png + plain_zip([("s.txt", hid)])
elif kind == "png_clean":
    def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"\0\0\0\0")) + chunk(b"IEND", b"")
elif kind == "zip64_stream":
    class U(io.RawIOBase):
        def __init__(s, f): s.f = f
        def writable(s): return True
        def write(s, b): return s.f.write(b)
    with open(out, "wb") as f:
        with zipfile.ZipFile(U(f), "w", zipfile.ZIP_DEFLATED) as z:
            with z.open("big.txt", "w", force_zip64=True) as w: w.write(b"line\n" * 5000)
            with z.open("small.txt", "w") as w: w.write(b"small clean\n" * 10)
            with z.open("st.txt", "w", force_zip64=True) as w: w.write(b"more\n" * 100)
    sys.exit(0)
elif kind in ("zip64_local_lie", "zip64_no_extra", "zip64_csize_only"):
    # Stored entry whose local 32-bit sizes are 0xFFFFFFFF. The directory covers
    # the hidden deflated local entry that follows; the local zip64 extra says
    # what a stream extractor reads.
    cov = clean + H
    if kind == "zip64_local_lie":
        ex = struct.pack("<HHQQ", 1, 16, len(clean), len(clean))
    elif kind == "zip64_csize_only":
        ex = struct.pack("<HHQQ", 1, 16, len(cov), len(clean))
    else:
        ex = b""
    A = b"PK\x03\x04" + struct.pack("<HHHHHIIIHH", 45, 0, 0, 0, 0x21, crc(clean), 0xFFFFFFFF, 0xFFFFFFFF, 5, len(ex)) + b"a.txt" + ex + clean
    data = finish(A + H, [cdent(b"a.txt", 0, 0, crc(cov), len(cov), len(cov), 0)])
elif kind == "zip64_csize_ambiguous":
    # Stored entry, only the local compressed size unset, 16-byte extra (A, B).
    # APPNOTE order reads csize=B (matching the directory); libarchive reads
    # csize=A and then finds the hidden deflated entry inside the span.
    cov = clean + H
    ex = struct.pack("<HHQQ", 1, 16, len(clean), len(cov))
    A = b"PK\x03\x04" + struct.pack("<HHHHHIIIHH", 45, 0, 0, 0, 0x21, crc(cov), 0xFFFFFFFF, len(cov), 5, len(ex)) + b"a.txt" + ex + clean
    data = finish(A + H, [cdent(b"a.txt", 0, 0, crc(cov), len(cov), len(cov), 0)])
elif kind == "zip64_real":
    with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:
        zi = zipfile.ZipInfo("st.txt"); zi.compress_type = zipfile.ZIP_STORED
        with z.open(zi, "w", force_zip64=True) as w: w.write(b"stored line\n" * 50)
        zi = zipfile.ZipInfo("df.txt"); zi.compress_type = zipfile.ZIP_DEFLATED
        with z.open(zi, "w", force_zip64=True) as w: w.write(b"deflated line\n" * 500)
    sys.exit(0)
elif kind == "zero_pad":
    # Synthetic stand-in for bsdtar's block padding: zeros after the end record.
    data = plain_zip([("c.txt", clean)]) + b"\0" * (10240 - len(plain_zip([("c.txt", clean)])) % 10240)
elif kind == "local_csize_only":
    # Deflated entry, only the local compressed size unset: APPNOTE 4.5.3 puts
    # BOTH sizes (uncompressed, compressed) in the 16-byte local zip64 extra.
    ex = struct.pack("<HHQQ", 1, 16, len(clean), len(ad))
    A = b"PK\x03\x04" + struct.pack("<HHHHHIIIHH", 45, 0, 8, 0, 0x21, crc(clean), 0xFFFFFFFF, len(clean), 5, len(ex)) + b"a.txt" + ex + ad
    data = finish(A, [cdent(b"a.txt", 8, 0, crc(clean), len(ad), len(clean), 0)])
elif kind == "cd_offset_ff":
    data = bytearray(plain_zip([("c.txt", clean)]))
    # The 32-bit offset is 0xFFFFFFFF and the zip64 extra carries 0xFF..FF: zipfile
    # then raises OverflowError (not BadZipFile) when it opens the member.
    cd = data.rfind(b"PK\x01\x02")
    nlen = struct.unpack("<H", data[cd + 28 : cd + 30])[0]
    ex = struct.pack("<HHQ", 1, 8, 2**64 - 1)
    data[cd + 30 : cd + 32] = struct.pack("<H", len(ex))
    data[cd + 42 : cd + 46] = b"\xff\xff\xff\xff"
    data[cd + 46 + nlen : cd + 46 + nlen] = ex
    eo = data.rfind(b"PK\x05\x06")
    data[eo + 12 : eo + 16] = struct.pack("<I", struct.unpack("<I", data[eo + 12 : eo + 16])[0] + len(ex))
    data = bytes(data)
elif kind == "z64_loc_in_comment":
    # Bug caught: a zip64 locator hidden in the last central-directory entry's
    # comment, 20 bytes before the 32-bit end record. zipfile and ditto ignore it
    # (no zip64 end record precedes it); bsdtar follows it into pad.bin's body,
    # to a second directory that lists a deflated .env.
    N = local(b"notes.txt", 0, 0, crc(clean), len(clean), len(clean), clean)
    pad = b"padding "
    body_start = len(N) + len(local(b"pad.bin", 0, 0, 0, 0, 0, b""))
    henv = local(b".env", 8, 0, crc(hid), len(hd), len(hid), hd)
    cd2 = cdent(b".env", 8, 0, crc(hid), len(hd), len(hid), body_start + len(pad))
    rec_in = body_start + len(pad) + len(henv) + len(cd2)
    rec = b"PK\x06\x06" + struct.pack("<QHHIIQQQQ", 44, 45, 45, 0, 0, 1, 1, len(cd2), body_start + len(pad) + len(henv))
    inner = pad + henv + cd2 + rec
    P = local(b"pad.bin", 0, 0, crc(inner), len(inner), len(inner), inner)
    cd_off = len(N) + len(P)
    loc = b"PK\x06\x07" + struct.pack("<IQI", 0, rec_in, 1)
    cd1a = cdent(b"notes.txt", 0, 0, crc(clean), len(clean), len(clean), 0)
    cd1b = bytearray(cdent(b"pad.bin", 0, 0, crc(inner), len(inner), len(inner), len(N)))
    cd1b[32:34] = struct.pack("<H", len(loc))
    cd1 = cd1a + bytes(cd1b) + loc
    data = N + P + cd1 + eocd(2, len(cd1), cd_off)
elif kind == "dir_data_zero":
    # Bug caught: a deflated directory entry whose stream inflates to bytes while
    # the directory claims file_size 0 (the walk, not the size check, must catch it).
    D = local(b"d/", 8, 0, crc(hid), len(hd), 0, hd)
    data = finish(D, [cdent(b"d/", 8, 0, crc(hid), len(hd), 0, 0)])
elif kind == "dir_deflated_empty":
    # Positive control: ZipFile.writestr("d/", b"") with ZIP_DEFLATED stores a
    # 2-byte empty deflate stream with file_size 0.
    b = io.BytesIO()
    with zipfile.ZipFile(b, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("d/", b"")
        z.writestr("d/c.txt", clean)
    data = b.getvalue()
elif kind == "backslash_name":
    # Bug caught: member names with backslashes; os.path.basename keeps
    # "cfg\\.env" whole on macOS, but unzip and bsdtar extract cfg/.env.
    data = plain_zip([("cfg\\.env", b"x=1\n")])
elif kind in ("comment_zip", "comment_local", "trailing_bytes", "sig_in_cd_name", "plain_comment"):
    inner = plain_zip([("s.txt", hid)])
    if kind == "comment_local":
        inner = H  # a bare local entry, no end record: only the first end record is real
    assert sent not in inner
    b = io.BytesIO()
    cm = inner if kind in ("comment_zip", "comment_local") else b"plain comment text\n"
    with zipfile.ZipFile(b, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("sig/PK\x03\x04.txt" if kind == "sig_in_cd_name" else "c.txt", clean)
        z.comment = cm
    data = b.getvalue()
    if kind == "trailing_bytes":
        data += b"\0\0\0\0 trailing"
else:
    raise SystemExit("unknown kind")
open(out, "wb").write(data)
PY

for K in csize_cover csize_cover_dd stored_cover method_mismatch; do
    start "zip $K: central directory lies about sizes/method so a hidden local entry is read by bsdtar/unzip but not zipfile (archive_unreadable)"
    new_case; python3 -I "$ROOT/mkzip.py" "$K" "$ART/$K.zip" "$SENT"; prepare --artifact "$ART/$K.zip"
    expect_fail "$K" "archive_unreadable"
done

for K in twoeocd z64_loc_off z64_disk z64_count dir_data dir_data_zero z64_loc_in_comment upath_local upath_cd upath_badcrc upath_badver; do
    case $K in
        twoeocd) T="zip64 end record and 32-bit end record point at different central directories (the second lists a hidden entry)" ;;
        z64_loc_off) T="zip64 locator record offset does not match where the zip64 end record is" ;;
        z64_disk) T="32-bit end record disk number disagrees with the zip64 record" ;;
        z64_count) T="32-bit end record entry count disagrees with the zip64 record" ;;
        dir_data_zero) T="deflated directory entry whose stream inflates to bytes while file_size claims 0" ;;
        z64_loc_in_comment) T="zip64 locator hidden in a central-directory entry comment, pointing at a second directory inside a stored member" ;;
        dir_data) T="directory entry that carries a deflated body (unzip -p prints it, zipfile skips it)" ;;
        upath_local) T="Unicode Path extra in the local header renames notes.txt to .env" ;;
        upath_cd) T="Unicode Path extra in the central directory renames notes.txt to .env" ;;
        upath_badcrc) T="Unicode Path extra whose CRC does not match the header filename" ;;
        upath_badver) T="Unicode Path extra with an unknown version" ;;
    esac
    start "$T [$K] (archive_unreadable)"
    new_case; python3 -I "$ROOT/mkzip.py" "$K" "$ART/$K.zip" "$SENT"; prepare --artifact "$ART/$K.zip"
    expect_fail "$K" "archive_unreadable"
done
start "positive controls: zip64 end record with all-marker 32-bit fields, with equal fields, and a Unicode Path extra that matches the filename stay clean"
new_case; prepare --artifact "$ART/none.bin" 2>/dev/null; printf 'x' > "$ART/none.bin"
for K in z64_marker z64_equal upath_ok; do
    python3 -I "$ROOT/mkzip.py" "$K" "$ART/$K.zip" "$SENT"; ctl_zip "$K" "$ART/$K.zip"
done

start "backslash in a member name: cfg\\.env is extracted as cfg/.env by unzip and bsdtar (forbidden_file)"
new_case; python3 -I "$ROOT/mkzip.py" backslash_name "$ART/bs.zip" "$SENT"; prepare --artifact "$ART/bs.zip"
expect_fail "backslash .env member" "forbidden_file"

start "dd_inflate_overrun: descriptor and directory agree on a clean 64-byte prefix but the deflate stream inflates to a token after it (archive_unreadable AND the token is found)"
new_case; python3 -I "$ROOT/mkzip.py" dd_inflate_overrun "$ART/ddo.zip" "$SENT"; prepare --artifact "$ART/ddo.zip"
expect_fail "dd overrun unreadable" "archive_unreadable"
expect_fail "dd overrun token" "secret_anthropic_key"

start "dd_wellformed: a deflated entry whose descriptor, directory and real stream all agree stays clean (no false positive)"
new_case; python3 -I "$ROOT/mkzip.py" dd_wellformed "$ART/ddw.zip" "$SENT"; prepare --artifact "$ART/ddw.zip"
run_audit
assert_eq "dd wellformed: exit 0" "$RC" 0
assert_not_contains "dd wellformed: no archive_unreadable" "$OUT" "archive_unreadable"

start "method_mismatch and csize_cover: the bytes the walk decodes are scanned (sentinel found, not just unreadable)"
new_case; python3 -I "$ROOT/mkzip.py" method_mismatch "$ART/mm.zip" "$SENT"; prepare --artifact "$ART/mm.zip"
expect_fail "method mismatch decoded" "sentinel"
new_case; python3 -I "$ROOT/mkzip.py" csize_cover "$ART/cc.zip" "$SENT"; prepare --artifact "$ART/cc.zip"
expect_fail "csize cover decoded" "sentinel"

start "zip after a prefix (shell script + zip, PNG + zip) is treated as a zip: archive_unreadable and members scanned"
new_case; python3 -I "$ROOT/mkzip.py" sfx_prefix "$ART/sfx.zip" "$SENT"; prepare --artifact "$ART/sfx.zip"
expect_fail "sfx prefix" "archive_unreadable"
new_case; python3 -I "$ROOT/mkzip.py" png_polyglot "$ART/poly.png" "$SENT"; prepare --artifact "$ART/poly.png"
expect_fail "png polyglot" "archive_unreadable"
assert_contains "png polyglot member scanned" "$OUT" "sentinel"

start "prefixed zip committed as a git blob is archive_unreadable too (blobs and artifacts share the path)"
new_case; python3 -I "$ROOT/mkzip.py" sfx_prefix "$REPO/tool.bin" "$SENT"; commit_all "sfx"; prepare
expect_fail "sfx blob" "archive_unreadable"

start "ordinary PNG without an end-of-central-directory record is not treated as a zip"
new_case; python3 -I "$ROOT/mkzip.py" png_clean "$ART/ok.png" "$SENT"; prepare --artifact "$ART/ok.png"
run_audit
assert_eq "clean png: exit 0" "$RC" 0

ctl_zip() { # label, file: audit a standard-tool zip as the only artifact
    rm -f "$RECEIPT"; make_manifest --artifact "$2"; make_review; run_audit
    assert_eq "$1: exit 0 (no false positive)" "$RC" 0
    assert_not_contains "$1: no archive_unreadable" "$OUT" "archive_unreadable"
}
start "positive controls: zip -r -, -0, -fd, -z comment, ditto (+ --sequesterRsrc), zip64 streaming writer"
new_case; mkdir -p "$CASE/zs/Fake.app/Contents"
for i in 1 2 3; do python3 -I -c 'import sys;print(("line %s\n" % sys.argv[1]) * 60, end="")' "$i" > "$CASE/zs/Fake.app/Contents/f$i.txt"; done
cp "$CASE/zs/Fake.app/Contents/f1.txt" "$CASE/zs/f0.txt"
prepare --artifact "$ART/none.bin" 2>/dev/null; printf 'x' > "$ART/none.bin"
(cd "$CASE/zs" && zip -q -r - Fake.app f0.txt > "$ART/stream.zip")
ctl_zip "zip -r - (streamed)" "$ART/stream.zip"
(cd "$CASE/zs" && zip -q -0 -r "$ART/store.zip" Fake.app f0.txt)
ctl_zip "zip -0" "$ART/store.zip"
(cd "$CASE/zs" && zip -q -fd -r "$ART/fd.zip" Fake.app f0.txt)
ctl_zip "zip -fd" "$ART/fd.zip"
(cd "$CASE/zs" && printf 'archive comment\n' | zip -q -z -r "$ART/cmt.zip" Fake.app f0.txt)
ctl_zip "zip -z comment" "$ART/cmt.zip"
ditto -c -k --keepParent "$CASE/zs/Fake.app" "$ART/d1.zip"; ctl_zip "ditto --keepParent" "$ART/d1.zip"
ditto -c -k --sequesterRsrc --keepParent "$CASE/zs/Fake.app" "$ART/d2.zip"; ctl_zip "ditto --sequesterRsrc" "$ART/d2.zip"
python3 -I "$ROOT/mkzip.py" zip64_stream "$ART/z64.zip" "$SENT"; ctl_zip "zip64 streaming writer" "$ART/z64.zip"

for K in local_csize_lie local_csize_small local_usize_lie zip64_local_lie zip64_csize_only comment_zip comment_local trailing_bytes; do
    case $K in
        zip64_local_lie) T="zip64 stored entry: local zip64 extra says a small size, directory covers a hidden deflated entry" ;;
        local_csize_lie) T="deflated entry whose local compressed size runs past its real stream into a hidden local entry (directory and data agree)" ;;
        local_csize_small) T="deflated entry whose local compressed size stops short of its real stream, so a hidden local entry inside the final block is read" ;;
        local_usize_lie) T="deflated entry whose local uncompressed size differs from the real inflated length (directory honest)" ;;
        zip64_csize_only) T="zip64 stored entry: local zip64 compressed size differs from the directory's" ;;
        comment_local) T="a bare deflated local entry inside the archive comment (an extractor taking the first end record reads it)" ;;
        comment_zip) T="a complete zip inside the archive comment: local entries after the central directory" ;;
        trailing_bytes) T="bytes after the end-of-central-directory comment" ;;
    esac
    start "$T [$K] (archive_unreadable)"
    new_case; python3 -I "$ROOT/mkzip.py" "$K" "$ART/$K.zip" "$SENT"; prepare --artifact "$ART/$K.zip"
    expect_fail "$K" "archive_unreadable"
done

start "bsdtar zero-pads a zip written to a non-seekable output to a 10240-byte block; valid archives must not be archive_unreadable"
new_case; mkdir -p "$CASE/zs"; python3 -I -c 'print("line\n" * 300, end="")' > "$CASE/zs/f.txt"
prepare --artifact "$ART/none.bin" 2>/dev/null; printf 'x' > "$ART/none.bin"
python3 -I "$ROOT/mkzip.py" zero_pad "$ART/pad.zip" "$SENT"; ctl_zip "synthetic zero padding" "$ART/pad.zip"
if (cd "$CASE/zs" && tar -cf - --format zip f.txt > "$ART/tarpad.zip" 2>/dev/null) && [ -s "$ART/tarpad.zip" ]; then
    ctl_zip "tar --format zip > file" "$ART/tarpad.zip"
    (cd "$CASE/zs" && tar -cf - --format zip f.txt | cat > "$ART/catpad.zip")
    ctl_zip "tar --format zip | cat" "$ART/catpad.zip"
else
    printf 'note: tar --format zip unavailable; only the synthetic padding control ran\n'
fi
start "non-zero bytes after the end record stay archive_unreadable even when a zero-padded zip is accepted"
new_case; python3 -I "$ROOT/mkzip.py" zero_pad "$ART/padbad.zip" "$SENT"; printf 'X' >> "$ART/padbad.zip"; prepare --artifact "$ART/padbad.zip"
expect_fail "padding then non-zero byte" "archive_unreadable"

start "only the local compressed size unset, 16-byte zip64 extra whose two readings differ: archive_unreadable (APPNOTE and libarchive would walk different entries)"
new_case; python3 -I "$ROOT/mkzip.py" local_csize_only "$ART/lcs.zip" "$SENT"; prepare --artifact "$ART/lcs.zip"
expect_fail "ambiguous local csize" "archive_unreadable"

start "stored entry whose ambiguous local zip64 csize hides a deflated entry that streaming bsdtar extracts"
new_case; python3 -I "$ROOT/mkzip.py" zip64_csize_ambiguous "$ART/amb.zip" "$SENT"; prepare --artifact "$ART/amb.zip"
expect_fail "ambiguous csize hides entry" "archive_unreadable"

start "corrupted central-directory header_offset is archive_unreadable, not an OverflowError traceback"
new_case; python3 -I "$ROOT/mkzip.py" cd_offset_ff "$ART/off.zip" "$SENT"; prepare --artifact "$ART/off.zip"
expect_fail "cd offset 0xFFFFFFFF" "archive_unreadable"
assert_not_contains "cd offset: no traceback" "$OUT" "Traceback"

start "walk budget: a scanner whose archive budget is nearly spent charges walk-decoded bytes to it (own 512 MiB walk budget ignored it)"
python3 -I - "$AUDIT" <<'PY'
import importlib.machinery, importlib.util, io, sys, zipfile
ld = importlib.machinery.SourceFileLoader("ap", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("ap", ld)); ld.exec_module(m)
b = io.BytesIO()
with zipfile.ZipFile(b, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("big.txt", b"a" * 200000)
def run(budget):
    f = m.Findings([]); s = m.Scanner(f, []); s.archive_budget = budget
    s.scan_blob(b.getvalue(), "x.zip", "x.zip")
    return {c for c, _ in f.items}, s.archive_budget
ample, left = run(10**7)
assert not ample, ample
assert left == 10**7 - 200000, left  # decoded once, charged once (member scan only)
tight, _ = run(100000)
assert "too_large" in tight, tight  # walk hits the scanner budget itself, before the member loop
PY
assert_eq "walk budget probe" "$?" 0

start "positive controls: real zip64 (stored + deflated, force_zip64), plain zip comment, PK local signature inside a directory name"
new_case; prepare --artifact "$ART/none.bin" 2>/dev/null; printf 'x' > "$ART/none.bin"
python3 -I "$ROOT/mkzip.py" zip64_real "$ART/real64.zip" "$SENT"; ctl_zip "real zip64" "$ART/real64.zip"
python3 -I "$ROOT/mkzip.py" plain_comment "$ART/pc.zip" "$SENT"; ctl_zip "plain comment" "$ART/pc.zip"
python3 -I "$ROOT/mkzip.py" sig_in_cd_name "$ART/sig.zip" "$SENT"; ctl_zip "signature in name" "$ART/sig.zip"
python3 -I "$ROOT/mkzip.py" dir_deflated_empty "$ART/dde.zip" "$SENT"; ctl_zip "deflated empty directory (zipfile writestr d/)" "$ART/dde.zip"

start "corrupt xz is archive_unreadable, not a LZMAError traceback"
new_case; printf '\3757zXZ\000garbage' > "$ART/bad.xz"; prepare --artifact "$ART/bad.xz"
run_audit
assert_eq "corrupt xz: exit 1" "$RC" 1
assert_contains "corrupt xz: archive_unreadable" "$OUT" "archive_unreadable"
assert_not_contains "corrupt xz: no traceback" "$OUT" "Traceback"

start "overlapping private patterns are redacted as one span (sequential sub leaked the remainder)"
new_case; P1="Ac""me"; P2="Ac""me Falcon Project"
printf 'about %s here\n' "$P2" > "$REPO/docs/$P2.md"; commit_all "overlap"
printf '%s\n%s\n' "$P1" "$P2" > "$CASE/pp.txt"; prepare --private-patterns "$CASE/pp.txt"
run_audit
assert_eq "overlap: exit 1" "$RC" 1
assert_contains "overlap: private_pattern reported" "$OUT" "private_pattern"
assert_not_contains "overlap: remainder not printed" "$OUT" "Falcon"
assert_not_contains "overlap: first pattern not printed" "$OUT" "$P1"

start "public blob renamed under x/Users/<name>/ is flagged (path scan ran after the published early return)"
new_case; mk_pub_ref
mkdir -p "$REPO/x$U$N_LOC"; git -C "$REPO" mv docs/app.py "$REPO/x$U$N_LOC/app.py"; commit_all "move"
prepare --published-base origin/main
run_audit
assert_eq "renamed public blob: exit 1" "$RC" 1
assert_contains "renamed public blob: home_path" "$OUT" "home_path"
assert_not_contains "renamed public blob: name not printed" "$OUT" "$N_LOC"

start "blob already audited under one path, seen again under x/Users/<name>/ in history, is flagged (audit_ref dedup skipped the path)"
new_case; mkdir -p "$REPO/x$U$N_LOC"; cp "$REPO/docs/app.py" "$REPO/x$U$N_LOC/app.py"
commit_all "copy under home path"; prepare
run_audit
assert_eq "dedup path: exit 1" "$RC" 1
assert_contains "dedup path: home_path" "$OUT" "home_path"

start "INT and TERM traps clean up and exit 130 / 143 (trap used to swallow the signal and keep running)"
for SIGNAME in INT TERM; do
    TRAP_OUT=$(TRAP_PROBE=$SIGNAME sh "$0" 2>&1); TRAP_RC=$?
    case $SIGNAME in INT) WANT=130 ;; TERM) WANT=143 ;; esac
    assert_eq "$SIGNAME: exit status" "$TRAP_RC" "$WANT"
    assert_not_contains "$SIGNAME: did not continue past the signal" "$TRAP_OUT" "PROBE_CONTINUED"
    assert_absent "$SIGNAME: temp root removed" "$(printf '%s\n' "$TRAP_OUT" | sed -n 's/^PROBE_ROOT=//p')"
done

printf '\n== publication audit tests: %s passed, %s failed ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
