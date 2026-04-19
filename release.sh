#!/bin/bash
set -e

# SpliceKit Motion Release Script
# Usage: ./release.sh <version> "<release notes>"
# Example: ./release.sh 1.0.0 "Initial release"

VERSION="$1"
NOTES="$2"
REPO_ROOT="$(pwd)"
if [ -z "$VERSION" ]; then
    echo "Usage: ./release.sh <version> [\"release notes\"]"
    exit 1
fi
if [ -z "$NOTES" ]; then
    NOTES="Bug fixes and improvements"
fi

SIGN_ID="Developer ID Application: Brian Tate (RH4U5VJHM6)"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-SpliceKit}"
XCODE_PROJECT="patcher/SpliceKitMotion.xcodeproj"
XCODE_SCHEME="SpliceKitMotion"
VERSION_FILE="patcher/SpliceKitMotion/Configuration/Version.xcconfig"
BUILD_DIR="patcher/build"
BUILT_APP_NAME="SpliceKitMotion.app"
DMG_NAME="SpliceKitMotion-v${VERSION}.dmg"
DMG_PATH="patcher/${DMG_NAME}"

CURRENT_BRANCH="$(git branch --show-current)"
PUSH_REMOTE="$(git config --get branch.${CURRENT_BRANCH}.remote || echo origin)"
PUSH_BRANCH="$(git config --get branch.${CURRENT_BRANCH}.merge | sed 's#refs/heads/##')"
if [ -z "${PUSH_BRANCH}" ]; then
    PUSH_BRANCH="${CURRENT_BRANCH}"
fi
REMOTE_URL="$(git remote get-url "${PUSH_REMOTE}")"
RELEASE_REPO="$(printf '%s' "${REMOTE_URL}" | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
TAG_NAME="v${VERSION}"

if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
    echo "ERROR: Working tree is dirty. Commit, stash, or remove local changes before releasing." >&2
    git status --short >&2
    exit 1
fi

echo "[0/12] Checking notarization profile (${KEYCHAIN_PROFILE})..."
if ! xcrun notarytool history --keychain-profile "${KEYCHAIN_PROFILE}" >/dev/null 2>&1; then
    echo "ERROR: Notarization profile ${KEYCHAIN_PROFILE} is not ready." >&2
    echo "Set KEYCHAIN_PROFILE=<name> or run: xcrun notarytool store-credentials" >&2
    exit 1
fi

update_version_file() {
    python3 - "$VERSION_FILE" "$VERSION" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
version = sys.argv[2]
text = path.read_text()
updated, count = re.subn(r"^SPLICEKIT_MOTION_VERSION\s*=\s*.*$", f"SPLICEKIT_MOTION_VERSION = {version}", text, flags=re.M)
if count != 1:
    raise SystemExit(f"ERROR: failed to update SPLICEKIT_MOTION_VERSION in {path}")
path.write_text(updated)
PY
}

echo "=== SpliceKit Motion Release v${VERSION} ==="
echo ""

echo "[1/12] Bumping version to ${VERSION}..."
update_version_file

echo "[2/12] Building MotionKit dylib..."
make clean
make

if [ ! -f "build/MotionKit" ]; then
    echo "ERROR: build/MotionKit not produced by make" >&2
    exit 1
fi
DYLIB_FILE_INFO=$(file build/MotionKit)
echo "  ${DYLIB_FILE_INFO}"
if ! echo "${DYLIB_FILE_INFO}" | grep -q "universal binary"; then
    echo "WARNING: MotionKit dylib is not a universal binary" >&2
fi

echo "[3/12] Building SpliceKit Motion patcher via Xcode..."
rm -rf "${BUILD_DIR}"
xcodebuild -project "${XCODE_PROJECT}" \
    -scheme "${XCODE_SCHEME}" \
    -configuration Release \
    -derivedDataPath "${BUILD_DIR}" \
    ONLY_ACTIVE_ARCH=NO \
    clean build 2>&1 | tail -10

BUILT_APP="${BUILD_DIR}/Build/Products/Release/${BUILT_APP_NAME}"
if [ ! -d "${BUILT_APP}" ]; then
    echo "ERROR: ${BUILT_APP} not produced" >&2
    exit 1
fi
echo "  Built: ${BUILT_APP}"

