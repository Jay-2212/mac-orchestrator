#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Mac Orchestrator"
EXECUTABLE_NAME="MacOrchestrator"
BUNDLE_ID="com.jay.mac-orchestrator"
MIN_SYSTEM_VERSION="13.0"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INFO_PLIST="$CONTENTS_DIR/Info.plist"

swift build -c release --package-path "$PROJECT_DIR"
BUILD_DIR="$(swift build -c release --show-bin-path --package-path "$PROJECT_DIR")"
BUILD_BINARY="$BUILD_DIR/$EXECUTABLE_NAME"

/bin/mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
/usr/bin/ditto "$BUILD_BINARY" "$MACOS_DIR/$EXECUTABLE_NAME"
/bin/chmod 755 "$MACOS_DIR/$EXECUTABLE_NAME"

NGROK_SOURCE="$HOME/Library/Application Support/ngrok/ngrok"
if [[ ! -x "$NGROK_SOURCE" ]]; then
  echo "ngrok binary not found at: $NGROK_SOURCE" >&2
  echo "Run ./script/bootstrap_ngrok.sh once to download it, then retry." >&2
  exit 1
fi
/usr/bin/ditto "$NGROK_SOURCE" "$RESOURCES_DIR/ngrok"
/bin/chmod 755 "$RESOURCES_DIR/ngrok"

/usr/bin/plutil -create xml1 "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleExecutable -string "$EXECUTABLE_NAME" "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleIdentifier -string "$BUNDLE_ID" "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleName -string "$APP_NAME" "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleDisplayName -string "$APP_NAME" "$INFO_PLIST"
/usr/bin/plutil -insert CFBundlePackageType -string APPL "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleShortVersionString -string 0.2.0 "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleVersion -string 1 "$INFO_PLIST"
/usr/bin/plutil -insert LSMinimumSystemVersion -string "$MIN_SYSTEM_VERSION" "$INFO_PLIST"
/usr/bin/plutil -insert LSUIElement -bool true "$INFO_PLIST"
/usr/bin/plutil -insert NSPrincipalClass -string NSApplication "$INFO_PLIST"
/usr/bin/plutil -insert NSAppleEventsUsageDescription -string "Mac Orchestrator uses Apple Events to control apps at your request." "$INFO_PLIST"
/usr/bin/plutil -insert NSScreenCaptureUsageDescription -string "Mac Orchestrator reads the screen when you invoke its screen tools." "$INFO_PLIST"

# Ad-hoc signing (identity "-") embeds a cdhash-only designated requirement,
# which changes on every rebuild — TCC (Screen Recording especially) then
# treats each rebuild as a new, unrecognized app and drops the grant. Signing
# with a persistent identity (a self-signed Keychain cert, or a real Apple
# Developer ID) keeps the designated requirement's certificate-based rule
# stable across rebuilds, so TCC grants survive. See README for the one-time
# setup. Falls back to ad-hoc if no identity is configured.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  echo "WARNING: signing ad-hoc (no CODESIGN_IDENTITY set)." >&2
  echo "  Screen Recording / Accessibility grants will NOT survive the next rebuild." >&2
  echo "  See README for the one-time Keychain Access cert setup, then re-run with:" >&2
  echo "  CODESIGN_IDENTITY=\"Your Cert Name\" ./script/distribute.sh" >&2
fi

/usr/bin/codesign --force --sign "$CODESIGN_IDENTITY" --identifier "$BUNDLE_ID" "$RESOURCES_DIR/ngrok"
/usr/bin/codesign --force --sign "$CODESIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP_BUNDLE"

echo "$APP_BUNDLE"
