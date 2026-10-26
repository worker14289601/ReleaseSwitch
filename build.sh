#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
[[ "$(uname -m)" == arm64 ]] || { print -u2 'Требуется Apple Silicon.'; exit 1; }
mkdir -p build/ReleaseSwitch.app/Contents/MacOS build/ReleaseSwitch.app/Contents/Resources build/module-cache
xcrun swiftc -O -target arm64-apple-macos26.0 -module-cache-path build/module-cache \
    Sources/ReleaseGesture.swift Sources/LanguageSwitcher.swift Sources/RuntimeSupervisor.swift \
    Sources/KeyboardSettings.swift Tests/main.swift -framework AppKit -o build/regression-tests
build/regression-tests
xcrun swift -module-cache-path build/module-cache Scripts/GenerateAssets.swift
/usr/bin/iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
xcrun swiftc -O -target arm64-apple-macos26.0 -swift-version 5 -module-cache-path build/module-cache \
    -import-objc-header Sources/HIDBridge.h Sources/*.swift \
    -framework AppKit -framework SwiftUI -framework ServiceManagement -framework Carbon -framework IOKit -framework ApplicationServices \
    -o build/ReleaseSwitch.app/Contents/MacOS/ReleaseSwitch
cp Info.plist build/ReleaseSwitch.app/Contents/Info.plist
cp Resources/AppIcon.icns Resources/AppIcon.png build/ReleaseSwitch.app/Contents/Resources/
plutil -lint build/ReleaseSwitch.app/Contents/Info.plist
codesign --force --sign - --identifier local.andrey.ReleaseSwitch build/ReleaseSwitch.app
codesign --verify --strict build/ReleaseSwitch.app
ditto build/ReleaseSwitch.app ReleaseSwitch.app