echo "[4/12] Bundling MotionKit dylib into app Resources..."
APP_RES="${BUILT_APP}/Contents/Resources"
mkdir -p "${APP_RES}"
cp build/MotionKit "${APP_RES}/MotionKit"
echo "  Copied MotionKit dylib"

echo "[5/12] Signing embedded binaries..."
# Sign any Mach-O in Resources (the MotionKit dylib)
find "${BUILT_APP}/Contents/Resources" -type f | while read f; do
    if file -b "$f" 2>/dev/null | grep -q "Mach-O"; then
        codesign --force --options runtime --timestamp --sign "${SIGN_ID}" "$f"
        echo "  Signed: $(basename "$f")"
    fi
done

echo "[6/12] Signing app bundle..."
codesign --force --options runtime --timestamp --sign "${SIGN_ID}" "${BUILT_APP}"
codesign --verify --deep --strict "${BUILT_APP}"
echo "  Verification passed"

echo "[7/12] Creating DMG..."
DMG_TEMP="${BUILD_DIR}/dmg_staging"
rm -rf "${DMG_TEMP}" "${DMG_PATH}"
mkdir -p "${DMG_TEMP}"
cp -R "${BUILT_APP}" "${DMG_TEMP}/"
ln -s /Applications "${DMG_TEMP}/Applications"

hdiutil create -volname "SpliceKit Motion" \
    -srcfolder "${DMG_TEMP}" \
    -ov -format UDZO \
    "${DMG_PATH}"
rm -rf "${DMG_TEMP}"
echo "  DMG: ${DMG_PATH} ($(du -h "${DMG_PATH}" | cut -f1))"

echo "[8/12] Submitting DMG for notarization (this may take a few minutes)..."
xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${KEYCHAIN_PROFILE}" --wait

echo "[9/12] Stapling notarization ticket..."
xcrun stapler staple "${DMG_PATH}"
echo "  Stapled: ${DMG_PATH}"

echo "[10/12] Committing version bump..."
git add "${VERSION_FILE}"
if ! git diff --cached --quiet; then
    git commit -m "Release v${VERSION}: ${NOTES}"
    git push "${PUSH_REMOTE}" "HEAD:${PUSH_BRANCH}"
else
    echo "  No version changes to commit"
fi

echo "[11/12] Tagging and pushing..."
if git rev-parse -q --verify "refs/tags/${TAG_NAME}" >/dev/null; then
    git tag -d "${TAG_NAME}"
fi
git tag -a "${TAG_NAME}" -m "Release ${TAG_NAME}"

LOCAL_TAG_SHA="$(git rev-parse "${TAG_NAME}^{}")"
REMOTE_TAG_SHA="$(git ls-remote --tags "${PUSH_REMOTE}" "refs/tags/${TAG_NAME}^{}" | awk '{print $1}')"
if [ -n "${REMOTE_TAG_SHA}" ] && [ "${REMOTE_TAG_SHA}" != "${LOCAL_TAG_SHA}" ]; then
    echo "ERROR: Remote tag ${TAG_NAME} already exists on ${PUSH_REMOTE} at ${REMOTE_TAG_SHA}, expected ${LOCAL_TAG_SHA}" >&2
    exit 1
fi
if [ -z "${REMOTE_TAG_SHA}" ]; then
    git push "${PUSH_REMOTE}" "refs/tags/${TAG_NAME}:refs/tags/${TAG_NAME}"
fi

echo "[12/12] Creating GitHub release..."
if gh release create "${TAG_NAME}" "${DMG_PATH}" \
    -R "${RELEASE_REPO}" \
    --verify-tag \
    --title "${TAG_NAME}" \
    --notes "${NOTES}"; then
    RELEASE_URL=$(gh release view "${TAG_NAME}" -R "${RELEASE_REPO}" --json url -q '.url')
else
    echo "ERROR: Failed to create GitHub release ${TAG_NAME}" >&2
    exit 1
fi

echo ""
echo "========================================="
echo "  SpliceKit Motion v${VERSION} released!"
echo "  ${RELEASE_URL}"
echo "========================================="
echo ""
echo "  - Built via Xcode, signed, notarized, stapled"
echo "  - DMG: ${DMG_PATH}"
echo "  - Pushed to ${PUSH_BRANCH}, GitHub release created"
echo ""
