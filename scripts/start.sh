#!/bin/bash
set -euo pipefail
label=io.github.brandon-cor.agents-on
service="gui/$(id -u)/$label"
plist="$HOME/Library/LaunchAgents/$label.plist"
app="$HOME/Applications/Agents On.app"
binary="$app/Contents/MacOS/AgentsOn"
[[ -x "$binary" && -f "$plist" ]] || {
  echo 'The app or login job is missing. Re-run the Agents On installer.' >&2
  exit 1
}
# a disabled login job stays disabled across reinstalls until explicitly enabled.
/bin/launchctl enable "$service"
if ! /bin/launchctl print "$service" >/dev/null 2>&1; then
  /bin/launchctl bootstrap "gui/$(id -u)" "$plist"
fi
/bin/launchctl kickstart "$service"
if "$binary" --check-ui; then exit 0; fi
# launch services provides a second path to a GUI app if direct startup failed.
/usr/bin/open -g "$app"
if "$binary" --check-ui; then exit 0; fi
echo 'Startup did not create a responsive menu bar item. Run agents doctor and share the output.' >&2
exit 1
