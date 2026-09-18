#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift_bin="$(xcrun --find swift)"
testing_plugin="${swift_bin:h:h}/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "$testing_plugin" ]]; then
    swift test --disable-xctest -Xswiftc -load-plugin-library -Xswiftc "$testing_plugin" "$@"
else
    swift test --disable-xctest "$@"
fi
