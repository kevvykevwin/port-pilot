#!/bin/bash
#
# Cuts a Port Pilot release from the VERSION file, so the git tag, the bundle
# version, and the GitHub Releases page can never disagree again.
#
# Local by default: creates the annotated tag and stops. The outward-facing step
# (pushing the tag and publishing the release) requires an explicit --push.
#
# Usage:
#   ./scripts/release.sh              # validate + create local tag
#   ./scripts/release.sh --dry-run    # validate only
#   ./scripts/release.sh --push       # validate, tag, push tag, publish GitHub release
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BRANCH="main"

DRY_RUN=false
PUSH=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --push)    PUSH=true ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
    esac
done

cd "$PROJECT_DIR"
die() { echo "error: $*" >&2; exit 1; }

[ -f VERSION ] || die "VERSION file missing"
# Parsed, not sourced — the file is read by three scripts and a stray `exit` or
# `set -x` in it would break all of them.
read_version_field() {
    sed -n "s/^[[:space:]]*$1=//p" VERSION | head -1 | tr -d '"'"'"' \t\r'
}
VERSION="$(read_version_field VERSION)"
BUILD="$(read_version_field BUILD)"
[ -n "$VERSION" ] || die "could not parse VERSION= from the VERSION file"
[ -n "$BUILD" ] || die "could not parse BUILD= from the VERSION file"
TAG="v$VERSION"

echo "Preparing release $TAG (build $BUILD)"

# ------------------------------------------------------------------ validation
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$CURRENT_BRANCH" = "$BRANCH" ] || die "on '$CURRENT_BRANCH'; releases are cut from '$BRANCH'"

[ -z "$(git status --porcelain --untracked-files=no)" ] || die "working tree has uncommitted changes — commit them first"

# SwiftPM compiles untracked files under its target dirs, so without this the
# "tests pass at this commit" check below could be satisfied by code that is not
# actually in the commit being tagged.
[ -z "$(git ls-files --others --exclude-standard -- Sources Tests Assets)" ] \
    || die "untracked files under Sources/Tests/Assets would be compiled but not tagged — commit or remove them"

# Fetch before the tag check: a tag someone else already pushed is invisible
# locally until it is fetched, and discovering it after tagging is too late.
# For a local-only run a stale ref is tolerable, but publishing compares HEAD
# against origin/main to prove the tag matches what others will get — and pushing
# a tag does not update main. A failed fetch there means tagging an unknown state.
FETCH_OK=true
if ! git fetch --quiet origin "$BRANCH" --tags 2>/dev/null; then
    if [ "$PUSH" = true ]; then
        die "could not fetch origin — refusing to publish a release against a possibly stale origin/$BRANCH"
    fi
    FETCH_OK=false
    echo "warning: could not fetch origin (offline?) — local tag only"
fi

# refs/tags/ specifically — bare `git rev-parse "$TAG"` resolves any ref or
# unambiguous SHA prefix, not just tags.
REUSE_TAG=false
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
    # A local-only run creates the tag and tells you to re-run with --push. That
    # instruction has to actually work, so --push may adopt an existing tag that
    # already points at HEAD instead of refusing it.
    if [ "$PUSH" = true ] && [ "$(git rev-parse "refs/tags/$TAG^{commit}")" = "$(git rev-parse HEAD)" ]; then
        REUSE_TAG=true
        echo "Tag $TAG already exists at HEAD — publishing it."
    else
        die "tag $TAG already exists — bump VERSION before releasing"
    fi
fi

# Only meaningful against a ref we know is current. Enforcing it after a failed
# fetch would block the offline local-tag workflow the warning above advertises.
if [ "$FETCH_OK" = true ] && git rev-parse "origin/$BRANCH" >/dev/null 2>&1; then
    [ "$(git rev-parse HEAD)" = "$(git rev-parse "origin/$BRANCH")" ] \
        || die "local $BRANCH differs from origin/$BRANCH — push or pull first so the tag matches what others get"
fi

# The bundle must actually build and pass tests at this commit before it's tagged.
echo "Running tests..."
swift test >/dev/null 2>&1 || die "tests failed — not releasing"

echo "Verifying bundle stamps $VERSION..."
./scripts/build-app.sh >/dev/null 2>&1 || die "build-app.sh failed"
# plutil, not defaults: this plist is rewritten at the same path on every release,
# and defaults goes through cfprefsd, which can serve the previous value.
BUILT_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$PROJECT_DIR/build/PortPilot.app/Contents/Info.plist")"
[ "$BUILT_VERSION" = "$VERSION" ] || die "bundle reports $BUILT_VERSION but VERSION says $VERSION"

echo "All checks passed."

if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN: would tag $TAG at $(git rev-parse --short HEAD)"
    [ "$PUSH" = true ] && echo "DRY RUN: would push $TAG and publish a GitHub release"
    exit 0
fi

# ------------------------------------------------------------------------ tag
if [ "$REUSE_TAG" = false ]; then
    git tag -a "$TAG" -m "Port Pilot $VERSION (build $BUILD)"
    echo "Created local tag $TAG at $(git rev-parse --short HEAD)"
fi

if [ "$PUSH" = false ]; then
    echo
    echo "Local only. To publish:"
    echo "  ./scripts/release.sh --push     (or: git push origin $TAG)"
    exit 0
fi

# ------------------------------------------------------------------- publish
git push origin "$TAG"
echo "Pushed $TAG"

if command -v gh >/dev/null 2>&1; then
    NOTES_FILE="$(mktemp -t portpilot-release-notes)"
    trap 'rm -f "$NOTES_FILE"' EXIT
    {
        echo "## Install"
        echo
        echo "Port Pilot is built from source — this release intentionally ships **no binary assets**."
        echo "An ad-hoc signed \`.app\` downloaded from the internet is blocked by macOS Gatekeeper with a"
        echo "misleading \"damaged\" error, so cloning and building locally is the supported path:"
        echo
        echo '```bash'
        echo "git clone https://github.com/kevvykevwin/port-pilot.git"
        echo "cd port-pilot && git checkout $TAG"
        echo "./scripts/build-app.sh"
        echo "cp -R build/PortPilot.app /Applications/"
        echo '```'
        echo
        echo "Requires macOS 14.0+ and Xcode Command Line Tools. See the README for details."
        echo
        echo "## Changes"
    } > "$NOTES_FILE"

    # The tag is already pushed at this point, so a failure here leaves it public
    # with no release attached — print the exact retry rather than just dying.
    if ! gh release create "$TAG" \
        --title "Port Pilot $VERSION" \
        --notes-file "$NOTES_FILE" \
        --generate-notes; then
        echo
        echo "error: tag $TAG was pushed but publishing the release failed." >&2
        echo "Retry with:" >&2
        echo "  gh release create $TAG --title \"Port Pilot $VERSION\" --notes-file $NOTES_FILE --generate-notes" >&2
        echo "(or delete the tag: git push origin :refs/tags/$TAG && git tag -d $TAG)" >&2
        trap - EXIT   # keep the notes file around for the retry
        exit 1
    fi
    echo "Published GitHub release $TAG"
else
    echo "gh CLI not found — tag pushed, but no GitHub release created."
fi
