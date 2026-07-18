#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="${CSWAPBAR_RELEASE_TAG:-v$VERSION}"
CHANNEL="${CSWAPBAR_UPDATE_CHANNEL:-stable}"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$ ]] || {
  echo "error: unsupported version $VERSION" >&2; exit 1;
}
[[ "$TAG" == "v$VERSION" ]] || { echo "error: tag must be v$VERSION" >&2; exit 1; }
[[ -s "release-notes/$TAG.md" ]] || { echo "error: missing release-notes/$TAG.md" >&2; exit 1; }

case "$CHANNEL" in
  stable) [[ "$VERSION" != *-* ]] ;;
  beta) [[ "$VERSION" == *-beta.* ]] ;;
  *) echo "error: unsupported update channel $CHANNEL" >&2; exit 1 ;;
esac

grep -q 'exact: "2.9.2"' Package.swift
grep -q '"version" : "2.9.2"' Package.resolved

echo "release metadata ok: $TAG ($CHANNEL)"
