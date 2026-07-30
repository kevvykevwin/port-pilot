#!/bin/bash
#
# Tests for scripts/auto-update.sh — the unattended installer.
#
# Swift tests cannot cover this: it quits apps, swaps bundles in /Applications,
# and rolls back. So each case builds a throwaway sandbox (temp git repo + temp
# "Applications" dir) and shims the system commands the script calls, letting us
# inject failures that are impossible to trigger on demand for real.
#
# Run: ./Tests/shell/test-auto-update.sh
#
set -uo pipefail

REAL_SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/scripts/auto-update.sh"
[ -x "$REAL_SCRIPT" ] || { echo "cannot find scripts/auto-update.sh" >&2; exit 1; }

PASS=0
FAIL=0
CURRENT_TEST=""

start() { CURRENT_TEST="$1"; printf '\n── %s\n' "$1"; }
ok()    { PASS=$((PASS + 1)); printf '   ✔ %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf '   ✘ %s\n' "$1"; }

assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi
}
assert_contains() {
    case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (output missing '$3')" ;; esac
}
assert_absent() {
    if [ ! -e "$2" ]; then ok "$1"; else bad "$1 ($2 exists but should not)"; fi
}
assert_exists() {
    if [ -e "$2" ]; then ok "$1"; else bad "$1 ($2 is missing)"; fi
}

# --------------------------------------------------------------------- sandbox
# ROOT/repo        — git clone under test (main, with an origin it can fetch)
# ROOT/origin.git  — bare origin
# ROOT/Applications— stands in for /Applications
# ROOT/shim        — fake swift/ditto/pgrep/open/osascript, prepended to PATH
setup() {
    ROOT="$(mktemp -d)"
    PROJECT="$ROOT/repo"
    ORIGIN="$ROOT/origin.git"
    INSTALL="$ROOT/Applications"
    STATE="$ROOT/state"
    LOGS="$ROOT/logs"
    SHIM="$ROOT/shim"
    SANDBOX_TMP="$ROOT/tmp"
    mkdir -p "$PROJECT/scripts" "$PROJECT/Sources" "$INSTALL" "$STATE" "$LOGS" "$SHIM" "$SANDBOX_TMP"

    printf 'VERSION=0.4.0\nBUILD=3\n' > "$PROJECT/VERSION"
    printf '// placeholder\n' > "$PROJECT/Sources/Main.swift"

    # Stands in for the real build-app.sh: emits a structurally valid bundle
    # without invoking Swift, so tests stay fast and hermetic.
    cat > "$PROJECT/scripts/build-app.sh" << 'FAKE_BUILD'
#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$DIR/build/PortPilot.app"
V="$(sed -n 's/^VERSION=//p' "$DIR/VERSION" | head -1)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
printf '#!/bin/bash\nsleep 100\n' > "$APP/Contents/MacOS/PortPilot"
chmod +x "$APP/Contents/MacOS/PortPilot"
cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>PortPilot</string>
    <key>CFBundleShortVersionString</key><string>$V</string>
    <key>CFBundleVersion</key><string>3</string>
</dict>
</plist>
PLIST
FAKE_BUILD
    chmod +x "$PROJECT/scripts/build-app.sh"

    make_shims

    git init -q "$PROJECT"
    git -C "$PROJECT" config user.email test@example.com
    git -C "$PROJECT" config user.name "Test"
    git -C "$PROJECT" symbolic-ref HEAD refs/heads/main
    git -C "$PROJECT" add -A
    git -C "$PROJECT" commit -qm "initial"
    git init -q --bare "$ORIGIN"
    git -C "$PROJECT" remote add origin "$ORIGIN"
    git -C "$PROJECT" push -q origin main
    git -C "$PROJECT" branch -q --set-upstream-to=origin/main main 2>/dev/null || true
}

teardown() { [ -n "${ROOT:-}" ] && rm -rf "$ROOT"; return 0; }
# An early exit or Ctrl-C would otherwise leak a mktemp tree containing a fake .app.
trap 'teardown' EXIT INT TERM

