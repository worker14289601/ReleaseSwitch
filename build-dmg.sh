#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
[[ "$(uname -m)" == arm64 ]] || { print -u2 'Требуется Apple Silicon.'; exit 1; }
[[ -x ReleaseSwitch.app/Contents/MacOS/ReleaseSwitch ]] || /bin/zsh build.sh
mkdir -p build/dmg-tools
if ! PYTHONPATH="$PWD/build/dmg-tools" /usr/bin/python3 -c 'import dmgbuild' >/dev/null 2>&1; then
    /usr/bin/python3 -m pip install --only-binary=:all: --target build/dmg-tools -r Scripts/dmg-requirements.txt
fi
PYTHONPATH="$PWD/build/dmg-tools" /usr/bin/python3 -m dmgbuild -s Scripts/dmg-settings.py 'ReleaseSwitch' "$PWD/ReleaseSwitch.dmg"
/usr/bin/hdiutil verify ReleaseSwitch.dmg
xcrun swift -module-cache-path build/module-cache Scripts/SetDMGIcon.swift "$PWD/ReleaseSwitch.dmg" "$PWD/Resources/AppIcon.icns"
shasum -a 256 ReleaseSwitch.dmg > ReleaseSwitch.dmg.sha256
