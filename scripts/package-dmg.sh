#!/usr/bin/env bash
# Build, optionally codesign, and package OpenShokz as a DMG.
#
# Usage:
#   ./scripts/package-dmg.sh
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/package-dmg.sh
#
# Optional env:
#   CONFIGURATION=Release|Debug   (default Release)
#   DERIVED_DATA=/tmp/...         (default /tmp/OpenShokz-DerivedData)
#   CODESIGN_IDENTITY=...         if set, signs the .app before DMG
#   NOTARIZE=1                    if set with APPLE_ID / APPLE_TEAM_ID / APPLE_APP_SPECIFIC_PASSWORD, notarizes

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="${DERIVED_DATA:-/tmp/OpenShokz-DerivedData}"
DIST="${ROOT}/dist"
APP_NAME="OpenShokz"
BUNDLE_ID="app.openshokz.OpenShokz"

cd "${ROOT}"

if [[ ! -f OpenShokz.xcodeproj/project.pbxproj ]]; then
  command -v xcodegen >/dev/null || { echo "error: xcodegen required (brew install xcodegen)"; exit 1; }
  xcodegen generate
fi

if [[ ! -x OpenShokz/Resources/Binaries/ffmpeg ]]; then
  echo "→ Fetching bundled binaries…"
  ./scripts/fetch-binaries.sh
fi

echo "→ Building ${APP_NAME} (${CONFIGURATION})…"
xcodebuild \
  -scheme OpenShokz \
  -configuration "${CONFIGURATION}" \
  -derivedDataPath "${DERIVED_DATA}" \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
[[ -d "${APP}" ]] || { echo "error: missing app at ${APP}"; exit 1; }

# Strip FileProvider / Finder xattrs that break codesign
xattr -c "${APP}" 2>/dev/null || true
find "${APP}" -exec xattr -c {} \; 2>/dev/null || true

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  echo "→ Codesigning with ${CODESIGN_IDENTITY}…"
  ENTITLEMENTS="${ROOT}/OpenShokz/OpenShokz.entitlements"
  SIGN_ARGS=(--force --options runtime --timestamp --sign "${CODESIGN_IDENTITY}")
  if [[ -f "${ENTITLEMENTS}" ]]; then
    SIGN_ARGS+=(--entitlements "${ENTITLEMENTS}")
  fi
  # Sign helpers first, then the bundle
  if [[ -d "${APP}/Contents/Resources/Binaries" ]]; then
    find "${APP}/Contents/Resources/Binaries" -type f -perm -111 -print0 \
      | xargs -0 -I{} codesign "${SIGN_ARGS[@]}" {}
  fi
  codesign "${SIGN_ARGS[@]}" "${APP}"
  codesign --verify --deep --strict --verbose=2 "${APP}"
else
  echo "→ Skipping codesign (set CODESIGN_IDENTITY to sign locally)"
fi

mkdir -p "${DIST}"
STAGE="$(mktemp -d)/${APP_NAME}"
mkdir -p "${STAGE}/.background"
ditto "${APP}" "${STAGE}/${APP_NAME}.app"
ln -sf /Applications "${STAGE}/Applications"
cp "${ROOT}/scripts/assets/dmg-background@2x.png" "${STAGE}/.background/background.png"

DMG="${DIST}/${APP_NAME}.dmg"
RW_DMG="${DIST}/${APP_NAME}-rw.dmg"
rm -f "${DMG}" "${RW_DMG}"

echo "→ Creating writable image…"
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGE}" \
  -ov -format UDRW \
  "${RW_DMG}"

# Style the drag-to-install window: background art, icon layout, no chrome.
# Best-effort — a failed Finder session on CI must not block the release.
echo "→ Styling installer window…"
MOUNT_DIR="/Volumes/${APP_NAME}"
hdiutil detach "${MOUNT_DIR}" >/dev/null 2>&1 || true
hdiutil attach "${RW_DMG}" -noautoopen >/dev/null
style_dmg() {
  osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "${APP_NAME}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 540}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 104
    set text size of viewOptions to 12
    set background picture of viewOptions to file ".background:background.png"
    set position of item "${APP_NAME}.app" of container window to {165, 185}
    set position of item "Applications" of container window to {495, 185}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
}
for attempt in 1 2 3; do
  if style_dmg; then
    echo "  styled (attempt ${attempt})"
    break
  fi
  echo "  styling attempt ${attempt} failed; retrying…"
  sleep 2
done
sync
hdiutil detach "${MOUNT_DIR}"

echo "→ Compressing ${DMG}…"
hdiutil convert "${RW_DMG}" -format UDZO -imagekey zlib-level=9 -ov -o "${DMG}"
rm -f "${RW_DMG}"

if [[ "${NOTARIZE:-0}" == "1" ]]; then
  : "${APPLE_ID:?APPLE_ID required for notarization}"
  : "${APPLE_TEAM_ID:?APPLE_TEAM_ID required for notarization}"
  : "${APPLE_APP_SPECIFIC_PASSWORD:?APPLE_APP_SPECIFIC_PASSWORD required for notarization}"
  echo "→ Notarizing…"
  xcrun notarytool submit "${DMG}" \
    --apple-id "${APPLE_ID}" \
    --team-id "${APPLE_TEAM_ID}" \
    --password "${APPLE_APP_SPECIFIC_PASSWORD}" \
    --wait
  xcrun stapler staple "${DMG}"
fi

echo "✓ ${DMG}"
ls -lh "${DMG}"
