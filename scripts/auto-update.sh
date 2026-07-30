#!/bin/bash
#
# Port Pilot auto-updater.
#
# Rebuilds from origin/main and reinstalls to /Applications when either
#   (a) new commits have landed upstream, or
#   (b) the installed bundle is missing, broken, or behind the VERSION file.
#
# Designed to run unattended from launchd, so every failure path must leave a
# launchable app installed. See scripts/install-auto-update.sh.
#
# Usage:
#   ./scripts/auto-update.sh              # normal run
#   ./scripts/auto-update.sh --dry-run    # report what it would do; builds and
#                                         # installs nothing, but does still fetch
#                                         # from origin and append to the log
#   ./scripts/auto-update.sh --force      # rebuild+reinstall even if nothing changed
#
set -euo pipefail

PROJECT_DIR="${PORTPILOT_PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
APP_NAME="PortPilot"
INSTALL_ROOT="${PORTPILOT_INSTALL_ROOT:-/Applications}"
INSTALLED_APP="$INSTALL_ROOT/$APP_NAME.app"
STAGED_APP="$INSTALL_ROOT/.$APP_NAME.app.new.$$"
BUILT_APP="$PROJECT_DIR/build/$APP_NAME.app"
BRANCH="main"

LOG_DIR="${PORTPILOT_LOG_DIR:-$HOME/Library/Logs/PortPilot}"
LOG_FILE="$LOG_DIR/auto-update.log"
LOG_MAX_BYTES=$((2 * 1024 * 1024))
# Application Support, not Caches: Caches is purgeable under disk pressure, and
# between the swap steps below the backup is the only copy of a working app.
STATE_DIR="${PORTPILOT_STATE_DIR:-$HOME/Library/Application Support/PortPilot}"
BACKUP_DIR="$STATE_DIR/backups"
FAILED_LAUNCH_MEMO="$STATE_DIR/last-failed-launch"
# Which commit the installed bundle was actually built from. Version equality is
# not a proxy for this: a fast-forward advances the clone before the build runs,
# so a commit that leaves VERSION untouched and then fails to build would look
# "already up to date" forever while the old bundle stayed installed.
INSTALLED_SHA_FILE="$STATE_DIR/installed-sha"
# UID-scoped: without TMPDIR every account would share /tmp/portpilot-auto-update.lock,
# where one user's run suppresses another's and a stale lock owned by someone else
# cannot be cleared.
LOCK_DIR="${TMPDIR:-/tmp}/portpilot-auto-update-$(id -u).lock"
LOCK_MAX_AGE_MIN=60
KEEP_BACKUPS=3
# How many times to retry a commit that installs but will not launch, when there
# is no working install to fall back to. Prevents an unbounded rebuild loop.
MAX_LAUNCH_ATTEMPTS=3

# Unattended means no tty: git must never wait on a credential or host prompt,
# or the job hangs forever and launchd will not fire the agent again.
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=10}"

FETCH_TIMEOUT_SECS="${PORTPILOT_FETCH_TIMEOUT:-120}"
BUILD_TIMEOUT_SECS="${PORTPILOT_BUILD_TIMEOUT:-900}"
TEST_TIMEOUT_SECS="${PORTPILOT_TEST_TIMEOUT:-600}"
# Poll/settle intervals, overridable so the test harness isn't dominated by sleeps.
POLL_SECS="${PORTPILOT_POLL_SECS:-2}"
LAUNCH_SETTLE_SECS="${PORTPILOT_LAUNCH_SETTLE_SECS:-8}"

# These feed shell arithmetic and `[ -ge ]`, so a non-integer or zero would make
# run_bounded's counter never advance — the timeout would never fire and the loop
# would spin forever holding the lock. Force every one back to a sane integer.
require_positive_int() {
    case "$2" in
        ''|*[!0-9]*|0) echo "$3" ;;
        *) echo "$2" ;;
    esac
}
POLL_SECS="$(require_positive_int POLL_SECS "$POLL_SECS" 2)"
LAUNCH_SETTLE_SECS="$(require_positive_int LAUNCH_SETTLE_SECS "$LAUNCH_SETTLE_SECS" 8)"
FETCH_TIMEOUT_SECS="$(require_positive_int FETCH_TIMEOUT_SECS "$FETCH_TIMEOUT_SECS" 120)"
BUILD_TIMEOUT_SECS="$(require_positive_int BUILD_TIMEOUT_SECS "$BUILD_TIMEOUT_SECS" 900)"
TEST_TIMEOUT_SECS="$(require_positive_int TEST_TIMEOUT_SECS "$TEST_TIMEOUT_SECS" 600)"

