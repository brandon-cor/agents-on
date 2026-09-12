#!/bin/bash
set -euo pipefail
label=io.github.brandon-cor.agents-on
user_id=$(id -u)
[[ "$user_id" != 0 ]] || { echo 'Run as yourself, without sudo.' >&2; exit 1; }
support="$HOME/Library/Application Support/Agents On"
echo 'Removing Agents On and restoring normal system sleep.'
# get authorization before removing files so cancellation leaves the app intact.
/usr/bin/sudo /bin/sh -s -- "$user_id" <<'ROOT'
set -eu
/usr/bin/pmset -a disablesleep 0
/bin/rm -f "/private/etc/sudoers.d/agents-on-$1"
/usr/sbin/visudo -c
ROOT
"$HOME/Applications/Agents On.app/Contents/MacOS/AgentsOn" --refresh 2>/dev/null || true
/bin/launchctl bootout "gui/$user_id/$label" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$label.plist" "$HOME/.local/bin/agents"
# remove only our marker, preserving later shell customizations.
if [[ -f "$HOME/.zshrc" ]]; then
  /usr/bin/sed '/ # agents-on$/d' "$HOME/.zshrc" > "$support/zshrc-clean"
  /bin/cat "$support/zshrc-clean" > "$HOME/.zshrc"
fi
rm -rf "$HOME/Applications/Agents On.app" "$support"
echo 'Agents On removed. Normal sleep restored. Open a new terminal to remove the shortcuts.'
