#!/bin/zsh

set -euo pipefail

# Prefer the active SDK. Xcode 27's SwiftUI requires the SwiftUIMacros host
# plugin; the standalone Command Line Tools 27.0 package currently installed
# on this Mac does not include it. In that incomplete configuration, use the
# newest installed pre-27 SDK so builds remain reproducible on macOS 27.
if [[ -n "${NOOK_MACOS_SDK:-}" ]]; then
    [[ -d "$NOOK_MACOS_SDK" ]] || {
        echo "NOOK_MACOS_SDK does not exist: $NOOK_MACOS_SDK" >&2
        exit 1
    }
    print -r -- "${NOOK_MACOS_SDK:A}"
    exit 0
fi

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SDK_PATH="${SDK_PATH:A}"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
SDK_MAJOR="${SDK_VERSION%%.*}"
DEVELOPER_DIR="$(xcode-select -p)"

has_swiftui_macros=false
for plugin in \
    "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" \
    "$DEVELOPER_DIR/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
do
    if [[ -f "$plugin" ]]; then
        has_swiftui_macros=true
        break
    fi
done

if (( SDK_MAJOR >= 27 )) && [[ "$has_swiftui_macros" != true ]]; then
    fallback="$(find "$DEVELOPER_DIR/SDKs" -maxdepth 1 -type d -name 'MacOSX26*.sdk' -print 2>/dev/null | sort -V | tail -n 1)"
    if [[ -z "$fallback" ]]; then
        echo "The macOS $SDK_VERSION SDK requires SwiftUIMacros, but the active developer tools do not provide it." >&2
        echo "Install/select Xcode 27, or set NOOK_MACOS_SDK to a compatible installed SDK." >&2
        exit 1
    fi
    echo "Nook: SwiftUIMacros is unavailable; using compatibility SDK ${fallback:t} on macOS 27." >&2
    print -r -- "${fallback:A}"
    exit 0
fi

print -r -- "$SDK_PATH"
