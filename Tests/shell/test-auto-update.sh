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
    # Prints a pid like the real thing, so the "only quit what we launched" logic
    # is actually exercised rather than comparing two empty strings.
    cat > "$SHIM/pgrep" << 'PGREP'
#!/bin/bash
if [ -f "$FAKE_RUNNING_MARKER" ]; then
    PID="$(cat "$FAKE_RUNNING_MARKER" 2>/dev/null)"
    [ -n "$PID" ] || PID=4242
    echo "$PID"
    exit 0
fi
exit 1
PGREP
    printf '#!/bin/bash\nrm -f "$FAKE_RUNNING_MARKER"\nexit 0\n' > "$SHIM/pkill"

    # open: launching succeeds only when FAKE_LAUNCH_OK=1, letting us simulate a
    # build that installs fine but crashes on startup.
    cat > "$SHIM/open" << 'OPEN'
#!/bin/bash
if [ "${FAKE_LAUNCH_OK:-1}" = "1" ]; then echo "${FAKE_LAUNCH_PID:-4242}" > "$FAKE_RUNNING_MARKER"; else rm -f "$FAKE_RUNNING_MARKER"; fi
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

    # mv: real, but can pause immediately after the backup move — that is the one
    # window where the install path holds nothing, and the only way to test that a
    # signal arriving then still leaves a launchable app behind.
    cat > "$SHIM/mv" << 'MVSHIM'
#!/bin/bash
/bin/mv "$@"
RC=$?
if [ "${PAUSE_AFTER_BACKUP:-0}" = "1" ]; then
    case "$*" in
        *backups*) touch "$PAUSE_MARKER"; sleep 5 ;;
    esac
fi
# Pause just after the staged bundle is swaped into place, i.e. installed but
# not yet verified.
if [ "${PAUSE_AFTER_SWAP:-0}" = "1" ]; then
    case "$*" in
        *.app.new.*) touch "$PAUSE_MARKER"; sleep 5 ;;
    esac
fi
exit $RC
MVSHIM

    # git: real, except `fetch` can be made to hang so the timeout branch is
    # reachable. Everything else must behave exactly like git.
    REAL_GIT="$(command -v git)"
    cat > "$SHIM/git" << GITSHIM
#!/bin/bash
if [ "\$1" = "fetch" ] && [ "\${HANG_FETCH:-0}" = "1" ]; then sleep 60; exit 0; fi
exec "$REAL_GIT" "\$@"
GITSHIM

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

# Steady state: the updater has recorded which commit the installed bundle came
# from. Without this an install is "unknown provenance" and rebuilding is correct.
seed_installed_sha() {
    mkdir -p "$STATE"
    git -C "$PROJECT" rev-parse "${1:-origin/main}" > "$STATE/installed-sha"
}

# The staged bundle is pid-suffixed, so any assertion on a fixed name is vacuous.
staged_bundle_count() {
    ls -1d "$INSTALL"/.PortPilot.app.new* 2>/dev/null | wc -l | tr -d ' '
}

installed_version_of() {
    local plist="$INSTALL/PortPilot.app/Contents/Info.plist"
    [ -f "$plist" ] || { echo "none"; return; }
    plutil -extract CFBundleShortVersionString raw -o - "$plist" 2>/dev/null || echo "unknown"
}

# Runs the real script against the sandbox. Extra env comes in as VAR=VAL args.
run_updater() {
    # Order-independent: env pairs and flags may be interleaved. Breaking at the
    # first flag silently dropped any env var that followed it, which made tests
    # pass for the wrong reason.
    local env_pairs=() arg
    for arg in "$@"; do
        case "$arg" in
            *=*) env_pairs+=("$arg") ;;
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
    seed_installed_sha
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
    assert_eq "no staged bundle left behind" "$(staged_bundle_count)" "0"
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
    assert_eq "no staged bundle left behind" "$(staged_bundle_count)" "0"
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

# Unpushed commits are unreviewed local work. Installing them unattended is the
# same hazard as installing a dirty tree, so it must refuse outright — and it must
# refuse without reinstalling anything on every firing.
test_unpushed_commits_are_refused() {
    start "unpushed commits on main are refused, not installed"
    setup
    install_app_version 0.4.0
    seed_installed_sha
    printf '// local work\n' >> "$PROJECT/Sources/Main.swift"
    git -C "$PROJECT" commit -qam "unpushed local commit"

    run_updater
    assert_eq "exits 0" "$STATUS" "0"
    assert_contains "refuses unreviewed local work" "$OUTPUT" "unpushed commit"
    assert_eq "install untouched" "$(installed_version_of)" "0.4.0"
    assert_eq "nothing was reinstalled" \
        "$(ls -1 "$STATE/backups" 2>/dev/null | wc -l | tr -d ' ')" "0"

    # --force is the documented override, and it installs what is checked out.
    run_updater --force
    assert_eq "--force exits 0" "$STATUS" "0"
    assert_eq "--force records the local commit as installed" \
        "$(cat "$STATE/installed-sha")" "$(git -C "$PROJECT" rev-parse HEAD)"
    teardown
}

