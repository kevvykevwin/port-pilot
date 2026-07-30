#!/bin/bash
#
# Port Pilot auto-updater.
#
# Rebuilds from origin/main and reinstalls to /Applications when either
#   (a) new commits have landed upstream, or
#   (b) the installed bundle version is behind the version in build-app.sh.
#
# Designed to run unattended from launchd, so every failure path leaves the
# currently-installed app untouched and exits quietly. See scripts/install-auto-update.sh.
#
# Usage:
#   ./scripts/auto-update.sh              # normal run
#   ./scripts/auto-update.sh --dry-run    # report decisions, mutate nothing
#   ./scripts/auto-update.sh --force      # rebuild+reinstall even if nothing changed
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="PortPilot"
INSTALLED_APP="/Applications/$APP_NAME.app"
BUILT_APP="$PROJECT_DIR/build/$APP_NAME.app"
BRANCH="main"

LOG_DIR="$HOME/Library/Logs/PortPilot"
LOG_FILE="$LOG_DIR/auto-update.log"
BACKUP_DIR="$HOME/Library/Caches/PortPilot/backups"
LOCK_DIR="${TMPDIR:-/tmp}/portpilot-auto-update.lock"
LOCK_MAX_AGE_MIN=60
KEEP_BACKUPS=3

DRY_RUN=false
FORCE=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --force)   FORCE=true ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
    esac
done

mkdir -p "$LOG_DIR" "$BACKUP_DIR"

# Log to file always; mirror to stdout only when a human is watching, so launchd
# runs don't double-write through its StandardOutPath.
log() {
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') $*"
    printf '%s\n' "$line" >> "$LOG_FILE"
    printf '%s\n' "$line"
    return 0
}
die()  { log "ERROR: $*"; exit 1; }
skip() { log "SKIP:  $*"; exit 0; }

# ---------------------------------------------------------------- concurrency
# mkdir is atomic, so it doubles as the lock. Clear locks left behind by a run
# that was killed before its trap fired.
if [ -d "$LOCK_DIR" ] && [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +$LOCK_MAX_AGE_MIN 2>/dev/null)" ]; then
    log "clearing stale lock (older than ${LOCK_MAX_AGE_MIN}m)"
    rmdir "$LOCK_DIR" 2>/dev/null || true
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    skip "another auto-update run is in progress"
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

# ------------------------------------------------------------------ preflight
command -v git   >/dev/null 2>&1 || die "git not found on PATH"
command -v swift >/dev/null 2>&1 || die "swift toolchain not found on PATH (Xcode / CLT missing?)"
[ -d "$PROJECT_DIR/.git" ] || die "$PROJECT_DIR is not a git repository"
[ -x "$PROJECT_DIR/scripts/build-app.sh" ] || die "scripts/build-app.sh missing or not executable"
[ -f "$PROJECT_DIR/VERSION" ] || die "VERSION file missing — cannot determine target version"

cd "$PROJECT_DIR"

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$CURRENT_BRANCH" = "$BRANCH" ] || skip "on branch '$CURRENT_BRANCH', not '$BRANCH' — leaving feature work alone"

# Only build inputs matter. A dirty agents.md or docs/ shouldn't freeze updates
# forever, but dirty source means active development — don't install that.
#
# Untracked files are deliberately ignored (--untracked-files=no): they aren't part
# of the committed build and can't block a fast-forward, so gating on them would
# deadlock the updater on any scratch file (plans/, a stray script, editor droppings).
DIRTY_INPUTS="$(git status --porcelain --untracked-files=no -- Sources Tests Package.swift scripts 2>/dev/null || true)"
if [ -n "$DIRTY_INPUTS" ] && [ "$FORCE" = false ]; then
    log "dirty build inputs:"
    log "$DIRTY_INPUTS"
    skip "uncommitted changes in build inputs — refusing to install an unreviewed build (use --force to override)"
fi

# --------------------------------------------------------------- what changed
if ! git fetch --quiet origin "$BRANCH" 2>/dev/null; then
    skip "git fetch failed (offline, or no access to origin)"
fi

LOCAL_SHA="$(git rev-parse HEAD)"
REMOTE_SHA="$(git rev-parse "origin/$BRANCH")"

