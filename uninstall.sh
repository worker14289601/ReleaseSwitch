#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
app_path="$HOME/Applications/ReleaseSwitch.app"
[[ -d /Applications/ReleaseSwitch.app ]] && app_path=/Applications/ReleaseSwitch.app
helper="$app_path/Contents/MacOS/ReleaseSwitch"
[[ -x "$helper" ]] || helper="$project_dir/ReleaseSwitch.app/Contents/MacOS/ReleaseSwitch"
if [[ -f "$app_path/Contents/Info.plist" ]]; then
    old_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")
    case "$old_version" in
        1.0|1.1) helper="$project_dir/ReleaseSwitch.app/Contents/MacOS/ReleaseSwitch" ;;
    esac
fi
if [[ -x "$helper" ]]; then
    "$helper" --disable-login
    "$helper" --quit-running
    "$helper" --restore
fi
launchctl bootout "gui/$(id -u)/local.andrey.ReleaseSwitch" 2>/dev/null || true
print 'Автозапуск выключен. Исходные настройки клавиш восстановлены.'
print "Приложение можно удалить из $app_path."