# The memo must key on the commit that actually gets built. Upstream commits are
# the normal case: after the fast-forward the installed commit is origin's tip, so
# the next run's target must equal what the memo recorded.
test_memo_key_matches_target_after_fast_forward() {
    start "failed-launch memo blocks the commit it fast-forwarded to"
    setup
    install_app_version 0.0.1
    seed_installed_sha
    printf '// upstream work\n' >> "$PROJECT/Sources/Main.swift"
    git -C "$PROJECT" commit -qam "upstream commit"
    git -C "$PROJECT" push -q origin main
    git -C "$PROJECT" reset -q --hard HEAD~1       # local is now genuinely behind
    touch "$ROOT/app-running"

    run_updater FAKE_LAUNCH_OK=0
    assert_eq "first run exits non-zero" "$STATUS" "1"
    assert_eq "rolled back" "$(installed_version_of)" "0.0.1"
    assert_eq "memo records origin's tip" \
        "$(sed -n 1p "$STATE/last-failed-launch")" "$(git -C "$PROJECT" rev-parse origin/main)"

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
    seed_installed_sha
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

# A staged bundle orphaned by a killed run must be swept once the lock is held,
# or /Applications slowly fills with .PortPilot.app.new.<pid> litter.
test_orphan_staged_bundle_is_swept() {
    start "an orphaned staged bundle is cleared"
    setup
    install_app_version 0.0.1
    mkdir -p "$INSTALL/.PortPilot.app.new.99999/Contents"
    run_updater
    assert_eq "exits 0" "$STATUS" "0"
    assert_contains "logged the sweep" "$OUTPUT" "cleared orphaned staged bundle"
    assert_eq "no staged bundles remain" "$(staged_bundle_count)" "0"
    teardown
}

# If the restored backup is itself incomplete, the updater must clear it rather
# than leave a bundle that looks healthy but cannot run.
test_incomplete_restore_is_cleared() {
    start "an incomplete rollback clears the install rather than leaving it broken"
    setup
    install_app_version 0.0.1
    chmod -x "$INSTALL/PortPilot.app/Contents/MacOS/PortPilot"   # backup will be unusable
    touch "$ROOT/app-running"
    run_updater FAKE_LAUNCH_OK=0
    assert_eq "exits non-zero" "$STATUS" "1"
    assert_contains "reports the incomplete restore" "$OUTPUT" "restored bundle is incomplete"
    assert_absent "no broken app left installed" "$INSTALL/PortPilot.app"
    assert_contains "user was notified of the failure" \
        "$(cat "$ROOT/notifications" 2>/dev/null || echo)" "rollback FAILED"
    teardown
}

# A timeout must kill the whole process group, not just the direct child — an
# orphaned swift build keeps the SwiftPM lock and blocks the next run.
test_timeout_kills_grandchildren() {
    start "a timeout kills the child's whole process group"
    setup
    install_app_version 0.0.1
    cat > "$SHIM/swift" << 'HANGER'
#!/bin/bash
sleep 60 &
echo $! > "$GRANDCHILD_PID_FILE"
wait
HANGER
    chmod +x "$SHIM/swift"
    run_updater PORTPILOT_TEST_TIMEOUT=1 GRANDCHILD_PID_FILE="$ROOT/grandchild"
    assert_eq "exits non-zero" "$STATUS" "1"
    GC="$(cat "$ROOT/grandchild" 2>/dev/null || echo)"
    if [ -n "$GC" ] && kill -0 "$GC" 2>/dev/null; then
        bad "grandchild $GC survived the timeout"
        kill -9 "$GC" 2>/dev/null || true
    else
        ok "grandchild was killed with its process group"
    fi
    teardown
}

# A hung fetch must be distinguishable from being offline, or a stalled updater
# looks like normal offline behaviour forever.
test_hung_fetch_is_reported_distinctly() {
    start "a hung fetch is reported as a timeout, not as being offline"
    setup
    install_app_version 0.0.1
    run_updater HANG_FETCH=1 PORTPILOT_FETCH_TIMEOUT=1
    assert_eq "exits 0 (skip)" "$STATUS" "0"
    assert_contains "names the timeout" "$OUTPUT" "git fetch timed out"
    assert_contains "user was notified" \
        "$(cat "$ROOT/notifications" 2>/dev/null || echo)" "timed out"
    teardown
}

# With no install to fall back on, retrying a crash-on-launch build must be
# bounded — otherwise it rebuilds every 6 hours forever.
test_repair_retries_are_bounded() {
    start "repair attempts on a non-launching build are bounded"
    setup
    # No app installed at all, so the memo cannot suppress the repair attempt.
    SHA="$(git -C "$PROJECT" rev-parse origin/main)"
    printf '%s\n3\nfailed earlier\n' "$SHA" > "$STATE/last-failed-launch"
    run_updater FAKE_LAUNCH_OK=0
    assert_eq "exits 0 (gave up)" "$STATUS" "0"
    assert_contains "explains it gave up" "$OUTPUT" "giving up until a newer commit"
    teardown
}

# A --force build over a dirty tree must not blacklist the commit: the crash came
# from uncommitted code, not from what is committed.
test_dirty_force_failure_does_not_blacklist() {
    start "a dirty --force build that fails to launch does not blacklist the commit"
    setup
    install_app_version 0.0.1
    printf '// local edit\n' >> "$PROJECT/Sources/Main.swift"
    touch "$ROOT/app-running"
    run_updater --force FAKE_LAUNCH_OK=0
    assert_eq "exits non-zero" "$STATUS" "1"
    assert_contains "says why it is not recording" "$OUTPUT" "included uncommitted changes"
    assert_absent "no memo written" "$STATE/last-failed-launch"
    teardown
}

# A live lock holder must be respected; a dead one must be cleared.
test_dead_lock_holder_is_cleared() {
    start "a lock left by a dead process is cleared"
    setup
    install_app_version 0.0.1
    mkdir -p "$SANDBOX_TMP/portpilot-auto-update.lock"
    # A pid that is certain not to be running.
    printf '999999\n' > "$SANDBOX_TMP/portpilot-auto-update.lock/pid"
    run_updater
    assert_eq "exits 0" "$STATUS" "0"
    assert_contains "reports clearing the stale lock" "$OUTPUT" "holder pid 999999 is gone"
    assert_eq "update proceeded" "$(installed_version_of)" "0.4.0"
    teardown
}

test_live_lock_holder_is_respected() {
    start "a lock held by a live process is respected"
    setup
    install_app_version 0.0.1
    mkdir -p "$SANDBOX_TMP/portpilot-auto-update.lock"
    printf '%s\n' "$$" > "$SANDBOX_TMP/portpilot-auto-update.lock/pid"   # this test runner
    run_updater
    assert_eq "exits 0" "$STATUS" "0"
    assert_contains "names the holder" "$OUTPUT" "in progress (pid $$)"
    assert_eq "install untouched" "$(installed_version_of)" "0.0.1"
    teardown
}

# Zero must be rejected like any other invalid interval, not busy-loop.
test_zero_poll_falls_back() {
    start "a zero poll interval falls back instead of busy-looping"
    setup
    install_app_version 0.4.0
    seed_installed_sha
    run_updater PORTPILOT_POLL_SECS=0
    assert_eq "exits 0" "$STATUS" "0"
    assert_contains "completed its decision" "$OUTPUT" "already up to date"
    teardown
}

# The hole codex found: a fast-forward advances the clone before the build runs,
# so if the new commit leaves VERSION untouched and the build fails, versions
# match on the next run and the new code would never be installed.
test_advanced_clone_without_install_still_updates() {
    start "a commit whose build never installed is still installed later"
    setup
    install_app_version 0.4.0
    # Provenance points at an older commit while VERSION is unchanged at 0.4.0,
    # exactly the state left behind by an advanced clone with a failed build.
    OLD_SHA="$(git -C "$PROJECT" rev-parse HEAD)"
    printf '// upstream change that does not touch VERSION\n' >> "$PROJECT/Sources/Main.swift"
    git -C "$PROJECT" commit -qam "upstream change"
    git -C "$PROJECT" push -q origin main
    printf '%s\n' "$OLD_SHA" > "$STATE/installed-sha"

    run_updater
    assert_eq "exits 0" "$STATUS" "0"
    assert_contains "cites the stale installed build" "$OUTPUT" "installed build is from"
    assert_eq "records the new commit as installed" \
        "$(cat "$STATE/installed-sha")" "$(git -C "$PROJECT" rev-parse HEAD)"
    teardown
}

# An install the updater has never seen has unknown provenance; rebuilding once
# is the safe interpretation.
test_unknown_provenance_triggers_update() {
    start "an install of unknown provenance is rebuilt once"
    setup
    install_app_version 0.4.0          # no seed_installed_sha
    run_updater
    assert_eq "exits 0" "$STATUS" "0"
    assert_contains "says provenance is unknown" "$OUTPUT" "an unknown commit"
    assert_exists "provenance recorded afterwards" "$STATE/installed-sha"
    teardown
}

# A --force build over a dirty tree must not claim a commit is installed.
test_dirty_build_clears_provenance() {
    start "a dirty --force build does not claim a commit is installed"
    setup
    install_app_version 0.0.1
    seed_installed_sha
    printf '// local edit\n' >> "$PROJECT/Sources/Main.swift"
    run_updater --force
    assert_eq "exits 0" "$STATUS" "0"
    assert_absent "provenance record dropped" "$STATE/installed-sha"
    teardown
}

# This repo's workflow is worktree-based, where .git is a file, not a directory.
test_linked_worktree_is_accepted() {
    start "a linked git worktree is accepted as a valid checkout"
    setup
    install_app_version 0.0.1
    # Detached: `main` is already checked out in the primary clone. The point of
    # this test is only that a worktree is not rejected as "not a repository";
    # the branch guard is covered separately.
    git -C "$PROJECT" worktree add -q --detach "$ROOT/wt" main >/dev/null 2>&1
    assert_exists "worktree .git is a file" "$ROOT/wt/.git"
    OUTPUT="$(env PATH="$SHIM:$PATH" TMPDIR="$SANDBOX_TMP" HOME="$ROOT/home" \
        PORTPILOT_PROJECT_DIR="$ROOT/wt" PORTPILOT_INSTALL_ROOT="$INSTALL" \
        PORTPILOT_STATE_DIR="$STATE" PORTPILOT_LOG_DIR="$LOGS" \
        PORTPILOT_POLL_SECS=1 PORTPILOT_LAUNCH_SETTLE_SECS=1 \
        FAKE_RUNNING_MARKER="$ROOT/app-running" NOTIFY_LOG="$ROOT/notifications" \
        bash "$REAL_SCRIPT" --dry-run 2>&1)"
    STATUS=$?
    assert_eq "exits 0" "$STATUS" "0"
    case "$OUTPUT" in
        *"not a git working tree"*) bad "worktree was rejected" ;;
        *) ok "worktree was not rejected" ;;
    esac
    teardown
}

