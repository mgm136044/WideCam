#!/bin/bash
set -euo pipefail

# WideCam 배포 스크립트 — 번들 생성부터 수행한다.
# 사용법: ./deploy.sh [--skip-build] [--no-launch]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="/Applications/WideCam.app"
BUNDLE_ID="com.mingyeongmin.WideCam"
VERSION="1.0.0"

# 서명 신원은 스크립트에 박지 않는다(공개 저장소에 개인 신원 문자열이 남지 않게).
# 우선순위: 환경변수 WIDECAM_SIGN_IDENTITY → gitignore된 로컬 파일 .sign-identity(한 줄).
SIGN_IDENTITY_FILE="$SCRIPT_DIR/.sign-identity"
if [ -n "${WIDECAM_SIGN_IDENTITY:-}" ]; then
    IDENTITY="$WIDECAM_SIGN_IDENTITY"
elif [ -f "$SIGN_IDENTITY_FILE" ]; then
    # 한 줄 파일. 뒤쪽 개행만 없애고 나머지는 그대로 쓴다(신원에 공백·괄호가 들어간다).
    IDENTITY="$(head -n 1 "$SIGN_IDENTITY_FILE")"
else
    echo "✗ 서명 신원이 설정되지 않았습니다." >&2
    echo "  다음 중 하나로 지정하세요:" >&2
    echo "    1) 환경변수:  export WIDECAM_SIGN_IDENTITY=\"Apple Development: 이름 (팀ID)\"" >&2
    echo "    2) 로컬 파일: 신원 문자열 한 줄을 $SIGN_IDENTITY_FILE 에 저장" >&2
    echo "  신원 값은 security find-identity -v -p codesigning 으로 확인할 수 있습니다." >&2
    exit 1
fi

SKIP_BUILD=false
NO_LAUNCH=false
for arg in "$@"; do
    case $arg in
        --skip-build) SKIP_BUILD=true ;;
        --no-launch) NO_LAUNCH=true ;;
        # 오타를 조용히 버리면 안 된다. 이 스크립트는 앱을 죽이고(pkill) 설치본을
        # 지우고(rm -rf) 다시 띄운다 — `--skipbuild`로 잘못 적으면 재사용할 생각이었던
        # 사용자에게 전체 릴리스 빌드가 돌아간다.
        *) echo "알 수 없는 옵션: $arg" >&2; exit 2 ;;
    esac
done

# 검사는 $IDENTITY 그 자체로 한다. 팀 ID를 따로 박아 두면 IDENTITY를 바꾼 사람이
# 검사를 통과한 뒤 codesign 단계에서 실패한다.
#
# 파이프를 쓰지 않는다. `security ... | grep -q`는 grep이 첫 일치에서 즉시 끝나면서
# security가 SIGPIPE로 죽어 파이프라인 상태가 141이 되고, set -o pipefail이 그것을
# 실패로 읽어 인증서가 있는데도 "없음"으로 중단한다(키체인 신원 수에 따라 간헐적으로
# 재현된다). 출력을 변수에 담고 case의 부분 일치로 본다 — case는 대상 단어에 필드
# 분리·경로명 확장을 적용하지 않으므로 공백과 괄호가 든 신원도 안전하다.
IDENTITIES="$(security find-identity -v -p codesigning)"
case "$IDENTITIES" in
    *"$IDENTITY"*) ;;
    *)
        echo "✗ 서명 인증서를 찾을 수 없습니다: $IDENTITY"
        echo "  security find-identity -v -p codesigning 으로 이름을 확인해 IDENTITY를 고치세요."
        exit 1
        ;;
esac

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
# 아이콘 확인도 설치본을 지우기 전에 한다. cp가 중간에 실패하면
# /Applications/WideCam.app이 반쯤 만들어진 채로 남는다.
ICON="$SCRIPT_DIR/Resources/AppIcon.icns"
if [ ! -f "$ICON" ]; then
    echo "✗ $ICON 없음 — 저장소의 Resources/AppIcon.icns가 사라졌습니다."
    exit 1
fi
pkill -x WideCam 2>/dev/null || true
sleep 1
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN" "$APP_PATH/Contents/MacOS/WideCam"
cp "$ICON" "$APP_PATH/Contents/Resources/AppIcon.icns"
cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>WideCam</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
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
