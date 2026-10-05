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
#   NOTARY_KEY_PATH        alternative to NOTARY_PROFILE: path to an App Store
#   NOTARY_KEY_ID          Connect API .p8 key, its Key ID and Issuer ID,
#   NOTARY_ISSUER_ID       passed straight to `notarytool submit`. Use this on
#                          CI runners where `store-credentials` crashes.
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
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi

notarise() {
  # notarytool exits 0 even when Apple rejects the submission — the failure
  # only shows up in the "status:" line of --wait's own output. Check it
  # explicitly and pull the rejection log before stapling, or `stapler staple`
  # fails later with an opaque "Record not found" instead of the real reason.
  local out
  out=$(xcrun notarytool submit "$DMG" "$@" --wait 2>&1) || { echo "$out"; exit 1; }
  echo "$out"
  local id
  id=$(echo "$out" | awk '/^  id:/{print $2; exit}')
  if ! echo "$out" | grep -q "status: Accepted"; then
    echo "==> Notarisation rejected; fetching log for $id"
    xcrun notarytool log "$id" "$@" || true
    exit 1
  fi
}

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "==> Notarising (keychain profile)"
  notarise --keychain-profile "$NOTARY_PROFILE"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
elif [ -n "${NOTARY_KEY_PATH:-}" ]; then
  echo "==> Notarising (API key)"
  notarise --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
else
  echo "==> Skipping notarisation (NOTARY_PROFILE/NOTARY_KEY_PATH not set)"
fi

echo "Done: $DMG"