make_shims() {
    # swift: always succeeds; the real toolchain is never invoked.
    printf '#!/bin/bash\nexit 0\n' > "$SHIM/swift"

    # ditto: real copy by default. FAIL_DITTO=1 fails outright; PARTIAL_DITTO=1
    # writes only Info.plist and reports success, mimicking an interrupted copy.
    cat > "$SHIM/ditto" << 'DITTO'
#!/bin/bash
[ "${FAIL_DITTO:-0}" = "1" ] && exit 1
if [ "${PARTIAL_DITTO:-0}" = "1" ]; then
    DEST="${2:-}"
    mkdir -p "$DEST/Contents"
    cp "$1/Contents/Info.plist" "$DEST/Contents/Info.plist" 2>/dev/null || true
    exit 0
fi
exec /usr/bin/ditto "$@"
DITTO

    # pgrep/pkill: app "runs" while the marker file exists.
    cat > "$SHIM/pgrep" << 'PGREP'
#!/bin/bash
[ -f "$FAKE_RUNNING_MARKER" ] && exit 0
exit 1
PGREP
    printf '#!/bin/bash\nrm -f "$FAKE_RUNNING_MARKER"\nexit 0\n' > "$SHIM/pkill"

    # open: launching succeeds only when FAKE_LAUNCH_OK=1, letting us simulate a
    # build that installs fine but crashes on startup.
    cat > "$SHIM/open" << 'OPEN'
#!/bin/bash
if [ "${FAKE_LAUNCH_OK:-1}" = "1" ]; then touch "$FAKE_RUNNING_MARKER"; else rm -f "$FAKE_RUNNING_MARKER"; fi
exit 0
OPEN

    # osascript: "quit app" stops the fake app; notifications are recorded.
    cat > "$SHIM/osascript" << 'OSA'
#!/bin/bash
case "$*" in
    *"quit app"*)             rm -f "$FAKE_RUNNING_MARKER" ;;
    *"display notification"*) printf '%s\n' "$*" >> "$NOTIFY_LOG" ;;
