#!/bin/zsh
set -euo pipefail

# Usage: ./release.sh 0.1.0 [--publish]
#
# Builds a release .app, zips it via ditto (preserves bundle metadata),
# and prints the SHA-256 + suggested gh release command.
# With --publish, also tags + pushes + creates the GitHub release.

if [ "${1:-}" = "" ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    print "Usage: $0 <version> [--publish]"
    print "  e.g. $0 0.1.0"
    print "       $0 0.1.0 --publish"
    exit 1
fi

VERSION="$1"
PUBLISH=false
[ "${2:-}" = "--publish" ] && PUBLISH=true

APP_NAME="TimeToClickup"
SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"

DIST_DIR="dist"
ARCHIVE="$DIST_DIR/$APP_NAME-v$VERSION.zip"

print -P "%F{cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%f"
print -P "%F{cyan}  Release $APP_NAME v$VERSION%f"
print -P "%F{cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%f"

# 1. Build the .app
APP_VERSION="$VERSION" ./build_app.sh

# 2. Package
mkdir -p "$DIST_DIR"
rm -f "$ARCHIVE"
print -P "%F{cyan}→%f Packaging $ARCHIVE"
ditto -c -k --keepParent ".build/release/$APP_NAME.app" "$ARCHIVE"

# 3. Hashes
SHA="$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"
SIZE="$(du -h "$ARCHIVE" | cut -f1)"

print ""
print -P "%F{green}✓%f Artifact ready"
print "  File:    $ARCHIVE"
print "  Size:    $SIZE"
print "  SHA-256: $SHA"
print ""

if $PUBLISH; then
    if ! command -v gh >/dev/null 2>&1; then
        print -P "%F{red}✗%f gh CLI not found. Install with: brew install gh"
        exit 1
    fi
    TAG="v$VERSION"
    if git rev-parse "$TAG" >/dev/null 2>&1; then
        print -P "%F{yellow}!%f Tag $TAG already exists locally — skipping tag step"
    else
        print -P "%F{cyan}→%f Tagging $TAG"
        git tag -a "$TAG" -m "Release $TAG"
        git push origin "$TAG"
    fi
    print -P "%F{cyan}→%f Creating GitHub release $TAG"
    gh release create "$TAG" "$ARCHIVE" \
        --title "$APP_NAME $TAG" \
        --generate-notes
    print -P "%F{green}✓%f Released. URL above."
else
    print -P "%F{cyan}Next steps (manual):%f"
    print "  git tag -a v$VERSION -m \"Release v$VERSION\""
    print "  git push origin v$VERSION"
    print "  gh release create v$VERSION '$ARCHIVE' \\"
    print "      --title '$APP_NAME v$VERSION' --generate-notes"
    print ""
    print -P "  Or run %F{yellow}./release.sh $VERSION --publish%f to do it automatically."
fi
