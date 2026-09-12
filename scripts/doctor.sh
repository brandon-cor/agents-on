#!/bin/bash
set -u
app="$HOME/Applications/Agents On.app"
service="gui/$(id -u)/io.github.brandon-cor.agents-on"
echo "macOS $(/usr/bin/sw_vers -productVersion), $(uname -m)"
if [[ ! -x "$app/Contents/MacOS/AgentsOn" ]]; then
  echo 'App: not installed in ~/Applications. Use the Terminal installer in the README.'
  exit 1
fi
echo "App version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
/usr/bin/codesign --verify --deep --strict "$app" 2>&1
/bin/launchctl print "$service" 2>&1 | /usr/bin/awk '/state =|pid =|last exit code|Could not find|Bad request/ {print}'
echo 'Menu bar app response:'
"$app/Contents/MacOS/AgentsOn" --check-ui
code=$?
if [[ -f "$HOME/Library/Application Support/Agents On/stderr.log" ]]; then
  echo 'Recent startup log:'
  tail -n 12 "$HOME/Library/Application Support/Agents On/stderr.log"
fi
echo 'A created/enabled item can still be hidden by a full menu bar, a notch, or a menu bar manager.'
echo 'Try agents show, then enable the compact light if space is limited.'
exit "$code"
