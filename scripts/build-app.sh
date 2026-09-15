#!/bin/zsh
# 用 SwiftPM 构建并打包成菜单栏 .app（无需 Xcode，只要 Command Line Tools）。
# 用法：scripts/build-app.sh            → 产物在 build/Codex Account Switch.app
#       scripts/build-app.sh --install  → 同时安装到 ~/Applications 并启动
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Codex Account Switch"
EXEC_NAME="CodexAccountSwitch"
BUNDLE_ID="com.eddiexux.codex-account-switch"
VERSION="${VERSION:-0.1.0}"
APP="build/$APP_NAME.app"

swift build -c release 2>&1 | tail -3
BIN=".build/release/$EXEC_NAME"
[[ -x "$BIN" ]] || { echo "构建产物不存在：$BIN" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXEC_NAME"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleExecutable</key><string>$EXEC_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "已打包：$APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications/$APP_NAME.app"
  mkdir -p "$HOME/Applications"
  pkill -x "$EXEC_NAME" 2>/dev/null || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST"
  echo "已安装并启动：$DEST"
fi
