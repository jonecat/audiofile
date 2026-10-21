#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${ROOT_DIR}"

VERSION="1.0.0"
if [ -f "${ROOT_DIR}/VERSION" ]; then
    VERSION="$(tr -d '[:space:]' < "${ROOT_DIR}/VERSION")"
fi

# Sync Resources/Info.plist with VERSION
if [ -f "${ROOT_DIR}/Resources/Info.plist" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${ROOT_DIR}/Resources/Info.plist" 2>/dev/null || true
fi

echo "Building AudioFile v${VERSION} (release)..."
swift build -c release

APP_NAME="AudioFile.app"
APP_DIR="${ROOT_DIR}/${APP_NAME}"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "Creating bundle structure at ${APP_DIR}..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

echo "Copying binary..."
cp -X "${ROOT_DIR}/.build/release/AudioFile" "${MACOS_DIR}/AudioFile"
chmod +x "${MACOS_DIR}/AudioFile"

echo "Copying metadata & resources..."
cp -X "${ROOT_DIR}/Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"

if [ -f "${ROOT_DIR}/Resources/AppIcon.icns" ]; then
    cp -X "${ROOT_DIR}/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

echo "Signing application ad-hoc..."
dot_clean -m "${APP_DIR}" 2>/dev/null || true
xattr -cr "${APP_DIR}" 2>/dev/null || true
codesign --force --deep --sign - "${APP_DIR}"

echo "Packaging release archive AudioFile.app.zip..."
rm -f "${ROOT_DIR}/AudioFile.app.zip"
ditto -c -k --sequesterRsrc --keepParent "${APP_DIR}" "${ROOT_DIR}/AudioFile.app.zip"

echo "Packaging disk image AudioFile.dmg..."
rm -f "${ROOT_DIR}/AudioFile.dmg"
DMG_STAGING="${ROOT_DIR}/.build/dmg_staging"
rm -rf "${DMG_STAGING}"
mkdir -p "${DMG_STAGING}"
cp -R "${APP_DIR}" "${DMG_STAGING}/AudioFile.app"
ln -s /Applications "${DMG_STAGING}/Applications"
hdiutil create -volname "AudioFile" -srcfolder "${DMG_STAGING}" -ov -format UDZO "${ROOT_DIR}/AudioFile.dmg" >/dev/null
rm -rf "${DMG_STAGING}"

echo "Done! Application ready at: ${APP_DIR}, AudioFile.app.zip, and AudioFile.dmg (v${VERSION})"
