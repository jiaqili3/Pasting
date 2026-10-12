#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="Pasting"
BUNDLE_ID="com.jiaqili.pasting"
MIN_SYS="14.0"
SDK="$(xcrun --show-sdk-path)"
BUILD_DIR="$ROOT/.build"
BIN="$BUILD_DIR/$APP_NAME"
APP_DIR="$ROOT/dist/$APP_NAME.app"
INSTALL_DIR="${HOME}/Applications"
INSTALL_APP="$INSTALL_DIR/$APP_NAME.app"

mkdir -p "$BUILD_DIR"

echo "==> Compiling $APP_NAME with swiftc..."
# shellcheck disable=SC2046
swiftc -swift-version 5 \
  -sdk "$SDK" \
  -target arm64-apple-macos${MIN_SYS} \
  -O \
  -framework AppKit \
  -framework Carbon \
  -framework ServiceManagement \
  -framework ApplicationServices \
  -framework Combine \
  -framework SwiftUI \
  -framework Quartz \
  -o "$BIN" \
  $(ls -1 Sources/Pasting/*.swift | sort)

echo "    binary: $BIN"

echo "==> Assembling app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

ICON_KEY=""
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
  ICON_KEY=$'\t<key>CFBundleIconFile</key>\n\t<string>AppIcon</string>'
fi

cat > "$APP_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key>
	<string>${APP_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.4.1</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>${MIN_SYS}</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright © 2026 Jiaqi Li</string>
${ICON_KEY}
</dict>
</plist>
PLIST

echo "APPL????" > "$APP_DIR/Contents/PkgInfo"

echo "==> Ad-hoc codesign..."
codesign --force --deep -s - "$APP_DIR"

echo "==> Installing to ${INSTALL_APP}..."
mkdir -p "$INSTALL_DIR"
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.3
rm -rf "$INSTALL_APP"
cp -R "$APP_DIR" "$INSTALL_APP"

echo "==> Done."
echo "    Bundle: $APP_DIR"
echo "    Installed: $INSTALL_APP"
echo "    Launch: open \"$INSTALL_APP\""
