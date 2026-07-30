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
#   ./scripts/auto-update.sh --dry-run    # report decisions, mutate nothing
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
LOCK_DIR="${TMPDIR:-/tmp}/portpilot-auto-update.lock"
LOCK_MAX_AGE_MIN=60
KEEP_BACKUPS=3

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

INSTALL_PHASE_STARTED=false
die() {
    log "ERROR: $*"
    [ "$INSTALL_PHASE_STARTED" = true ] && notify "Update failed: $*"
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
if [ -d "$LOCK_DIR" ] && [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +$LOCK_MAX_AGE_MIN 2>/dev/null)" ]; then
    log "clearing stale lock (older than ${LOCK_MAX_AGE_MIN}m)"
    rmdir "$LOCK_DIR" 2>/dev/null || true
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    skip "another auto-update run is in progress"
fi
# TERM/HUP matter: launchd signals agents at logout, and bash does not run an
# EXIT trap for a default-action signal. Without these the lock outlives the run
# and a staged bundle is left behind mid-install.
cleanup() {
    rmdir "$LOCK_DIR" 2>/dev/null || true
    rm -rf "$STAGED_APP" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

# We hold the lock now, so any staged bundle still lying around belongs to a run
# that was killed before its trap fired. Clear them before staging our own.
for orphan in "$INSTALL_ROOT/.$APP_NAME.app.new"*; do
    [ -e "$orphan" ] || continue
    [ "$orphan" = "$STAGED_APP" ] && continue
    rm -rf "$orphan" 2>/dev/null && log "cleared orphaned staged bundle $(basename "$orphan")"
done

# ------------------------------------------------------------------ preflight
command -v git   >/dev/null 2>&1 || die "git not found on PATH"
command -v swift >/dev/null 2>&1 || die "swift toolchain not found on PATH (Xcode / CLT missing?)"
[ -d "$PROJECT_DIR/.git" ] || die "$PROJECT_DIR is not a git repository"
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
if [ "$FORCE" = false ] && { [ -n "$DIRTY_INPUTS" ] || [ -n "$UNTRACKED_SOURCES" ]; }; then
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
[ "$LOCAL_SHA" != "$REMOTE_SHA" ] && BEHIND="$(git rev-list --count HEAD.."origin/$BRANCH")"

# The one commit this run would actually install. Everything downstream — the
# failed-launch memo check AND the memo it writes — must agree on this value, or
# the blacklist silently never matches.
if [ "$BEHIND" -gt 0 ]; then
    TARGET_SHA="$REMOTE_SHA"
else
    TARGET_SHA="$LOCAL_SHA"
fi

REASONS=()
[ "$BEHIND" -gt 0 ] && REASONS+=("$BEHIND new upstream commit(s)")
[ "$SRC_VERSION" != "$INST_VERSION" ] && REASONS+=("installed $INST_VERSION != source $SRC_VERSION")
[ "$FORCE" = true ] && REASONS+=("--force")

# Local main being AHEAD of origin is not a reason to reinstall — treating it as
# one rebuilt and swapped the bundle every 6 hours forever on any machine with an
# unpushed commit. Worth a log line, nothing more.
if [ "$LOCAL_SHA" != "$REMOTE_SHA" ] && [ "$BEHIND" -eq 0 ]; then
    log "note: local $BRANCH is ahead of origin/$BRANCH — nothing to pull"
fi

if [ ${#REASONS[@]} -eq 0 ]; then
    skip "already up to date (v$INST_VERSION @ ${LOCAL_SHA:0:7})"
fi

# A commit that builds and passes tests can still crash on launch. Without this
# memo the rollback leaves installed != source forever, and the agent quits and
# replaces the user's app every 6 hours in an endless flap.
# Only ever suppress an UPGRADE. If the installed app is missing or broken there
# is nothing to protect, and skipping would leave the user with no working app
# and an agent that declines to fix it on every firing.
if [ "$FORCE" = false ] && [ "$INST_VERSION" != "none" ] && [ "$INST_VERSION" != "broken" ] \
   && [ -f "$FAILED_LAUNCH_MEMO" ]; then
    FAILED_SHA="$(head -1 "$FAILED_LAUNCH_MEMO" 2>/dev/null || true)"
    if [ -n "$FAILED_SHA" ] && [ "$FAILED_SHA" = "$TARGET_SHA" ]; then
        skip "${TARGET_SHA:0:7} already failed to launch (see $FAILED_LAUNCH_MEMO) — waiting for a newer commit (--force to retry)"
    fi
fi

log "update needed: ${REASONS[*]}"

if [ "$DRY_RUN" = true ]; then
    log "DRY RUN: would fast-forward to ${REMOTE_SHA:0:7}, build, test, and install v$SRC_VERSION over v$INST_VERSION"
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

# ----------------------------------------------------------------- install it
WAS_RUNNING=false
pgrep -x "$APP_NAME" >/dev/null 2>&1 && WAS_RUNNING=true

quit_app() {
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || return 0
    osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true
    for _ in $(seq 1 10); do
        pgrep -x "$APP_NAME" >/dev/null 2>&1 || return 0
        sleep 1
    done
    log "graceful quit timed out; sending SIGTERM"
    pkill -x "$APP_NAME" 2>/dev/null || true
    for _ in $(seq 1 5); do
        pgrep -x "$APP_NAME" >/dev/null 2>&1 || return 0
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
BACKUP_PATH=""
if [ -d "$INSTALLED_APP" ]; then
    BACKUP_PATH="$BACKUP_DIR/$APP_NAME-${SAFE_INST_VERSION:-unknown}-$(date '+%Y%m%d%H%M%S').app"
    mv "$INSTALLED_APP" "$BACKUP_PATH" || { rm -rf "$STAGED_APP"; die "could not move existing app aside"; }
    log "previous app backed up to $BACKUP_PATH"
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
open "$INSTALLED_APP" >/dev/null 2>&1 || true
LAUNCHED=false
for _ in $(seq 1 10); do
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then LAUNCHED=true; break; fi
    sleep 1
done
# Surviving the first sighting is not enough — a crash-on-startup app appears
# briefly and then vanishes, which would otherwise count as success.
if [ "$LAUNCHED" = true ]; then
    sleep "$LAUNCH_SETTLE_SECS"
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || { LAUNCHED=false; log "v$SRC_VERSION started then exited"; }
fi

if [ "$LAUNCHED" = false ]; then
    mkdir -p "$STATE_DIR"
    printf '%s\n%s\n' "$TARGET_SHA" "v$SRC_VERSION failed to launch on $(date '+%Y-%m-%d %H:%M:%S')" > "$FAILED_LAUNCH_MEMO"
    log "recorded failed launch in $FAILED_LAUNCH_MEMO — will not retry this commit"
    if restore_backup; then
        notify "v$SRC_VERSION would not start. Rolled back to v$INST_VERSION."
        die "new version would not start; rolled back"
    fi
    notify "v$SRC_VERSION would not start and rollback FAILED. No app installed."
    die "new version would not start and rollback failed — backup at ${BACKUP_PATH:-none}"
fi

# Leave the user's app in the state we found it: we only started it to check.
if [ "$WAS_RUNNING" = false ]; then
    log "launch verified; returning $APP_NAME to its previous (not running) state"
    quit_app || log "warning: could not quit $APP_NAME after verification"
fi

# Clear the memo: this commit installed and launched fine.
rm -f "$FAILED_LAUNCH_MEMO" 2>/dev/null || true

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