DRY_RUN=false
FORCE=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --force)   FORCE=true ;;
        -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
    esac
done

mkdir -p "$LOG_DIR" "$BACKUP_DIR"

# Keep the log from growing without bound across years of 6-hourly runs.
if [ -f "$LOG_FILE" ]; then
    LOG_BYTES="$(wc -c < "$LOG_FILE" | tr -d ' ')"
    if [ "${LOG_BYTES:-0}" -gt "$LOG_MAX_BYTES" ]; then
        mv "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
    fi
fi

log() {
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') $*"
    printf '%s\n' "$line" >> "$LOG_FILE"
    printf '%s\n' "$line"
    return 0
}

# The bad outcomes here are invisible otherwise: launchd stdout goes to
# /dev/null and nobody watches a log file. Surface them on the desktop.
notify() {
    osascript -e "display notification \"$1\" with title \"Port Pilot update\"" >/dev/null 2>&1 || true
}

# Match only the installed bundle's executable. A name-only match also catches a
# development build from `swift run PortPilot`, which quit_app would then pkill
# and launch verification would mistake for the newly installed app.
app_pids() {
    pgrep -f "$INSTALLED_APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true
}
app_running() {
    [ -n "$(app_pids)" ]
}

INSTALL_PHASE_STARTED=false
# Set once this run has committed to updating. A build or test failure happens
# before the install phase but still needs to be visible: launchd discards stdout,
# so otherwise a bad upstream commit stalls updates with the reason buried in a log.
UPDATE_STARTED=false
die() {
    log "ERROR: $*"
    if [ "$INSTALL_PHASE_STARTED" = true ] || [ "$UPDATE_STARTED" = true ]; then
        notify "Update failed: $*"
    fi
    exit 1
}
skip() { log "SKIP:  $*"; exit 0; }

# Bounded child execution. macOS ships no coreutils `timeout`, and an unbounded
# `git fetch`/`swift build` that hangs holds the lock and stops the agent for good.
run_bounded() {
    local secs="$1"; shift
    # Own process group, so a timeout can signal the whole tree. Killing just the
    # direct child would orphan `swift build`, which keeps the SwiftPM lock and
    # blocks the next run's `swift test` until that one times out too.
    set -m
    "$@" &
    local pid=$! waited=0
    set +m
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$secs" ]; then
            pkill -P "$pid" 2>/dev/null || true
            kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
            sleep 2
            kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            return 124
        fi
        sleep "$POLL_SECS"
        waited=$((waited + POLL_SECS))
    done
    wait "$pid"
}

# ---------------------------------------------------------------- concurrency
# Claims a stale lock by renaming it aside. mv onto a non-existent source fails,
# so of two racers exactly one succeeds and the other backs off.
take_stale_lock() {
    local aside="$LOCK_DIR.stale.$$"
    mv "$LOCK_DIR" "$aside" 2>/dev/null || return 1
    log "clearing stale lock ($1)"
    rm -rf "$aside" 2>/dev/null || true
    return 0
}