# The core guarantee: a signal must never leave /Applications without an app. The
# dangerous window is between moving the old bundle aside and swapping in the new.
test_signal_mid_install_restores_the_app() {
    start "a signal during the install window still leaves an app installed"
    setup
    install_app_version 0.0.1
    seed_installed_sha

    env PATH="$SHIM:$PATH" TMPDIR="$SANDBOX_TMP" HOME="$ROOT/home" \
        PORTPILOT_PROJECT_DIR="$PROJECT" PORTPILOT_INSTALL_ROOT="$INSTALL" \
        PORTPILOT_STATE_DIR="$STATE" PORTPILOT_LOG_DIR="$LOGS" \
        PORTPILOT_POLL_SECS=1 PORTPILOT_LAUNCH_SETTLE_SECS=1 \
        FAKE_RUNNING_MARKER="$ROOT/app-running" NOTIFY_LOG="$ROOT/notifications" \
        PAUSE_AFTER_BACKUP=1 PAUSE_MARKER="$ROOT/paused" \
        bash "$REAL_SCRIPT" >/dev/null 2>&1 &
    UPDATER_PID=$!

    # Wait until it is inside the window (old bundle moved aside, nothing installed).
    WAITED=0
    while [ ! -f "$ROOT/paused" ] && [ "$WAITED" -lt 40 ]; do sleep 1; WAITED=$((WAITED + 1)); done
    if [ -f "$ROOT/paused" ]; then
        ok "reached the mid-install window"
        assert_absent "install path is empty inside the window" "$INSTALL/PortPilot.app"
        kill -TERM "$UPDATER_PID" 2>/dev/null || true
        wait "$UPDATER_PID" 2>/dev/null || true
        assert_eq "app restored after the signal" "$(installed_version_of)" "0.0.1"
        assert_eq "no staged bundle left behind" "$(staged_bundle_count)" "0"
    else
        bad "never reached the mid-install window"
        kill -TERM "$UPDATER_PID" 2>/dev/null || true
    fi
    teardown
}

