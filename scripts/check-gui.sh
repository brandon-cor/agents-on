#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# run on a clean GUI account so the test cannot interfere with an installed copy.
if [[ -d "$HOME/Applications/Agents On.app" ]]; then
  echo 'GUI smoke test skipped: an installed app is present.'
  exit 0
fi
/bin/launchctl print "gui/$(id -u)" >/dev/null
work=$(mktemp -d)
label="io.github.brandon-cor.agents-on.smoke-$$"
service="gui/$(id -u)/$label"
cleanup() {
  /bin/launchctl bootout "$service" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
/usr/bin/ditto -x -k dist/Agents-On-macOS.zip "$work"
binary="$work/Agents-On/Agents On.app/Contents/MacOS/AgentsOn"
plist="$work/gui.plist"
/usr/bin/plutil -create xml1 "$plist"
/usr/bin/plutil -insert Label -string "$label" "$plist"
/usr/bin/plutil -insert ProgramArguments -json '[]' "$plist"
/usr/bin/plutil -insert ProgramArguments.0 -string "$binary" "$plist"
/usr/bin/plutil -insert ProcessType -string Interactive "$plist"
/usr/bin/plutil -insert RunAtLoad -bool true "$plist"
/usr/bin/plutil -insert LimitLoadToSessionType -string Aqua "$plist"
/bin/launchctl bootstrap "gui/$(id -u)" "$plist"
"$binary" --check-ui
/bin/launchctl bootout "$service"
# a stale JSON response must not make a dead app look healthy.
if "$binary" --check-ui; then
  echo 'ERROR: UI check accepted a stopped app.' >&2
  exit 1
fi
echo 'GUI startup and stopped-app rejection verified.'
