#!/bin/bash
set -e

REPO="jonecat/audiofile"
DOWNLOAD_URL="https://github.com/${REPO}/releases/latest/download/AudioFile.app.zip"
INSTALL_DIR="/Applications"
APP_NAME="AudioFile.app"

echo "==> Downloading latest AudioFile release from GitHub..."
TMP_DIR="$(mktemp -d /tmp/audiofile-install.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

curl -fSL "${DOWNLOAD_URL}" -o "${TMP_DIR}/AudioFile.app.zip"

echo "==> Extracting ${APP_NAME}..."
ditto -x -k "${TMP_DIR}/AudioFile.app.zip" "${TMP_DIR}"

if [ ! -d "${TMP_DIR}/${APP_NAME}" ]; then
    echo "Error: ${APP_NAME} not found in downloaded archive."
    exit 1
fi

echo "==> Installing ${APP_NAME} to ${INSTALL_DIR}..."
rm -rf "${INSTALL_DIR}/${APP_NAME}"
mv "${TMP_DIR}/${APP_NAME}" "${INSTALL_DIR}/${APP_NAME}"

# Ensure quarantine attributes are cleared and ad-hoc signature is intact
xattr -cr "${INSTALL_DIR}/${APP_NAME}" 2>/dev/null || true
codesign --force --deep --sign - "${INSTALL_DIR}/${APP_NAME}" 2>/dev/null || true

echo "==> Installed ${INSTALL_DIR}/${APP_NAME} successfully!"
echo "==> Launching AudioFile..."
open "${INSTALL_DIR}/${APP_NAME}"