# An interruption after the swap leaves a bundle that was never confirmed to
# start. The previous, known-good app is the safer state to return to.
test_signal_after_swap_restores_previous_version() {
    start "a signal after the swap but before verification restores the old version"
    setup
    install_app_version 0.0.1
    seed_installed_sha

    env PATH="$SHIM:$PATH" TMPDIR="$SANDBOX_TMP" HOME="$ROOT/home" \
        PORTPILOT_PROJECT_DIR="$PROJECT" PORTPILOT_INSTALL_ROOT="$INSTALL" \
        PORTPILOT_STATE_DIR="$STATE" PORTPILOT_LOG_DIR="$LOGS" \
        PORTPILOT_POLL_SECS=1 PORTPILOT_LAUNCH_SETTLE_SECS=1 \
        FAKE_RUNNING_MARKER="$ROOT/app-running" NOTIFY_LOG="$ROOT/notifications" \
        PAUSE_AFTER_SWAP=1 PAUSE_MARKER="$ROOT/paused" \
        bash "$REAL_SCRIPT" >/dev/null 2>&1 &
    UPDATER_PID=$!

    WAITED=0
    while [ ! -f "$ROOT/paused" ] && [ "$WAITED" -lt 40 ]; do sleep 1; WAITED=$((WAITED + 1)); done
    if [ -f "$ROOT/paused" ]; then
        ok "reached the post-swap window"
        kill -TERM "$UPDATER_PID" 2>/dev/null || true
        wait "$UPDATER_PID" 2>/dev/null || true
        assert_eq "previous version restored" "$(installed_version_of)" "0.0.1"
        assert_eq "no staged bundle left behind" "$(staged_bundle_count)" "0"
    else
        bad "never reached the post-swap window"
        kill -TERM "$UPDATER_PID" 2>/dev/null || true
    fi
    teardown
}

