#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Mac Orchestrator"
EXECUTABLE_NAME="MacOrchestrator"
BUNDLE_ID="com.jay.mac-orchestrator"
MIN_SYSTEM_VERSION="13.0"
APP_VERSION="$(printenv MAC_ORCHESTRATOR_VERSION || printf '%s' '0.2.1')"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INFO_PLIST="$CONTENTS_DIR/Info.plist"

HOST_ARCH="$(/usr/bin/uname -m)"
if [[ "$HOST_ARCH" != "arm64" ]]; then
  echo "Mac Orchestrator release helpers require an arm64 build host." >&2
  exit 1
fi

swift build -c release --package-path "$PROJECT_DIR"
BUILD_DIR="$(swift build -c release --show-bin-path --package-path "$PROJECT_DIR")"
BUILD_BINARY="$BUILD_DIR/$EXECUTABLE_NAME"

BUILD_FILE_INFO="$(/usr/bin/file "$BUILD_BINARY")"
case "$BUILD_FILE_INFO" in
  *arm64*) ;;
  *)
    echo "Release helper executable is not arm64: $BUILD_FILE_INFO" >&2
    exit 1
    ;;
esac

/bin/rm -rf "$APP_BUNDLE"
/bin/mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
/usr/bin/ditto "$BUILD_BINARY" "$MACOS_DIR/$EXECUTABLE_NAME"
/bin/chmod 755 "$MACOS_DIR/$EXECUTABLE_NAME"

/usr/bin/plutil -create xml1 "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleExecutable -string "$EXECUTABLE_NAME" "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleIdentifier -string "$BUNDLE_ID" "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleName -string "$APP_NAME" "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleDisplayName -string "$APP_NAME" "$INFO_PLIST"
/usr/bin/plutil -insert CFBundlePackageType -string APPL "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleShortVersionString -string "$APP_VERSION" "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleVersion -string 1 "$INFO_PLIST"
/usr/bin/plutil -insert LSMinimumSystemVersion -string "$MIN_SYSTEM_VERSION" "$INFO_PLIST"
/usr/bin/plutil -insert LSUIElement -bool true "$INFO_PLIST"
/usr/bin/plutil -insert NSPrincipalClass -string NSApplication "$INFO_PLIST"
/usr/bin/plutil -insert NSAppleEventsUsageDescription -string "Mac Orchestrator uses Apple Events to control apps at your request." "$INFO_PLIST"
/usr/bin/plutil -insert NSScreenCaptureUsageDescription -string "Mac Orchestrator reads the screen when you invoke its screen tools." "$INFO_PLIST"

/usr/bin/codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
SIGNATURE_DETAILS="$(/usr/bin/codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 || true)"
case "$SIGNATURE_DETAILS" in
  *Signature=adhoc*) ;;
  *)
    echo "Release helper is not ad-hoc signed." >&2
    exit 1
    ;;
esac

if [[ -e "$RESOURCES_DIR"/* ]]; then
  echo "Release helper contains unexpected bundled resources." >&2
  exit 1
fi

echo "$APP_BUNDLE"
