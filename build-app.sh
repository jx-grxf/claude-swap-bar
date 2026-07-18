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
VERSION="${APP_VERSION:-$(tr -d '[:space:]' < VERSION)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-+Rtqjb/eDLmt9i/NR3ol6BrFRjku/usKzGxQSXNmOSI=}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "▶ Building release…"
swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="${BIN_DIR}/${APP_NAME}"
RESOURCE_BUNDLE="${BIN_DIR}/${APP_NAME}_${APP_NAME}.bundle"
SPARKLE_FRAMEWORK="${BIN_DIR}/Sparkle.framework"
APP="${APP_NAME}.app"
CONTENTS="${APP}/Contents"

rm -rf "${APP}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources" "${CONTENTS}/Frameworks"
cp "${BIN}" "${CONTENTS}/MacOS/${APP_NAME}"

if [ -d "${SPARKLE_FRAMEWORK}" ]; then
  cp -R "${SPARKLE_FRAMEWORK}" "${CONTENTS}/Frameworks/"
else
  echo "Missing Sparkle framework: ${SPARKLE_FRAMEWORK}" >&2
  exit 1
fi

# SwiftPM links binary frameworks against @rpath but only adds @loader_path.
# Packaged macOS apps keep frameworks in Contents/Frameworks.
if ! otool -l "${CONTENTS}/MacOS/${APP_NAME}" \
    | grep -q '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath '@executable_path/../Frameworks' \
    "${CONTENTS}/MacOS/${APP_NAME}"
fi

# Flatten SwiftPM resources into the standard macOS app resource directory.
# MenuBarIcon checks Bundle.main first and falls back to Bundle.module when the
# executable is launched directly during SwiftPM development.
if [ -d "${RESOURCE_BUNDLE}" ]; then
  cp -R "${RESOURCE_BUNDLE}/." "${CONTENTS}/Resources/"
else
  echo "Missing SwiftPM resource bundle: ${RESOURCE_BUNDLE}" >&2
  exit 1
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
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Johannes Grof</string>
    <key>SUFeedURL</key><string>https://github.com/jx-grxf/claude-swap-bar/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_KEY}</string>
    <key>SUEnableInstallerLauncherService</key><true/>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>3600</integer>
</dict>
</plist>
PLIST

SPARKLE="${CONTENTS}/Frameworks/Sparkle.framework"
SIGN_TARGETS=(
  "${SPARKLE}/Versions/B/XPCServices/Downloader.xpc"
  "${SPARKLE}/Versions/B/XPCServices/Installer.xpc"
  "${SPARKLE}/Versions/B/Autoupdate"
  "${SPARKLE}/Versions/B/Updater.app"
)

if [ "${SIGN_IDENTITY}" = "-" ]; then
  echo "▶ Ad-hoc signing…"
  for target in "${SIGN_TARGETS[@]}"; do
    [ -e "${target}" ] || continue
    codesign --force --sign - --preserve-metadata=entitlements "${target}"
  done
  codesign --force --sign - "${SPARKLE}"
  codesign --force --sign - "${APP}"
else
  echo "▶ Signing with: ${SIGN_IDENTITY}"
  for target in "${SIGN_TARGETS[@]}"; do
    [ -e "${target}" ] || continue
    codesign --force --options runtime --timestamp \
      --preserve-metadata=entitlements --sign "${SIGN_IDENTITY}" "${target}"
  done
  codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${SPARKLE}"
  codesign --force --options runtime --timestamp \
    --preserve-metadata=entitlements --sign "${SIGN_IDENTITY}" "${APP}"
fi
codesign --verify --deep --strict "${APP}"

echo "✓ Built ${APP}"
echo "  Launch with:  open ${APP}"
echo "  Install with: cp -R ${APP} /Applications/"
