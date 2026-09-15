#!/bin/bash
set -euo pipefail

# CLT 환경에서 plain `swift test`는 Swift Testing 매크로 플러그인 탐색이 간헐적으로
# 실패한다(실측 통과율 약 25%). 경로를 직접 박아 그 탐색 단계를 없앤다.
#
# 경로는 고정하지 않고 활성 툴체인에서 유도한다. Command Line Tools만 설치한 환경과
# Xcode를 설치한 환경의 레이아웃이 다르므로, 고정 CLT 절대경로를 쓰면 Xcode 사용자에게는
# 없는 dylib을 로드하라고 시켜 원인과 무관한 컴파일러 오류가 난다.
PLUGIN="$(xcode-select -p)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$PLUGIN" ]; then
    exec swift test -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN" "$@"
fi

echo "알림: libTestingMacros.dylib을 찾지 못해 플러그인 경로 고정 없이 실행합니다." >&2
echo "      ($PLUGIN)" >&2
exec swift test "$@"
