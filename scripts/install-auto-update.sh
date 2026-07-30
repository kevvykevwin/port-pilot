#!/bin/bash
#
# Installs (or removes) the launchd agent that runs scripts/auto-update.sh.
#
# Checks every 6 hours and once at login. The updater itself decides whether
# there's anything to do, so a firing is cheap when nothing has changed.
#
# Usage:
#   ./scripts/install-auto-update.sh            # install + load
#   ./scripts/install-auto-update.sh --uninstall
#   ./scripts/install-auto-update.sh --status
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.portpilot.autoupdate"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
INTERVAL_SECONDS=21600   # 6 hours
LOG_DIR="$HOME/Library/Logs/PortPilot"

case "${1:-install}" in
    --status)
        if launchctl list | grep -q "$LABEL"; then
            echo "loaded:"
            launchctl list "$LABEL" | grep -E 'LastExitStatus|PID|Label' || true
        else
            echo "not loaded"
        fi
        echo "plist: $PLIST"
        echo "log:   $LOG_DIR/auto-update.log"
        # The plist bakes in an absolute path, so moving or deleting the clone
        # leaves an agent that fails every 6h with nothing reporting it.
        if [ -f "$PLIST" ]; then
            RECORDED="$(sed -n 's|.*<string>\(/.*/auto-update\.sh\)</string>.*|\1|p' "$PLIST" | head -1)"
            if [ -n "$RECORDED" ] && [ ! -x "$RECORDED" ]; then
                echo "WARNING: the agent points at $RECORDED, which no longer exists." >&2
                echo "         Re-run this script from the current clone, or --uninstall." >&2
                exit 1
            fi
            [ -n "$RECORDED" ] && echo "script: $RECORDED (present)"
        fi
        exit 0
        ;;
    --uninstall)
        launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
        rm -f "$PLIST"
        echo "auto-update agent removed"
        exit 0
        ;;
    install) ;;
    *) echo "unknown argument: $1 (try --status or --uninstall)" >&2; exit 2 ;;
esac

mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"

# launchd gives an agent a minimal PATH, so swift/git must be resolvable.
cat > "$PLIST" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$PROJECT_DIR/scripts/auto-update.sh</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin</string>
    </dict>
    <key>StartInterval</key>
    <integer>$INTERVAL_SECONDS</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/auto-update.launchd.err</string>
</dict>
</plist>
PLIST_EOF

# bootout first so a re-run reloads cleanly instead of erroring on a live label.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST"

echo "auto-update agent installed: checks every $((INTERVAL_SECONDS / 3600))h and at login"
echo "  plist:  $PLIST"
echo "  log:    $LOG_DIR/auto-update.log"
echo "  status: ./scripts/install-auto-update.sh --status"
echo "  remove: ./scripts/install-auto-update.sh --uninstall"
