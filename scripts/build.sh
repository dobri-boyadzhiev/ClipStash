#!/bin/bash
set -euo pipefail

APP_NAME="ClipStash"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RELEASES_DIR="${PROJECT_ROOT}/releases"
VERSION="${1:-3.1.5}"
CONFIG="${2:-debug}"
SCRATCH_PATH="/tmp/clipstash-build"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
BUILD_DIR="${SCRATCH_PATH}/arm64-apple-macosx/${CONFIG}"

echo "🔨 Building ${APP_NAME} v${VERSION} (${CONFIG})..."
swift build -c "${CONFIG}" --scratch-path "${SCRATCH_PATH}" --product ClipStashApp 2>&1

BIN_PATH="${BUILD_DIR}/ClipStashApp"

if [ ! -f "${BIN_PATH}" ]; then
    echo "ERROR: Binary not found at ${BIN_PATH}"
    exit 1
fi

APP_BUNDLE="/tmp/${APP_NAME}.app"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"

echo "📦 Creating app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
mkdir -p "${APP_BUNDLE}/Contents/Frameworks"

cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

find "${BUILD_DIR}" -maxdepth 1 -name '*.bundle' -exec cp -R {} "${APP_BUNDLE}/Contents/Resources/" \;
find "${BUILD_DIR}" -maxdepth 1 -name '*.framework' -exec cp -R {} "${APP_BUNDLE}/Contents/Frameworks/" \;

if find "${BUILD_DIR}" -maxdepth 1 -name '*.framework' | grep -q .; then
    if ! otool -l "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" | grep -q "@executable_path/../Frameworks"; then
        install_name_tool -add_rpath "@executable_path/../Frameworks" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
    fi
fi

cat > "${APP_BUNDLE}/Contents/Info.plist" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>com.clipstash.app</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST_EOF

if [ -n "${CODESIGN_IDENTITY}" ]; then
    echo "🔏 Code signing app bundle..."
    codesign --force --deep --timestamp --options runtime --sign "${CODESIGN_IDENTITY}" "${APP_BUNDLE}"
else
    echo "🔏 Applying ad-hoc signature for local-use app bundle..."
    codesign --force --deep --sign - "${APP_BUNDLE}"
fi

echo "🔎 Verifying app signature..."
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"

echo "💿 Creating DMG..."
DMG_DIR="/tmp/clipstash_dmg"
rm -rf "${DMG_DIR}"
mkdir -p "${DMG_DIR}"
cp -R "${APP_BUNDLE}" "${DMG_DIR}/"
ln -s /Applications "${DMG_DIR}/Applications"

hdiutil create -volname "${APP_NAME}" \
    -srcfolder "${DMG_DIR}" \
    -ov -format UDZO \
    "/tmp/${DMG_NAME}" 2>&1

echo ""
echo "═══════════════════════════════════════"
echo "✅ Build complete!"
echo "   App:  ${APP_BUNDLE}  ($(du -sh "${APP_BUNDLE}" | cut -f1))"
echo "   DMG:  /tmp/${DMG_NAME}  ($(du -sh "/tmp/${DMG_NAME}" | cut -f1))"
echo "   Arch: $(file "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" | grep -o 'arm64')"
if [ -d "${APP_BUNDLE}/Contents/Frameworks/SQLCipher.framework" ]; then
    echo "   SQLCipher: embedded"
fi
echo "═══════════════════════════════════════"
echo ""
echo "📂 Copying DMG to releases/..."
mkdir -p "${RELEASES_DIR}"
cp "/tmp/${DMG_NAME}" "${RELEASES_DIR}/${DMG_NAME}"
echo ""
echo "📋 Install: open /tmp/${DMG_NAME}"
echo "   → Drag ${APP_NAME} to Applications"
echo "   Local: ${RELEASES_DIR}/${DMG_NAME}"
