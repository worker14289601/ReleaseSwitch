#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
[[ "$(uname -m)" == arm64 ]] || { print -u2 'Требуется Apple Silicon.'; exit 1; }
macos_major="$(sw_vers -productVersion | cut -d. -f1)"
(( macos_major >= 26 )) || { print -u2 'Требуется macOS 26 или новее.'; exit 1; }
source_app="$project_dir/ReleaseSwitch.app"
app_path="$HOME/Applications/ReleaseSwitch.app"
service="gui/$(id -u)/local.andrey.ReleaseSwitch"
legacy_path="$HOME/Library/LaunchAgents/local.andrey.ReleaseSwitch.plist"
[[ -x "$source_app/Contents/MacOS/ReleaseSwitch" ]] || { print -u2 'Сначала выполните zsh build.sh'; exit 1; }
codesign --verify --strict "$source_app"
if [[ -e "$app_path" ]]; then
    existing_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")
    [[ "$existing_id" == local.andrey.ReleaseSwitch ]] || { print -u2 'По этому пути находится другое приложение.'; exit 1; }
fi
launchctl bootout "$service" 2>/dev/null || true
"$source_app/Contents/MacOS/ReleaseSwitch" --quit-running
if [[ -f "$legacy_path" ]]; then
    mkdir -p "$HOME/Library/Application Support/ReleaseSwitch"
    legacy_backup="$HOME/Library/Application Support/ReleaseSwitch/legacy-autostart.plist"
    [[ -e "$legacy_backup" ]] || cp -p "$legacy_path" "$legacy_backup"
    launchctl disable "$service" 2>/dev/null || true
    rm "$legacy_path"
fi
mkdir -p "$HOME/Applications"
ditto "$source_app" "$app_path"
codesign --verify --strict "$app_path"
open "$app_path"
print "Установлено: $app_path"
print 'Разрешения и автозапуск настраиваются в окне ReleaseSwitch.'
if (( macos_major == 26 )); then print 'На macOS 26 программа не тестировалась; возможны сбои.'; fi