source_version() {
    # The VERSION file is the single source of truth (see also build-app.sh).
    # Read in a subshell so sourcing can't leak vars into this script's scope.
    ( set -a; . "$PROJECT_DIR/VERSION" >/dev/null 2>&1 || exit 1; printf '%s' "${VERSION:-unknown}" )
}
installed_version() {
    [ -d "$INSTALLED_APP" ] || { echo "none"; return; }
    defaults read "$INSTALLED_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown"
}

SRC_VERSION="$(source_version)"
INST_VERSION="$(installed_version)"

COMMITS_BEHIND="$(git rev-list --count HEAD.."origin/$BRANCH")"
REASONS=()
[ "$LOCAL_SHA" != "$REMOTE_SHA" ] && REASONS+=("$COMMITS_BEHIND new upstream commit(s)")
[ "$SRC_VERSION" != "$INST_VERSION" ] && REASONS+=("installed $INST_VERSION != source $SRC_VERSION")
[ "$FORCE" = true ] && REASONS+=("--force")

if [ ${#REASONS[@]} -eq 0 ]; then
    skip "already up to date (v$INST_VERSION @ ${LOCAL_SHA:0:7})"
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
    log "fast-forwarded ${LOCAL_SHA:0:7} -> ${REMOTE_SHA:0:7}"
    SRC_VERSION="$(source_version)"   # may have moved with the new commits
fi

# --------------------------------------------------------------- build + test
# Both run before anything is uninstalled, so a broken main can't take the
# working app down with it.
log "building (swift build -c release)..."
if ! swift build -c release >>"$LOG_FILE" 2>&1; then
    die "build failed — installed app left untouched (see $LOG_FILE)"
fi

log "running tests..."
if ! swift test >>"$LOG_FILE" 2>&1; then
    die "tests failed — refusing to install (see $LOG_FILE)"
fi

log "bundling..."
if ! "$PROJECT_DIR/scripts/build-app.sh" >>"$LOG_FILE" 2>&1; then
    die "bundling failed — installed app left untouched (see $LOG_FILE)"
fi
[ -d "$BUILT_APP" ] || die "expected bundle missing at $BUILT_APP"

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

if [ "$WAS_RUNNING" = true ]; then
    log "quitting running $APP_NAME (v$INST_VERSION)..."
    quit_app || die "could not quit $APP_NAME — aborting before install"
fi

BACKUP_PATH=""
if [ -d "$INSTALLED_APP" ]; then
    BACKUP_PATH="$BACKUP_DIR/$APP_NAME-$INST_VERSION-$(date '+%Y%m%d%H%M%S').app"
    mv "$INSTALLED_APP" "$BACKUP_PATH" || die "could not move existing app aside"
    log "previous app backed up to $BACKUP_PATH"
fi

restore_backup() {
    [ -n "$BACKUP_PATH" ] && [ -d "$BACKUP_PATH" ] || return 1
    rm -rf "$INSTALLED_APP" 2>/dev/null || true
    mv "$BACKUP_PATH" "$INSTALLED_APP" || return 1
    log "rolled back to v$INST_VERSION"
    [ "$WAS_RUNNING" = true ] && open "$INSTALLED_APP" >/dev/null 2>&1 || true
    return 0
}

if ! ditto "$BUILT_APP" "$INSTALLED_APP" 2>>"$LOG_FILE"; then
    restore_backup || log "ROLLBACK FAILED — backup at $BACKUP_PATH"
    die "install failed"
fi

# ------------------------------------------------------------------- relaunch
if [ "$WAS_RUNNING" = true ]; then
    open "$INSTALLED_APP" >/dev/null 2>&1 || true
    LAUNCHED=false
    for _ in $(seq 1 10); do
        if pgrep -x "$APP_NAME" >/dev/null 2>&1; then LAUNCHED=true; break; fi
        sleep 1
    done
    if [ "$LAUNCHED" = false ]; then
        log "v$SRC_VERSION failed to launch"
        restore_backup || log "ROLLBACK FAILED — backup at $BACKUP_PATH"
        die "new version would not start; rolled back"
    fi
fi

log "updated v$INST_VERSION -> v$SRC_VERSION @ $(git rev-parse --short HEAD)"

# --------------------------------------------------------------------- prune
# Keep the most recent few backups as manual rollback points.
if [ -d "$BACKUP_DIR" ]; then
    ls -dt "$BACKUP_DIR/$APP_NAME"-*.app 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | while read -r old; do
        rm -rf "$old" && log "pruned old backup $(basename "$old")"
    done
fi
