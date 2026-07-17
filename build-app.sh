#!/usr/bin/env bash
# Build a release binary and wrap it into a double-clickable .app bundle.
#
# Usage:
#   ./build-app.sh                          # ad-hoc signed (local use)
#   SIGN_IDENTITY="Developer ID Application: ..." ./build-app.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ClaudeSwapBar"
BUNDLE_ID="me.johannesgrof.claudeswapbar"
VERSION="1.0.0"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "▶ Building release…"
swift build -c release

BIN=".build/release/${APP_NAME}"
RESOURCE_BUNDLE=".build/release/${APP_NAME}_${APP_NAME}.bundle"
APP="${APP_NAME}.app"
CONTENTS="${APP}/Contents"

rm -rf "${APP}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"
cp "${BIN}" "${CONTENTS}/MacOS/${APP_NAME}"

# SwiftPM resource bundle (app logo etc.) — Bundle.module resolves it from
# the app's Resources directory.
if [ -d "${RESOURCE_BUNDLE}" ]; then
  cp -R "${RESOURCE_BUNDLE}" "${CONTENTS}/Resources/"
fi

cp Resources/AppIcon.icns "${CONTENTS}/Resources/AppIcon.icns"

cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>Claude Swap</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Johannes Grof</string>
</dict>
</plist>
PLIST

if [ "${SIGN_IDENTITY}" = "-" ]; then
  echo "▶ Ad-hoc signing…"
  codesign --force --sign - "${APP}"
else
  echo "▶ Signing with: ${SIGN_IDENTITY}"
  codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${APP}"
fi
codesign --verify --deep --strict "${APP}"

echo "✓ Built ${APP}"
echo "  Launch with:  open ${APP}"
echo "  Install with: cp -R ${APP} /Applications/"
