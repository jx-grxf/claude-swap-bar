#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

: "${CSWAPBAR_VERSION:?CSWAPBAR_VERSION is required}"
: "${CSWAPBAR_BUILD:?CSWAPBAR_BUILD is required}"
: "${CSWAPBAR_UPDATE_CHANNEL:?CSWAPBAR_UPDATE_CHANNEL is required}"
: "${CSWAPBAR_RELEASE_TAG:?CSWAPBAR_RELEASE_TAG is required}"
: "${CSWAPBAR_SPARKLE_PUBLIC_KEY:?CSWAPBAR_SPARKLE_PUBLIC_KEY is required}"

APP="dist/ClaudeSwapBar.app"
ZIP="dist/sparkle/ClaudeSwapBar-${CSWAPBAR_VERSION}.zip"
APPCAST="dist/sparkle/appcast.xml"

for path in "$APP" "$ZIP" "$APPCAST"; do
  [[ -e "$path" ]] || { echo "error: missing release artifact: $path" >&2; exit 1; }
done

INFO="$APP/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")" == "me.johannesgrof.claudeswapbar" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")" == "$CSWAPBAR_VERSION" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")" == "$CSWAPBAR_BUILD" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INFO")" == "https://github.com/jx-grxf/claude-swap-bar/releases/latest/download/appcast.xml" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO")" == "$CSWAPBAR_SPARKLE_PUBLIC_KEY" ]]

codesign --verify --deep --strict "$APP"
test -d "$APP/Contents/Frameworks/Sparkle.framework"
unzip -tq "$ZIP"

./script/verify_appcast.swift \
  "$APPCAST" \
  "https://github.com/${GITHUB_REPOSITORY:-jx-grxf/claude-swap-bar}/releases/download/${CSWAPBAR_RELEASE_TAG}/ClaudeSwapBar-${CSWAPBAR_VERSION}.zip" \
  "$CSWAPBAR_UPDATE_CHANNEL" \
  "$CSWAPBAR_VERSION" \
  "$CSWAPBAR_BUILD" \
  "$ZIP"

if [[ "${CSWAPBAR_NOTARY_ENABLED:-}" == "true" ]]; then
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose "$APP"
fi

(
  cd dist/sparkle
  shasum -a 256 "ClaudeSwapBar-${CSWAPBAR_VERSION}.zip" appcast.xml
) > dist/SHA256SUMS

echo "release artifacts ok"
