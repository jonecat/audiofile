#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${ROOT_DIR}"

CURRENT_VERSION="1.0.0"
if [ -f "${ROOT_DIR}/VERSION" ]; then
    CURRENT_VERSION="$(tr -d '[:space:]' < "${ROOT_DIR}/VERSION")"
fi

# Check if the current version tag already exists in git or on GitHub
if [ "${1}" == "--initial" ]; then
    NEXT_VERSION="${CURRENT_VERSION}"
elif git rev-parse "v${CURRENT_VERSION}" >/dev/null 2>&1 || gh release view "v${CURRENT_VERSION}" >/dev/null 2>&1; then
    IFS='.' read -r MAJOR MINOR PATCH <<< "${CURRENT_VERSION}"
    MAJOR=${MAJOR:-1}
    MINOR=${MINOR:-0}
    PATCH=${PATCH:-0}
    NEXT_PATCH=$((PATCH + 1))
    NEXT_VERSION="${MAJOR}.${MINOR}.${NEXT_PATCH}"
else
    NEXT_VERSION="${CURRENT_VERSION}"
fi

echo "Preparing AudioFile point release: v${NEXT_VERSION}..."
echo "${NEXT_VERSION}" > "${ROOT_DIR}/VERSION"

# Increment CFBundleVersion integer build number as well
if [ -f "${ROOT_DIR}/Resources/Info.plist" ]; then
    BUILD_NUM=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${ROOT_DIR}/Resources/Info.plist" 2>/dev/null || echo "1")
    if [[ "${BUILD_NUM}" =~ ^[0-9]+$ ]] && [ "${NEXT_VERSION}" != "${CURRENT_VERSION}" ]; then
        NEXT_BUILD=$((BUILD_NUM + 1))
    else
        NEXT_BUILD="${BUILD_NUM}"
    fi
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${NEXT_VERSION}" "${ROOT_DIR}/Resources/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${NEXT_BUILD}" "${ROOT_DIR}/Resources/Info.plist"
fi

# Build AudioFile.app and AudioFile.app.zip with updated version
"${SCRIPT_DIR}/build_app.sh"

# Stage and commit any changes if working tree has modifications
git add VERSION Resources/Info.plist
if ! git diff --cached --quiet || ! git diff --quiet; then
    git add -A
    git commit -m "Release v${NEXT_VERSION}"
fi

# Tag the release
git tag -f "v${NEXT_VERSION}"

# Push branch and tag to GitHub
echo "Pushing main and tag v${NEXT_VERSION} to GitHub..."
SKIP_AUTO_RELEASE=1 git push -u origin main --tags

# Create or update GitHub Release with AudioFile.app.zip binary archive
echo "Publishing GitHub Release v${NEXT_VERSION} with AudioFile.app.zip..."
if gh release view "v${NEXT_VERSION}" >/dev/null 2>&1; then
    gh release upload "v${NEXT_VERSION}" "${ROOT_DIR}/AudioFile.app.zip" --clobber
else
    gh release create "v${NEXT_VERSION}" "${ROOT_DIR}/AudioFile.app.zip" \
        --title "AudioFile v${NEXT_VERSION}" \
        --generate-notes
fi

echo "Successfully published AudioFile v${NEXT_VERSION} to GitHub Releases!"
