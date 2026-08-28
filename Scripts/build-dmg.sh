#!/bin/bash
#
# Builds a Release copy of Cleat and packages it as a DMG.
#
# This script deliberately does NOT contain, choose, or create any signing
# identity. Provide your own through the environment:
#
#   DEVELOPMENT_TEAM       your Apple Developer Team ID (also set it in
#                          Config/Signing.xcconfig so the XPC code-signing
#                          requirement is built with the right team)
#   SIGN_IDENTITY          e.g. "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE         a notarytool keychain profile you created with
#                          `xcrun notarytool store-credentials`
#   MARKETING_VERSION      optional; overrides the 1.0 in project.yml
#   CURRENT_PROJECT_VERSION optional; overrides the build number in project.yml
#
# Without SIGN_IDENTITY the DMG is built unsigned, which is fine for local
# testing and NOT distributable.
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD_DIR="$ROOT/build"
APP_NAME="Cleat"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Building Release"
xcodebuild \
  -project Cleat.xcodeproj \
  -scheme Cleat \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  ${DEVELOPMENT_TEAM:+DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"} \
  ${SIGN_IDENTITY:+CODE_SIGN_IDENTITY="$SIGN_IDENTITY"} \
  ${SIGN_IDENTITY:+CODE_SIGN_STYLE=Manual} \
  ${MARKETING_VERSION:+MARKETING_VERSION="$MARKETING_VERSION"} \
  ${CURRENT_PROJECT_VERSION:+CURRENT_PROJECT_VERSION="$CURRENT_PROJECT_VERSION"} \
  build

APP="$BUILD_DIR/DerivedData/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "Build produced no app at $APP" >&2; exit 1; }

if [ -n "${SIGN_IDENTITY:-}" ]; then
  echo "==> Re-signing inside out with the hardened runtime"
  # The helper has to be signed before the bundle that contains it.
  codesign --force --options runtime --timestamp \
    --entitlements HelperSupport/CleatHelper.entitlements \
    --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/CleatHelper"
  codesign --force --options runtime --timestamp \
    --entitlements Cleat/Cleat.entitlements \
    --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
fi

echo "==> Building the DMG"
STAGING="$BUILD_DIR/dmg"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
DMG="$BUILD_DIR/$APP_NAME.dmg"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$SIGN_IDENTITY" "$DMG"
fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "==> Notarising"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
else
  echo "==> Skipping notarisation (NOTARY_PROFILE not set)"
fi

echo "Done: $DMG"
