#!/bin/bash
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/../.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/project/scripts" "$SANDBOX/project/Assets" "$SANDBOX/project/.build/release" "$SANDBOX/bin"
cp "$PROJECT/scripts/build-app.sh" "$SANDBOX/project/scripts/"
cp "$PROJECT/scripts/managed-helper.py" "$SANDBOX/project/scripts/"
cp "$PROJECT/VERSION" "$SANDBOX/project/"
printf '<svg/>\n' > "$SANDBOX/project/Assets/icon.svg"
for binary in PortPilot PortPilotHelper PortPilotCLI; do
    printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/project/.build/release/$binary"
    chmod +x "$SANDBOX/project/.build/release/$binary"
done
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$SWIFT_LOG"\nexit 0\n' > "$SANDBOX/bin/swift"
# Records whether COMMIT already existed at each signing call: a file added after signing is not covered by the signature.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$SIGN_LOG"\nif [ -f "$COMMIT_FILE" ]; then echo present >> "$SIGN_LOG.commit"; else echo missing >> "$SIGN_LOG.commit"; fi\n' > "$SANDBOX/bin/codesign"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$STRIP_LOG"\n' > "$SANDBOX/bin/strip"
chmod +x "$SANDBOX/bin/"*
# A real git checkout, so the build can stamp the commit it was built from.
git -C "$SANDBOX/project" init -q
git -C "$SANDBOX/project" -c user.email=t@example.com -c user.name=T add -A
git -C "$SANDBOX/project" -c user.email=t@example.com -c user.name=T commit -qm init
EXPECTED_COMMIT="$(git -C "$SANDBOX/project" rev-parse HEAD)"
export COMMIT_FILE="$SANDBOX/project/build/PortPilot.app/Contents/Resources/COMMIT"
SWIFT_LOG="$SANDBOX/swift-args" STRIP_LOG="$SANDBOX/strip-args" SIGN_LOG="$SANDBOX/signing" PATH="$SANDBOX/bin:$PATH" "$SANDBOX/project/scripts/build-app.sh" > "$SANDBOX/build.log"
APP="$SANDBOX/project/build/PortPilot.app"
test -x "$APP/Contents/MacOS/PortPilot"
test -x "$APP/Contents/Helpers/PortPilotHelper"
test -x "$APP/Contents/Resources/bin/portpilot"
test -f "$APP/Contents/Resources/bin/managed-helper.py"
cmp "$PROJECT/VERSION" "$APP/Contents/Resources/VERSION"
test "$(wc -l < "$SANDBOX/signing" | tr -d ' ')" = 3
test ! -e "$SANDBOX/project/Library/LaunchAgents"
# Bug caught: release binaries embedding the builder's absolute source paths (home directory and
# username) in debug/assert metadata, which the publication audit flags in shipped artifacts.
grep -q -- "-debug-prefix-map -Xswiftc $SANDBOX/project=/portpilot" "$SANDBOX/swift-args"
grep -q -- "-file-prefix-map -Xswiftc $SANDBOX/project=/portpilot" "$SANDBOX/swift-args"
# Debug-symbol stabs still name the build directory, so every shipped binary is stripped before signing.
test "$(grep -c '^-S ' "$SANDBOX/strip-args")" = 3
# Bug caught: the updater could not tell which commit an installed bundle came from, so a code-only
# fix with an unchanged VERSION looked "already installed". The bundle records its commit, before signing.
test "$(cat "$APP/Contents/Resources/COMMIT")" = "$EXPECTED_COMMIT"
test "$(grep -c '^present$' "$SANDBOX/signing.commit")" = 3
# Bug caught: a dirty build claiming to be a clean commit would equal the updater's target and hide a real update.
printf '// local edit\n' >> "$SANDBOX/project/scripts/managed-helper.py"
SWIFT_LOG="$SANDBOX/swift-args2" STRIP_LOG="$SANDBOX/strip-args2" SIGN_LOG="$SANDBOX/signing2" PATH="$SANDBOX/bin:$PATH" "$SANDBOX/project/scripts/build-app.sh" > "$SANDBOX/build2.log"
test "$(cat "$APP/Contents/Resources/COMMIT")" = "$EXPECTED_COMMIT-dirty"
# Bug caught: no git must not fail the build; the bundle then simply has no COMMIT (updater falls back).
mv "$SANDBOX/project/.git" "$SANDBOX/git-away"
SWIFT_LOG="$SANDBOX/swift-args3" STRIP_LOG="$SANDBOX/strip-args3" SIGN_LOG="$SANDBOX/signing3" PATH="$SANDBOX/bin:$PATH" "$SANDBOX/project/scripts/build-app.sh" > "$SANDBOX/build3.log"
test ! -e "$APP/Contents/Resources/COMMIT"
printf 'PASS: GUI, helper and CLI packaged separately; shared VERSION; nested signing; no installation; source paths remapped; commit stamped before signing\n'