esac
exit 0
OSA

    chmod +x "$SHIM"/*
}

# Installs a fake already-present app at the given version.
install_app_version() {
    local ver="$1" app="$INSTALL/PortPilot.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS"
    printf '#!/bin/bash\nsleep 100\n' > "$app/Contents/MacOS/PortPilot"
    chmod +x "$app/Contents/MacOS/PortPilot"
    cat > "$app/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>PortPilot</string>
    <key>CFBundleShortVersionString</key><string>$ver</string>
    <key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
PLIST
}

installed_version_of() {
    local plist="$INSTALL/PortPilot.app/Contents/Info.plist"
    [ -f "$plist" ] || { echo "none"; return; }
    plutil -extract CFBundleShortVersionString raw -o - "$plist" 2>/dev/null || echo "unknown"
}

# Runs the real script against the sandbox. Extra env comes in as VAR=VAL args.
run_updater() {
    local env_pairs=() arg
    for arg in "$@"; do
        case "$arg" in
            *=*) env_pairs+=("$arg") ;;
            *)   break ;;
        esac
    done
    local script_args=()
    for arg in "$@"; do
        case "$arg" in *=*) ;; *) script_args+=("$arg") ;; esac
    done

    OUTPUT="$(env \
        PATH="$SHIM:$PATH" \
        TMPDIR="$SANDBOX_TMP" \
        HOME="$ROOT/home" \
        PORTPILOT_PROJECT_DIR="$PROJECT" \
        PORTPILOT_INSTALL_ROOT="$INSTALL" \
        PORTPILOT_STATE_DIR="$STATE" \
        PORTPILOT_LOG_DIR="$LOGS" \
        PORTPILOT_POLL_SECS=1 \
        PORTPILOT_LAUNCH_SETTLE_SECS=1 \
        FAKE_RUNNING_MARKER="$ROOT/app-running" \
        NOTIFY_LOG="$ROOT/notifications" \
        ${env_pairs[@]+"${env_pairs[@]}"} \
        bash "$REAL_SCRIPT" ${script_args[@]+"${script_args[@]}"} 2>&1)"
    STATUS=$?
    return 0
}

# ----------------------------------------------------------------------- tests

# An idle run must be cheap and silent — this is 99% of the 6-hourly firings.
test_up_to_date() {
    start "idle run with a current install does nothing"
    setup
    install_app_version 0.4.0
    run_updater
    assert_eq "exits 0" "$STATUS" "0"
    assert_contains "reports up to date" "$OUTPUT" "already up to date"
    teardown
}

# Guards the user's work in progress: never install unreviewed local edits.
test_dirty_sources_skip() {
    start "tracked modification under Sources/ blocks the update"
    setup
    install_app_version 0.0.1
    printf '// local edit\n' >> "$PROJECT/Sources/Main.swift"
    run_updater
    assert_eq "exits 0 (skip, not failure)" "$STATUS" "0"
    assert_contains "explains why" "$OUTPUT" "uncommitted changes in build inputs"
    assert_eq "install untouched" "$(installed_version_of)" "0.0.1"
    teardown
}

# ...but an untracked scratch file outside the build inputs must NOT block it,
# or the updater deadlocks on things like plans/ or editor droppings.
test_untracked_scratch_does_not_block() {
    start "untracked file outside build inputs does not block the update"
    setup
    install_app_version 0.0.1
    mkdir -p "$PROJECT/plans"
    printf 'scratch\n' > "$PROJECT/plans/notes.md"
    printf 'scratch\n' > "$PROJECT/stray.txt"
    run_updater
    assert_eq "exits 0" "$STATUS" "0"
    assert_eq "update proceeded" "$(installed_version_of)" "0.4.0"
    teardown
}

# An untracked file under Sources/ IS compiled by SwiftPM, so it must block —
# otherwise the log claims it installed origin/main while shipping local code.
test_untracked_source_blocks() {
    start "untracked file under Sources/ blocks the update"
    setup
    install_app_version 0.0.1
    printf '// sneaky\n' > "$PROJECT/Sources/Extra.swift"
    run_updater
    assert_eq "exits 0 (skip)" "$STATUS" "0"
    assert_contains "names the untracked file" "$OUTPUT" "would be compiled"
    assert_eq "install untouched" "$(installed_version_of)" "0.0.1"
    teardown
}

# Regression: a successful first install with an empty backup dir used to abort
# the prune pipeline under `set -euo pipefail` and exit 1 despite succeeding.
test_fresh_install_exits_zero() {
    start "first install with no prior backups exits 0"
    setup
    run_updater
    assert_eq "exits 0" "$STATUS" "0"
    assert_eq "app installed" "$(installed_version_of)" "0.4.0"
    assert_contains "logged the update" "$OUTPUT" "updated"
    teardown
}

# Staging failure must abort before the live app is disturbed at all.
test_staging_failure_leaves_install_intact() {
    start "copy failure leaves the existing install untouched"
    setup
    install_app_version 0.0.1
    run_updater FAIL_DITTO=1
    assert_eq "exits non-zero" "$STATUS" "1"
    assert_eq "old version still installed" "$(installed_version_of)" "0.0.1"
    assert_absent "no staged bundle left behind" "$INSTALL/.PortPilot.app.new"
    teardown
}

# C1 regression. A partial copy must never land at the install path: a bundle
# with only Info.plist reports the NEW version, so the next run would call a
# broken install healthy and never repair it.
test_partial_copy_never_reaches_install_path() {
    start "partial copy never lands at the install path (C1)"
    setup
    run_updater PARTIAL_DITTO=1
    assert_eq "exits non-zero" "$STATUS" "1"
    assert_absent "no partial bundle installed" "$INSTALL/PortPilot.app"
    assert_absent "no staged bundle left behind" "$INSTALL/.PortPilot.app.new"
    teardown
}

# C1 regression, second half: if a broken bundle IS somehow present, the updater
# must see it as broken and repair it rather than trusting the plist.
test_broken_install_is_repaired() {
    start "an executable-less bundle is detected as broken and replaced (C1)"
    setup
    mkdir -p "$INSTALL/PortPilot.app/Contents"
    cat > "$INSTALL/PortPilot.app/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict><key>CFBundleShortVersionString</key><string>0.4.0</string></dict>
</plist>
PLIST
    run_updater
    assert_eq "exits 0" "$STATUS" "0"
    assert_contains "recognised as broken" "$OUTPUT" "installed broken"
    assert_exists "executable restored" "$INSTALL/PortPilot.app/Contents/MacOS/PortPilot"
    teardown
}

# C2 regression. A build that passes tests but crashes on launch must roll back,
# AND be remembered — otherwise every firing re-quits the user's app forever.
test_launch_failure_rolls_back_and_is_remembered() {
    start "a build that will not launch rolls back and is not retried (C2)"
    setup
    install_app_version 0.0.1
    touch "$ROOT/app-running"          # app is currently running

    run_updater FAKE_LAUNCH_OK=0
    assert_eq "exits non-zero" "$STATUS" "1"
    assert_eq "rolled back to previous version" "$(installed_version_of)" "0.0.1"
    assert_exists "failure memo written" "$STATE/last-failed-launch"
    assert_contains "user was notified" "$(cat "$ROOT/notifications" 2>/dev/null || echo)" "Rolled back"

    # The critical half: the very next firing must leave the app alone.
    run_updater FAKE_LAUNCH_OK=0
    assert_eq "second run exits 0" "$STATUS" "0"
    assert_contains "second run skips the known-bad commit" "$OUTPUT" "already failed to launch"
    assert_eq "still on the working version" "$(installed_version_of)" "0.0.1"
    teardown
}

# The memo must actually block, and --force must actually override it. Writing a
# bogus SHA here would make both halves pass vacuously, since a SHA that matches
# nothing never blocks anything.
test_memo_blocks_and_force_overrides() {
    start "the memo blocks the target commit, and --force overrides it"
    setup
    install_app_version 0.0.1
    git -C "$PROJECT" rev-parse origin/main > "$STATE/last-failed-launch"

    run_updater
    assert_eq "without --force: exits 0" "$STATUS" "0"
    assert_contains "without --force: skips the blacklisted commit" "$OUTPUT" "already failed to launch"
    assert_eq "without --force: install untouched" "$(installed_version_of)" "0.0.1"

    run_updater --force
    assert_eq "with --force: exits 0" "$STATUS" "0"
    assert_eq "with --force: update applied" "$(installed_version_of)" "0.4.0"
    teardown
}

# An unpushed local commit must not be treated as a reason to reinstall. Treating
# it as one rebuilt and swapped the bundle on every firing, forever.
test_local_ahead_does_not_trigger_update() {
    start "local main ahead of origin does not trigger a reinstall"
    setup
    install_app_version 0.4.0
    printf '// local work\n' >> "$PROJECT/Sources/Main.swift"
    git -C "$PROJECT" commit -qam "unpushed local commit"

    run_updater
    assert_eq "exits 0" "$STATUS" "0"
    assert_contains "reports up to date" "$OUTPUT" "already up to date"
    assert_eq "no backup was taken (nothing was reinstalled)" \
        "$(ls -1 "$STATE/backups" 2>/dev/null | wc -l | tr -d ' ')" "0"
    teardown
}

# The memo is keyed on the commit that would be installed. When local main is
# ahead of origin that is NOT origin's tip, and keying on the wrong one made the
# blacklist silently never match — the flap survived.
test_memo_key_matches_target_when_local_ahead() {
    start "failed-launch memo still blocks when local main is ahead of origin"
    setup
    install_app_version 0.0.1
    printf '// local work\n' >> "$PROJECT/Sources/Main.swift"
    git -C "$PROJECT" commit -qam "unpushed local commit"
    touch "$ROOT/app-running"

    run_updater FAKE_LAUNCH_OK=0
    assert_eq "first run exits non-zero" "$STATUS" "1"
    assert_eq "rolled back" "$(installed_version_of)" "0.0.1"

    run_updater FAKE_LAUNCH_OK=0
    assert_eq "second run exits 0" "$STATUS" "0"
    assert_contains "second run skips the known-bad commit" "$OUTPUT" "already failed to launch"
    teardown
}

# The memo must suppress upgrades only. Letting it suppress repairs left the user
# with no app and an agent that declined to fix it on every firing.
test_memo_never_blocks_a_repair() {
    start "the memo does not block repairing a broken install"
    setup
    git -C "$PROJECT" rev-parse origin/main > "$STATE/last-failed-launch"
    mkdir -p "$INSTALL/PortPilot.app/Contents"
    cat > "$INSTALL/PortPilot.app/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict><key>CFBundleShortVersionString</key><string>0.4.0</string></dict>
</plist>
PLIST
    run_updater
    assert_eq "exits 0" "$STATUS" "0"
    assert_exists "broken install was repaired" "$INSTALL/PortPilot.app/Contents/MacOS/PortPilot"
    teardown
}

# Same, for a missing install: a memo must never mean "refuse to install at all".
test_memo_never_blocks_a_fresh_install() {
    start "the memo does not block a fresh install"
    setup
    git -C "$PROJECT" rev-parse origin/main > "$STATE/last-failed-launch"
    run_updater
    assert_eq "exits 0" "$STATUS" "0"
    assert_eq "app installed" "$(installed_version_of)" "0.4.0"
    teardown
}

# A successful launch must clear the memo, or the next genuine update is blocked.
test_memo_cleared_after_success() {
    start "a successful update clears the failure memo"
    setup
    install_app_version 0.0.1
    touch "$ROOT/app-running"
    run_updater FAKE_LAUNCH_OK=0
    assert_exists "memo written by the failed run" "$STATE/last-failed-launch"
    run_updater --force FAKE_LAUNCH_OK=1
    assert_eq "recovery run exits 0" "$STATUS" "0"
    assert_absent "memo cleared" "$STATE/last-failed-launch"
    teardown
}

# Launch verification must not be conditional on the app having been running —
# otherwise a crash-on-launch build installs silently whenever the user quit it.
test_launch_verified_even_when_app_not_running() {
    start "a non-launching build rolls back even if the app was not running"
    setup
    install_app_version 0.0.1
    rm -f "$ROOT/app-running"          # app is NOT running
    run_updater FAKE_LAUNCH_OK=0
    assert_eq "exits non-zero" "$STATUS" "1"
    assert_eq "rolled back rather than silently installed" "$(installed_version_of)" "0.0.1"
    assert_exists "failure memo written" "$STATE/last-failed-launch"
    teardown
}

# A hung child must be killed and the install left alone, not hang the agent.
test_timeout_aborts_without_touching_install() {
    start "a hung build times out and leaves the install alone"
    setup
    install_app_version 0.0.1
    printf '#!/bin/bash\nsleep 60\n' > "$SHIM/swift"
    chmod +x "$SHIM/swift"
    run_updater PORTPILOT_TEST_TIMEOUT=1
    assert_eq "exits non-zero" "$STATUS" "1"
    assert_contains "reports the timeout" "$OUTPUT" "timed out"
    assert_eq "install untouched" "$(installed_version_of)" "0.0.1"
    teardown
}

# A garbage interval must not silently disable the timeout machinery.
test_non_integer_poll_falls_back() {
    start "a non-integer poll interval falls back instead of spinning forever"
    setup
    install_app_version 0.4.0
    run_updater PORTPILOT_POLL_SECS=0.5
    assert_eq "exits 0" "$STATUS" "0"
    assert_contains "still completed its decision" "$OUTPUT" "already up to date"
    teardown
}

# A second concurrent firing must not run the install twice.
test_lock_prevents_concurrent_run() {
    start "an existing lock makes the run skip"
    setup
    install_app_version 0.0.1
    mkdir -p "$SANDBOX_TMP/portpilot-auto-update.lock"
    run_updater
    assert_eq "exits 0" "$STATUS" "0"
    assert_contains "reports the lock" "$OUTPUT" "another auto-update run is in progress"
    assert_eq "install untouched" "$(installed_version_of)" "0.0.1"
    teardown
}

# Feature-branch work must never be built and shipped to /Applications.
test_feature_branch_skip() {
    start "running on a feature branch skips"
    setup
    install_app_version 0.0.1
    git -C "$PROJECT" checkout -q -b feat/wip
    run_updater
    assert_eq "exits 0" "$STATUS" "0"
    assert_contains "names the branch" "$OUTPUT" "not 'main'"
    teardown
}

# --dry-run must decide out loud and change nothing.
test_dry_run_mutates_nothing() {
    start "--dry-run reports without installing"
    setup
    install_app_version 0.0.1
    run_updater --dry-run
    assert_eq "exits 0" "$STATUS" "0"
    assert_contains "says what it would do" "$OUTPUT" "DRY RUN"
    assert_eq "install untouched" "$(installed_version_of)" "0.0.1"
    teardown
}

# A tests failure must abort before anything is uninstalled.
test_test_failure_aborts_install() {
    start "failing tests abort before touching the install"
    setup
    install_app_version 0.0.1
    printf '#!/bin/bash\n[ "$1" = "test" ] && exit 1\nexit 0\n' > "$SHIM/swift"
    chmod +x "$SHIM/swift"
    run_updater
    assert_eq "exits non-zero" "$STATUS" "1"
    assert_contains "reports the test failure" "$OUTPUT" "tests failed"
    assert_eq "install untouched" "$(installed_version_of)" "0.0.1"
    teardown
}

# ------------------------------------------------------------------------ main
test_up_to_date
test_dirty_sources_skip
test_untracked_scratch_does_not_block
test_untracked_source_blocks
test_fresh_install_exits_zero
test_staging_failure_leaves_install_intact
test_partial_copy_never_reaches_install_path
test_broken_install_is_repaired
test_launch_failure_rolls_back_and_is_remembered
test_launch_verified_even_when_app_not_running
test_memo_blocks_and_force_overrides
test_memo_key_matches_target_when_local_ahead
test_memo_never_blocks_a_repair
test_memo_never_blocks_a_fresh_install
test_memo_cleared_after_success
test_local_ahead_does_not_trigger_update
test_timeout_aborts_without_touching_install
test_non_integer_poll_falls_back
test_lock_prevents_concurrent_run
test_feature_branch_skip
test_dry_run_mutates_nothing
test_test_failure_aborts_install

printf '\n────────────────────────────\n'
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