# Liveness beats an age heuristic: a worst-case run (fetch + test + build) can
# legitimately exceed any fixed timeout, and stealing its lock lets a second run
# swap the same bundle underneath it.
if [ -d "$LOCK_DIR" ]; then
    LOCK_PID="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [ -n "$LOCK_PID" ]; then
        if kill -0 "$LOCK_PID" 2>/dev/null; then
            skip "another auto-update run is in progress (pid $LOCK_PID)"
        fi
        # Two runs can both observe the same dead holder. Deleting and recreating
        # would let the second delete the first's freshly acquired lock and both
        # proceed. Claim it by rename instead: that is atomic, so exactly one wins
        # and the loser finds nothing to move.
        take_stale_lock "holder pid $LOCK_PID is gone" || skip "another auto-update run claimed the stale lock first"
    elif [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +$LOCK_MAX_AGE_MIN 2>/dev/null)" ]; then
        take_stale_lock "no holder recorded, older than ${LOCK_MAX_AGE_MIN}m" || skip "another auto-update run claimed the stale lock first"
    else
        skip "another auto-update run is in progress"
    fi
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    skip "another auto-update run is in progress"
fi
printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
# TERM/HUP matter: launchd signals agents at logout, and bash does not run an
# EXIT trap for a default-action signal. Without these the lock outlives the run
# and a staged bundle is left behind mid-install.
cleanup() {
    # Anything between moving the old bundle aside and a VERIFIED launch is an
    # incomplete install: the path may hold nothing, or hold a bundle that was
    # never confirmed to start. Either way the previous app is the safer state, so
    # a signal arriving in that span puts it back.
    if [ "${LAUNCH_VERIFIED:-false}" != true ]; then
        # BACKUP_PATH is only assigned once the backup validates, but a signal can
        # land in the gap between the move completing and that assignment — bash
        # defers the trap until the running command returns. So fall back to the
        # in-flight candidate, and only if it too proves complete: an unvalidated
        # copy must never displace whatever is currently installed.
        RESTORE_SRC=""
        if [ -n "${BACKUP_PATH:-}" ] && [ -d "${BACKUP_PATH:-}" ]; then
            RESTORE_SRC="${BACKUP_PATH}"
        elif [ ! -d "$INSTALLED_APP" ] && [ -n "${CANDIDATE_BACKUP:-}" ] \
             && [ -x "${CANDIDATE_BACKUP}/Contents/MacOS/$APP_NAME" ]; then
            # Last resort only: an in-flight candidate has not been fully validated
            # (a cross-volume copy interrupted after the executable but before the
            # rest still looks executable), so it may only fill an empty install
            # path — never displace a bundle that is still there.
            RESTORE_SRC="${CANDIDATE_BACKUP}"
        fi
        if [ -n "$RESTORE_SRC" ]; then
            # An instance we started only to verify must not outlive its bundle.
            if [ -n "${LAUNCHED_PID:-}" ]; then
                kill -TERM "${LAUNCHED_PID}" 2>/dev/null || true
            fi
            rm -rf "$INSTALLED_APP" 2>/dev/null || true
            if mv "$RESTORE_SRC" "$INSTALLED_APP" 2>/dev/null; then
                log "interrupted before the new version was verified; restored v${INST_VERSION:-previous}"
                # Leave the user as we found them: if their app was running when
                # we started, it should be running again now.
                if [ "${WAS_RUNNING:-false}" = true ]; then
                    open "$INSTALLED_APP" >/dev/null 2>&1 || true
                fi
            fi
        fi
    fi
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    rm -rf "$STAGED_APP" 2>/dev/null || true
}
# Both are referenced by cleanup before the install phase sets them, and the traps
# can fire at any point, so they must always be defined under `set -u`.
BACKUP_PATH=""
CANDIDATE_BACKUP=""
LAUNCH_VERIFIED=false
WAS_RUNNING=false
LAUNCHED_PID=""
# cleanup alone is not enough for a signal: replacing bash's default termination
# behaviour without exiting would let the run continue past the point where its
# lock and staged bundle have already been removed, while launchd is free to
# start another. Signals clean up and then die; EXIT stays for normal paths.
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

# We hold the lock now, so any staged bundle still lying around belongs to a run
# that was killed before its trap fired. Clear them before staging our own.
if [ "$DRY_RUN" = false ]; then
    for orphan in "$INSTALL_ROOT/.$APP_NAME.app.new"*; do
        [ -e "$orphan" ] || continue
        [ "$orphan" = "$STAGED_APP" ] && continue
        rm -rf "$orphan" 2>/dev/null && log "cleared orphaned staged bundle $(basename "$orphan")"
    done
fi

# ------------------------------------------------------------------ preflight
command -v git   >/dev/null 2>&1 || die "git not found on PATH"
command -v swift >/dev/null 2>&1 || die "swift toolchain not found on PATH (Xcode / CLT missing?)"
# `.git` is a FILE in a linked worktree, and this repo's workflow is worktree-based.
git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "$PROJECT_DIR is not a git working tree"
[ -x "$PROJECT_DIR/scripts/build-app.sh" ] || die "scripts/build-app.sh missing or not executable"
[ -f "$PROJECT_DIR/VERSION" ] || die "VERSION file missing — cannot determine target version"

