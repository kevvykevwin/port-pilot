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
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/swift"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$SIGN_LOG"\n' > "$SANDBOX/bin/codesign"
chmod +x "$SANDBOX/bin/"*
SIGN_LOG="$SANDBOX/signing" PATH="$SANDBOX/bin:$PATH" "$SANDBOX/project/scripts/build-app.sh" > "$SANDBOX/build.log"
APP="$SANDBOX/project/build/PortPilot.app"
test -x "$APP/Contents/MacOS/PortPilot"
test -x "$APP/Contents/Helpers/PortPilotHelper"
test -x "$APP/Contents/Resources/bin/portpilot"
test -f "$APP/Contents/Resources/bin/managed-helper.py"
cmp "$PROJECT/VERSION" "$APP/Contents/Resources/VERSION"
test "$(wc -l < "$SANDBOX/signing" | tr -d ' ')" = 3
test ! -e "$SANDBOX/project/Library/LaunchAgents"
printf 'PASS: GUI, helper and CLI packaged separately; shared VERSION; nested signing; no installation\n'
