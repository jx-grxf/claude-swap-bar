#!/usr/bin/env bash
# Build a release binary and wrap it into a double-clickable .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ClaudeSwapBar"
BUNDLE_ID="me.johannesgrof.claudeswapbar"
VERSION="0.1.0"

echo "▶ Building release…"
swift build -c release

BIN=".build/release/${APP_NAME}"
APP="${APP_NAME}.app"
CONTENTS="${APP}/Contents"

rm -rf "${APP}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"
cp "${BIN}" "${CONTENTS}/MacOS/${APP_NAME}"

cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>Claude Swap</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so Gatekeeper lets it run locally.
codesign --force --deep --sign - "${APP}" >/dev/null 2>&1 || true

echo "✓ Built ${APP}"
echo "  Launch with:  open ${APP}"
echo "  Install with: cp -R ${APP} /Applications/"