cd "$PROJECT_DIR"

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$CURRENT_BRANCH" = "$BRANCH" ] || skip "on branch '$CURRENT_BRANCH', not '$BRANCH' — leaving feature work alone"

# Tracked modifications to anything that ends up in the bundle. Untracked files
# are ignored here (they can't block a fast-forward and would otherwise deadlock
# the updater on scratch files) — but see the scoped untracked check below, since
# SwiftPM globs its target directories and would compile an untracked source file.
DIRTY_INPUTS="$(git status --porcelain --untracked-files=no -- Sources Tests Assets Package.swift Package.resolved VERSION scripts 2>/dev/null || true)"
UNTRACKED_SOURCES="$(git ls-files --others --exclude-standard -- Sources Tests Assets 2>/dev/null || true)"
DIRTY_BUILD=false
{ [ -n "$DIRTY_INPUTS" ] || [ -n "$UNTRACKED_SOURCES" ]; } && DIRTY_BUILD=true
if [ "$FORCE" = false ] && [ "$DIRTY_BUILD" = true ]; then
    [ -n "$DIRTY_INPUTS" ] && { log "dirty build inputs:"; log "$DIRTY_INPUTS"; }
    [ -n "$UNTRACKED_SOURCES" ] && { log "untracked files that would be compiled:"; log "$UNTRACKED_SOURCES"; }
    skip "uncommitted changes in build inputs — refusing to install an unreviewed build (use --force to override)"
fi

# --------------------------------------------------------------- what changed
FETCH_RC=0
run_bounded "$FETCH_TIMEOUT_SECS" git fetch --quiet origin "$BRANCH" 2>/dev/null || FETCH_RC=$?
if [ "$FETCH_RC" -eq 124 ]; then
    # Not the same as being offline: something is hanging (a credential helper
    # GIT_TERMINAL_PROMPT can't suppress, a black-holed connection). Say so,
    # or it looks like normal offline behaviour forever.
    notify "git fetch timed out after ${FETCH_TIMEOUT_SECS}s — updates are stalled."
    skip "git fetch timed out after ${FETCH_TIMEOUT_SECS}s (hung transport or credential prompt)"
elif [ "$FETCH_RC" -ne 0 ]; then
    skip "git fetch failed (offline, or no access to origin)"
fi

LOCAL_SHA="$(git rev-parse HEAD)"
REMOTE_SHA="$(git rev-parse "origin/$BRANCH")"

source_version() {
    # Parsed, not sourced: three scripts read this file, and a stray `exit` or
    # `set -x` in a sourced file would break all of them.
    sed -n 's/^[[:space:]]*VERSION=//p' "$PROJECT_DIR/VERSION" | head -1 | tr -d '"'"'"' \t\r'
}

installed_version() {
    # A bundle holding only Info.plist (interrupted copy) still reports a valid
    # version, which would make the updater declare a broken install healthy and
    # never repair it. Require the executable before trusting the plist.
    [ -d "$INSTALLED_APP" ] || { echo "none"; return; }
    [ -x "$INSTALLED_APP/Contents/MacOS/$APP_NAME" ] || { echo "broken"; return; }
    # plutil reads the file directly; `defaults` goes through cfprefsd and can
    # return a cached value for a path that was just replaced.
    plutil -extract CFBundleShortVersionString raw -o - "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null || echo "unknown"
}

SRC_VERSION="$(source_version)"
[ -n "$SRC_VERSION" ] || die "could not parse VERSION= from $PROJECT_DIR/VERSION"
INST_VERSION="$(installed_version)"

BEHIND=0
AHEAD=0
if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
    BEHIND="$(git rev-list --count HEAD.."origin/$BRANCH" 2>/dev/null || echo 0)"
    AHEAD="$(git rev-list --count "origin/$BRANCH"..HEAD 2>/dev/null || echo 0)"
fi
BEHIND="${BEHIND:-0}"
AHEAD="${AHEAD:-0}"

# Unpushed commits on main are local work that nothing has reviewed, and installing
# them unattended is the same hazard as installing a dirty tree. Skipping here also
# keeps the invariant everything below relies on: if we proceed, the commit that
# gets built is origin's tip (either HEAD already equals it, or the fast-forward
# makes it so), which is what the failed-launch memo and provenance record assume.
if [ "$AHEAD" -gt 0 ] && [ "$BEHIND" -eq 0 ]; then
    if [ "$FORCE" = false ]; then
        skip "local $BRANCH has $AHEAD unpushed commit(s) — refusing to install unreviewed local work (push them, or --force)"
    fi
    TARGET_SHA="$LOCAL_SHA"   # --force installs what is actually checked out
