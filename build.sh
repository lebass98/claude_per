#!/bin/zsh
# ClaudeUsageBar.app 빌드 스크립트
#   ./build.sh          빌드만
#   ./build.sh install  빌드 후 /Applications에 설치하고 재실행
set -e
cd "$(dirname "$0")"
source ./version.env

APP="build/ClaudeUsageBar.app"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ClaudeUsageBar "$APP/Contents/MacOS/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ClaudeUsageBar</string>
    <key>CFBundleDisplayName</key><string>Claude Usage Bar</string>
    <key>CFBundleIdentifier</key><string>com.wordncode.ClaudeUsageBar</string>
    <key>CFBundleExecutable</key><string>ClaudeUsageBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "✅ 빌드 완료: $APP (v${VERSION} / build ${BUILD})"

if [[ "$1" == "install" ]]; then
    pkill -x ClaudeUsageBar || true
    sleep 1
    rm -rf /Applications/ClaudeUsageBar.app
    cp -R "$APP" /Applications/
    open /Applications/ClaudeUsageBar.app
    echo "✅ /Applications에 설치 후 실행"
fi
