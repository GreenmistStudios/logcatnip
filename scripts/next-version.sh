#!/usr/bin/env bash
# Works out the next release version from the conventional commits since the last vX.Y.Z tag.
#
#   scripts/next-version.sh                 # auto: read the commit messages
#   scripts/next-version.sh --bump minor    # force patch, minor or major
#
# Prints key=value lines for $GITHUB_OUTPUT:
#   previous=0.3.1  version=0.4.0  bump=minor  tag=v0.4.0  release=true
#
# Auto rules (merge commits are ignored; squash merges use the PR title):
#   `type!:` or a `BREAKING CHANGE:` footer -> major (minor while the version is 0.x)
#   feat                                    -> minor
#   fix, perf, refactor, revert             -> patch
#   anything else (docs, chore, ci, test…)  -> no release
set -euo pipefail

cd "$(dirname "$0")/.."
BUMP="auto"
while [ $# -gt 0 ]; do
    case "$1" in
        --bump) BUMP="${2:-}"; shift 2 ;;
        --bump=*) BUMP="${1#--bump=}"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
case "$BUMP" in auto | patch | minor | major) ;; *) echo "--bump must be auto, patch, minor or major" >&2; exit 2 ;; esac

LAST_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' HEAD 2>/dev/null || true)"
if [ -n "$LAST_TAG" ]; then
    PREVIOUS="${LAST_TAG#v}"
    RANGE="$LAST_TAG..HEAD"
else
    PREVIOUS="0.0.0"
    RANGE="HEAD"
fi
IFS=. read -r MAJOR MINOR PATCH <<<"$PREVIOUS"

if [ "$BUMP" = "auto" ]; then
    BUMP="none"
    SUBJECTS="$(git log --no-merges --format=%s "$RANGE")"
    BODIES="$(git log --no-merges --format=%b "$RANGE")"
    TYPE='[a-z]+(\([^)]*\))?'
    if grep -Eq "^${TYPE}!:" <<<"$SUBJECTS" \
        || grep -Eq '^BREAKING[ -]CHANGE:' <<<"$BODIES"; then
        BUMP="major"
    elif grep -Eq '^feat(\([^)]*\))?:' <<<"$SUBJECTS"; then
        BUMP="minor"
    elif grep -Eq '^(fix|perf|refactor|revert)(\([^)]*\))?:' <<<"$SUBJECTS"; then
        BUMP="patch"
    fi
    # Before 1.0, breaking changes bump the minor version; 1.0 is cut by hand with --bump major.
    if [ "$BUMP" = "major" ] && [ "$MAJOR" -eq 0 ]; then BUMP="minor"; fi
fi

case "$BUMP" in
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    patch) PATCH=$((PATCH + 1)) ;;
esac
VERSION="$MAJOR.$MINOR.$PATCH"

echo "previous=$PREVIOUS"
echo "version=$VERSION"
echo "bump=$BUMP"
echo "tag=v$VERSION"
if [ "$BUMP" = "none" ]; then echo "release=false"; else echo "release=true"; fi
