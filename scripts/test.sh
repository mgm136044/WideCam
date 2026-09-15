#!/bin/bash
# CLT 환경에서 swift test의 매크로 플러그인 탐색이 간헐적으로 실패하는 문제 우회 (Task 1 실측, 9/9 안정)
exec swift test -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib "$@"
