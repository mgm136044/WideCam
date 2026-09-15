#!/bin/bash
set -euo pipefail

# WideCam 배포 스크립트 — 번들 생성부터 수행한다.
# 사용법: ./deploy.sh [--skip-build] [--no-launch]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="/Applications/WideCam.app"
IDENTITY="Apple Development: YOUR NAME (TEAMID)"
BUNDLE_ID="com.mingyeongmin.WideCam"
VERSION="1.0.0"

SKIP_BUILD=false
NO_LAUNCH=false
for arg in "$@"; do
    case $arg in
        --skip-build) SKIP_BUILD=true ;;
        --no-launch) NO_LAUNCH=true ;;
    esac
done

if ! security find-identity -v -p codesigning | grep -q "TEAMID"; then
    echo "✗ 서명 인증서(TEAMID)를 찾을 수 없습니다. 중단합니다."
    exit 1
fi

echo "[1/4] 빌드"
if [ "$SKIP_BUILD" = false ]; then
    cd "$SCRIPT_DIR"
    swift build -c release 2>&1 | tail -2
else
    echo "  건너뜀 (--skip-build)"
fi

echo "[2/4] 번들 생성"
BIN="$SCRIPT_DIR/.build/release/WideCam"
if [ ! -x "$BIN" ]; then
    echo "✗ $BIN 없음 — 빌드를 먼저 하거나 --skip-build를 빼세요."
    exit 1
fi
pkill -x WideCam 2>/dev/null || true
sleep 1
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN" "$APP_PATH/Contents/MacOS/WideCam"
cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>WideCam</string>
	<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
	<key>CFBundleName</key><string>WideCam</string>
	<key>CFBundleDisplayName</key><string>WideCam</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${VERSION}</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>LSUIElement</key><true/>
	<key>NSCameraUsageDescription</key><string>아이폰 카메라의 전체 화각 미리보기와 촬영에 사용합니다.</string>
	<key>NSMicrophoneUsageDescription</key><string>영상 녹화에 소리를 담기 위해 사용합니다.</string>
	<key>NSCameraUseContinuityCameraDeviceType</key><true/>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
echo "  ✓ 번들 생성 완료"

echo "[3/4] 코드 서명"
codesign --force --sign "$IDENTITY" "$APP_PATH"
codesign -v "$APP_PATH" && echo "  ✓ 서명 유효"

echo "[4/4] 완료"
if [ "$NO_LAUNCH" = false ]; then
    open "$APP_PATH"
    echo "  ✓ WideCam 실행됨"
fi
