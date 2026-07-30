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
# shellcheck source=../VERSION
source VERSION
: "${VERSION:?VERSION not set in VERSION file}"
: "${BUILD:?BUILD not set in VERSION file}"
TAG="v$VERSION"

echo "Preparing release $TAG (build $BUILD)"

# ------------------------------------------------------------------ validation
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$CURRENT_BRANCH" = "$BRANCH" ] || die "on '$CURRENT_BRANCH'; releases are cut from '$BRANCH'"

[ -z "$(git status --porcelain --untracked-files=no)" ] || die "working tree has uncommitted changes — commit them first"

if git rev-parse "$TAG" >/dev/null 2>&1; then
    die "tag $TAG already exists — bump VERSION before releasing"
fi

git fetch --quiet origin "$BRANCH" --tags 2>/dev/null || echo "warning: could not fetch origin (offline?)"
if git rev-parse "origin/$BRANCH" >/dev/null 2>&1; then
    [ "$(git rev-parse HEAD)" = "$(git rev-parse "origin/$BRANCH")" ] \
        || die "local $BRANCH differs from origin/$BRANCH — push or pull first so the tag matches what others get"
fi

# The bundle must actually build and pass tests at this commit before it's tagged.
echo "Running tests..."
swift test >/dev/null 2>&1 || die "tests failed — not releasing"

echo "Verifying bundle stamps $VERSION..."
./scripts/build-app.sh >/dev/null 2>&1 || die "build-app.sh failed"
BUILT_VERSION="$(defaults read "$PROJECT_DIR/build/PortPilot.app/Contents/Info.plist" CFBundleShortVersionString)"
[ "$BUILT_VERSION" = "$VERSION" ] || die "bundle reports $BUILT_VERSION but VERSION says $VERSION"

echo "All checks passed."

if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN: would tag $TAG at $(git rev-parse --short HEAD)"
    [ "$PUSH" = true ] && echo "DRY RUN: would push $TAG and publish a GitHub release"
    exit 0
fi

# ------------------------------------------------------------------------ tag
git tag -a "$TAG" -m "Port Pilot $VERSION (build $BUILD)"
echo "Created local tag $TAG at $(git rev-parse --short HEAD)"

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

    gh release create "$TAG" \
        --title "Port Pilot $VERSION" \
        --notes-file "$NOTES_FILE" \
        --generate-notes
    rm -f "$NOTES_FILE"
    echo "Published GitHub release $TAG"
else
    echo "gh CLI not found — tag pushed, but no GitHub release created."
fi