# The updater builds in a live clone, so the tree can move mid-build. Installing
# then would ship mixed state while recording TARGET_SHA as its provenance.
test_tree_moving_mid_build_aborts() {
    start "a commit landing mid-build discards that build"
    setup
    install_app_version 0.0.1
    seed_installed_sha
    # `swift test` is where we simulate the developer committing mid-run.
    cat > "$SHIM/swift" << 'MOVER'
#!/bin/bash
if [ "$1" = "test" ]; then
    printf '// landed mid-build
' >> "$PORTPILOT_PROJECT_DIR/Sources/Main.swift"
    git -C "$PORTPILOT_PROJECT_DIR" commit -qam "mid-build commit"
fi
exit 0
MOVER
    chmod +x "$SHIM/swift"
    run_updater
    assert_eq "exits non-zero" "$STATUS" "1"
    assert_contains "reports HEAD moving" "$OUTPUT" "while building"
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
test_memo_key_matches_target_after_fast_forward
test_memo_never_blocks_a_repair
test_memo_never_blocks_a_fresh_install
test_memo_cleared_after_success
test_unpushed_commits_are_refused
test_timeout_aborts_without_touching_install
test_non_integer_poll_falls_back
test_zero_poll_falls_back
test_orphan_staged_bundle_is_swept
test_incomplete_restore_is_cleared
test_timeout_kills_grandchildren
test_hung_fetch_is_reported_distinctly
test_repair_retries_are_bounded
test_dirty_force_failure_does_not_blacklist
test_advanced_clone_without_install_still_updates
test_unknown_provenance_triggers_update
test_dirty_build_clears_provenance
test_linked_worktree_is_accepted
test_signal_mid_install_restores_the_app
test_signal_after_swap_restores_previous_version
test_tree_moving_mid_build_aborts
test_dead_lock_holder_is_cleared
test_live_lock_holder_is_respected
test_lock_prevents_concurrent_run
test_feature_branch_skip
test_dry_run_mutates_nothing
test_test_failure_aborts_install

# A test that is defined but never called silently "passes". That happened twice
# while writing this suite, so make it a failure instead of a quiet no-op.
UNCALLED=""
for fn in $(grep -o '^test_[a-z0-9_]*() {' "$0" | sed 's/() {//'); do
    grep -q "^$fn\$" "$0" || UNCALLED="$UNCALLED $fn"
done
if [ -n "$UNCALLED" ]; then
    printf '\n✘ defined but never run:%s\n' "$UNCALLED"
    FAIL=$((FAIL + 1))
fi

printf '\n────────────────────────────\n'
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