else
    TARGET_SHA="$REMOTE_SHA"
fi

# The commit the installed bundle was built from, as recorded by the last
# successful install. Empty means unknown provenance (first run under the
# updater, or a hand-installed app), which counts as needing an update.
INSTALLED_SHA="$(sed -n 1p "$INSTALLED_SHA_FILE" 2>/dev/null || true)"

REASONS=()
[ "$BEHIND" -gt 0 ] && REASONS+=("$BEHIND new upstream commit(s)")
[ "$SRC_VERSION" != "$INST_VERSION" ] && REASONS+=("installed $INST_VERSION != source $SRC_VERSION")
# This is what catches a fast-forward whose build never made it into the bundle:
# the clone has moved on, VERSION may be unchanged, but nothing was installed.
if [ "$INSTALLED_SHA" != "$TARGET_SHA" ]; then
    REASONS+=("installed build is from ${INSTALLED_SHA:-an unknown commit}, target is ${TARGET_SHA:0:7}")
fi
[ "$FORCE" = true ] && REASONS+=("--force")

if [ "$AHEAD" -gt 0 ]; then
    log "note: local $BRANCH is $AHEAD commit(s) ahead of origin/$BRANCH"
fi

if [ ${#REASONS[@]} -eq 0 ]; then
    skip "already up to date (v$INST_VERSION @ ${LOCAL_SHA:0:7})"
fi

# A commit that builds and passes tests can still crash on launch. Without this
# memo the rollback leaves installed != source forever, and the agent quits and
# replaces the user's app every 6 hours in an endless flap.
# The memo suppresses UPGRADES only. If the installed app is missing or broken
# there is nothing to protect, and skipping would leave the user with no working
# app and an agent that declines to fix it on every firing — so a repair is
# always attempted, but a bounded number of times so it cannot rebuild forever.
FAILED_ATTEMPTS=0
if [ "$FORCE" = false ] && [ -f "$FAILED_LAUNCH_MEMO" ]; then
    FAILED_SHA="$(sed -n 1p "$FAILED_LAUNCH_MEMO" 2>/dev/null || true)"
    FAILED_ATTEMPTS="$(sed -n 2p "$FAILED_LAUNCH_MEMO" 2>/dev/null || true)"
    case "$FAILED_ATTEMPTS" in ''|*[!0-9]*) FAILED_ATTEMPTS=1 ;; esac
    if [ -n "$FAILED_SHA" ] && [ "$FAILED_SHA" = "$TARGET_SHA" ]; then
        if [ "$INST_VERSION" != "none" ] && [ "$INST_VERSION" != "broken" ]; then
            skip "${TARGET_SHA:0:7} already failed to launch (see $FAILED_LAUNCH_MEMO) — waiting for a newer commit (--force to retry)"
        elif [ "$FAILED_ATTEMPTS" -ge "$MAX_LAUNCH_ATTEMPTS" ]; then
            skip "${TARGET_SHA:0:7} failed to launch $FAILED_ATTEMPTS times and no working install could be restored — giving up until a newer commit lands (--force to retry)"
        else
            log "no healthy install and ${TARGET_SHA:0:7} previously failed to launch — retrying (attempt $((FAILED_ATTEMPTS + 1)) of $MAX_LAUNCH_ATTEMPTS)"
        fi
    else
        FAILED_ATTEMPTS=0
    fi
fi

log "update needed: ${REASONS[*]}"
UPDATE_STARTED=true

if [ "$DRY_RUN" = true ]; then
    # SRC_VERSION still comes from the pre-fast-forward tree, so read the target
    # commit's VERSION to report what a real run would actually install.
    TARGET_VERSION="$(git show "$TARGET_SHA:VERSION" 2>/dev/null | sed -n 's/^[[:space:]]*VERSION=//p' | head -1 | tr -d '"'"'"' \t\r')"
    log "DRY RUN: would fast-forward to ${TARGET_SHA:0:7}, build, test, and install v${TARGET_VERSION:-$SRC_VERSION} over v$INST_VERSION"
    exit 0
fi

# ------------------------------------------------------------------- get code
if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
    # --ff-only so a diverged or rebased local main is reported, never rewritten.
    if ! git merge --ff-only "origin/$BRANCH" >/dev/null 2>&1; then
        skip "cannot fast-forward to origin/$BRANCH (local main diverged, or a dirty file blocks it) — resolve manually"
    fi
    NEW_SHA="$(git rev-parse HEAD)"
    [ "$NEW_SHA" = "$LOCAL_SHA" ] || log "fast-forwarded ${LOCAL_SHA:0:7} -> ${NEW_SHA:0:7}"
    SRC_VERSION="$(source_version)"   # may have moved with the new commits
    [ -n "$SRC_VERSION" ] || die "could not parse VERSION= after fast-forward"
fi

# --------------------------------------------------------------- build + test
# All of this happens before anything is uninstalled, so a broken main cannot
# take a working install down with it. build-app.sh runs swift build itself.
log "running tests..."
if ! run_bounded "$TEST_TIMEOUT_SECS" swift test >>"$LOG_FILE" 2>&1; then
    die "tests failed or timed out — installed app left untouched (see $LOG_FILE)"
fi

log "building and bundling v$SRC_VERSION..."
if ! run_bounded "$BUILD_TIMEOUT_SECS" "$PROJECT_DIR/scripts/build-app.sh" >>"$LOG_FILE" 2>&1; then
    die "build failed or timed out — installed app left untouched (see $LOG_FILE)"
fi
[ -d "$BUILT_APP" ] || die "expected bundle missing at $BUILT_APP"
[ -x "$BUILT_APP/Contents/MacOS/$APP_NAME" ] || die "built bundle has no executable — refusing to install"

# This runs in a live clone, so the tree can move between the preflight check and
# the end of the build. Installing then would ship a bundle of mixed state while
# recording TARGET_SHA as its provenance — a lie that also suppresses future runs.
POST_SHA="$(git rev-parse HEAD)"
if [ "$POST_SHA" != "$TARGET_SHA" ]; then
    die "HEAD moved from ${TARGET_SHA:0:7} to ${POST_SHA:0:7} while building — discarding this build, will retry next run"
fi
if [ "$FORCE" = false ]; then
    POST_DIRTY="$(git status --porcelain --untracked-files=no -- Sources Tests Assets Package.swift Package.resolved VERSION scripts 2>/dev/null || true)"
    POST_UNTRACKED="$(git ls-files --others --exclude-standard -- Sources Tests Assets 2>/dev/null || true)"
    if [ -n "$POST_DIRTY" ] || [ -n "$POST_UNTRACKED" ]; then
        die "build inputs changed while building — discarding this build, will retry next run"
    fi
fi

# ----------------------------------------------------------------- install it
app_running && WAS_RUNNING=true

quit_app() {
    app_running || return 0
    osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true
    for _ in $(seq 1 10); do
        app_running || return 0
        sleep 1
    done
    log "graceful quit timed out; sending SIGTERM"
    # Signal the pids we resolved from the installed bundle, not every process
    # that happens to share the name.
    for pid in $(app_pids); do
        kill -TERM "$pid" 2>/dev/null || true
    done
    for _ in $(seq 1 5); do
        app_running || return 0
        sleep 1
    done
    return 1
}

# Stage the copy beside the target, then swap with renames. A ditto straight into
# the live path leaves a half-written bundle there if it is interrupted.
rm -rf "$STAGED_APP"
if ! ditto "$BUILT_APP" "$STAGED_APP" 2>>"$LOG_FILE"; then
    rm -rf "$STAGED_APP"
    die "could not stage new bundle into $INSTALL_ROOT"
fi
[ -x "$STAGED_APP/Contents/MacOS/$APP_NAME" ] || { rm -rf "$STAGED_APP"; die "staged bundle incomplete — aborting before touching the install"; }

INSTALL_PHASE_STARTED=true

if [ "$WAS_RUNNING" = true ]; then
    log "quitting running $APP_NAME (v$INST_VERSION)..."
    quit_app || { rm -rf "$STAGED_APP"; die "could not quit $APP_NAME — aborting before install"; }
fi

# Version goes into a filename; keep it to safe characters.
SAFE_INST_VERSION="$(printf '%s' "$INST_VERSION" | tr -cd 'A-Za-z0-9._-')"
if [ -d "$INSTALLED_APP" ]; then
    # BACKUP_PATH is what cleanup and restore_backup treat as the good copy to
    # return to, so it is only assigned once the backup is proven complete. The
    # backup dir is under $HOME while the install root need not be, and a
    # cross-volume mv is a copy-then-delete that can fail partway.
    CANDIDATE_BACKUP="$BACKUP_DIR/$APP_NAME-${SAFE_INST_VERSION:-unknown}-$(date '+%Y%m%d%H%M%S').app"
    if ! mv "$INSTALLED_APP" "$CANDIDATE_BACKUP"; then
        rm -rf "$CANDIDATE_BACKUP" "$STAGED_APP" 2>/dev/null || true
        die "could not move existing app aside"
    fi
    if [ -x "$CANDIDATE_BACKUP/Contents/MacOS/$APP_NAME" ]; then
        BACKUP_PATH="$CANDIDATE_BACKUP"
        log "previous app backed up to $BACKUP_PATH"
    elif [ -d "$INSTALLED_APP" ]; then
        # The copy failed before the delete, so the complete original is still
        # installed. Keep it and abort — never trade it for a partial copy.
        rm -rf "$CANDIDATE_BACKUP" "$STAGED_APP" 2>/dev/null || true
        die "backup copy is incomplete — leaving the existing install in place"
    else
        # Original already gone and the backup is unusable. There is nothing to
        # roll back to, so continue: the staged bundle was verified complete.
        log "backup is incomplete and the original is gone — installing the new bundle with no rollback point"
        rm -rf "$CANDIDATE_BACKUP" 2>/dev/null || true
    fi
fi

# Both operands are on the same volume, so this rename is atomic: the install
# path holds either the old bundle or the complete new one, never a partial.
if ! mv "$STAGED_APP" "$INSTALLED_APP"; then
    log "swap failed; restoring previous app"
    rm -rf "$STAGED_APP" 2>/dev/null || true
    if [ -n "$BACKUP_PATH" ] && [ -d "$BACKUP_PATH" ]; then
        mv "$BACKUP_PATH" "$INSTALLED_APP" && log "rolled back to v$INST_VERSION"
    fi
    die "install failed"
fi

restore_backup() {
    # Always clear the install path first: leaving a bad bundle there is what
    # makes a broken install look healthy to the next run.
    rm -rf "$INSTALLED_APP" 2>/dev/null || true
    [ -n "$BACKUP_PATH" ] && [ -d "$BACKUP_PATH" ] || return 1
    mv "$BACKUP_PATH" "$INSTALLED_APP" || return 1
    # $BACKUP_DIR lives under $HOME while the install root does not, so if the
    # home directory is on another volume this mv was a copy, not a rename — and
    # an interrupted copy can pass a naive health check while being incomplete.
    if [ ! -x "$INSTALLED_APP/Contents/MacOS/$APP_NAME" ]; then
        log "restored bundle is incomplete — clearing it rather than leaving a broken app"
        rm -rf "$INSTALLED_APP" 2>/dev/null || true
        return 1
    fi
    log "rolled back to v$INST_VERSION"
    [ "$WAS_RUNNING" = true ] && open "$INSTALLED_APP" >/dev/null 2>&1 || true
    return 0
}

# ------------------------------------------------------------------- relaunch
# Verify the new bundle launches even when the app wasn't running: installing a
# crash-on-launch build and reporting success is precisely what the memo exists
# to prevent, and skipping the check whenever the user had quit the app left that
# hole wide open.
# The user may have launched the old bundle while we were staging. `open` would
# just activate that surviving process, and the check below would then "verify"
# the old executable instead of the one just installed.
if app_running; then
    log "an instance was started during the install; quitting it so verification tests the new bundle"
    if ! quit_app; then
        # `open` would just activate that surviving process, and app_running would
        # then accept the OLD executable as proof the new one launched — committing
        # a possibly crash-on-launch update. This is an environment problem, not a
        # bad build, so roll back without blacklisting the commit.
        log "could not stop the running instance, so the new bundle cannot be verified"
        if restore_backup; then
            notify "Update aborted: a running instance blocked verification. Rolled back to v$INST_VERSION."
            die "aborted before verification: a running instance could not be stopped; rolled back"
        fi
        notify "Update aborted: a running instance blocked verification and rollback FAILED."
        die "aborted before verification: a running instance could not be stopped and no rollback was possible"
    fi
fi

open "$INSTALLED_APP" >/dev/null 2>&1 || true
LAUNCHED=false
for _ in $(seq 1 10); do
    if app_running; then
        LAUNCHED=true
        LAUNCHED_PID="$(app_pids | head -1)"
        break
    fi
    sleep 1
done
# Surviving the first sighting is not enough — a crash-on-startup app appears
# briefly and then vanishes, which would otherwise count as success.
if [ "$LAUNCHED" = true ]; then
    sleep "$LAUNCH_SETTLE_SECS"
    app_running || { LAUNCHED=false; log "v$SRC_VERSION started then exited"; }
fi

if [ "$LAUNCHED" = false ]; then
    if [ "$DIRTY_BUILD" = true ]; then
        # The crash came from uncommitted working-tree code, so blaming the commit
        # would refuse a legitimate install of it once the user reverts.
        log "not recording a failed launch: this build included uncommitted changes"
    else
        mkdir -p "$STATE_DIR"
        printf '%s\n%s\n%s\n' "$TARGET_SHA" "$((FAILED_ATTEMPTS + 1))" \
            "v$SRC_VERSION failed to launch on $(date '+%Y-%m-%d %H:%M:%S')" > "$FAILED_LAUNCH_MEMO"
        log "recorded failed launch in $FAILED_LAUNCH_MEMO (attempt $((FAILED_ATTEMPTS + 1)) of $MAX_LAUNCH_ATTEMPTS)"
    fi
    if restore_backup; then
        notify "v$SRC_VERSION would not start. Rolled back to v$INST_VERSION."
        die "new version would not start; rolled back"
    fi
    notify "v$SRC_VERSION would not start and rollback FAILED. No app installed."
    die "new version would not start and no working install could be restored — older backups (if any) are in $BACKUP_DIR"
fi

# From here the install is committed: the bundle is in place and confirmed to run,
# so cleanup must stop treating the backup as the state to return to.
LAUNCH_VERIFIED=true

# Leave the user's app in the state we found it: we only started it to check.
if [ "$WAS_RUNNING" = false ]; then
    CURRENT_PID="$(app_pids | head -1)"
    if [ -n "$LAUNCHED_PID" ] && [ -n "$CURRENT_PID" ] && [ "$CURRENT_PID" != "$LAUNCHED_PID" ]; then
        # Someone started it during the ~18s verification window; leave theirs alone.
        log "launch verified; $APP_NAME was started by someone else meanwhile — leaving it running"
    else
        log "launch verified; returning $APP_NAME to its previous (not running) state"
        quit_app || log "warning: could not quit $APP_NAME after verification"
    fi
fi

# Clear the memo: this commit installed and launched fine.
rm -f "$FAILED_LAUNCH_MEMO" 2>/dev/null || true

mkdir -p "$STATE_DIR"
if [ "$DIRTY_BUILD" = true ]; then
    # The bundle contains uncommitted code, so no commit describes it. Drop the
    # record rather than claim this commit is installed.
    rm -f "$INSTALLED_SHA_FILE" 2>/dev/null || true
else
    printf '%s\n' "$TARGET_SHA" > "$INSTALLED_SHA_FILE" 2>/dev/null || true
fi

log "updated v$INST_VERSION -> v$SRC_VERSION @ $(git rev-parse --short HEAD)"

# --------------------------------------------------------------------- prune
# Keep the most recent few backups as manual rollback points. Guarded so a
# missing/empty backup dir can never fail the run that just succeeded.
prune_backups() {
    local listed count=0 path
    listed="$(find "$BACKUP_DIR" -maxdepth 1 -name "$APP_NAME-*.app" -exec stat -f '%m %N' {} \; 2>/dev/null | sort -rn || true)"
    [ -n "$listed" ] || return 0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        count=$((count + 1))
        [ "$count" -le "$KEEP_BACKUPS" ] && continue
        path="${line#* }"
        rm -rf "$path" 2>/dev/null && log "pruned old backup $(basename "$path")"
    done <<PRUNE_LIST
$listed
PRUNE_LIST
    return 0
}
prune_backups || true
