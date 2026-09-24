#!/bin/bash
set -euo pipefail
version=0.2.0
base="https://github.com/brandon-cor/agents-on/releases/download/v$version"
check_only=0
archive_dir=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only) check_only=1; shift ;;
    --archive-dir) [[ $# -ge 2 ]] || exit 2; archive_dir="$2"; shift 2 ;;
    *) echo 'Usage: bash install.sh [--check-only] [--archive-dir DIRECTORY]' >&2; exit 2 ;;
  esac
done
[[ "$(uname -s)" == Darwin ]] || { echo 'Agents On requires macOS.' >&2; exit 1; }
major=$(/usr/bin/sw_vers -productVersion | cut -d. -f1)
(( major >= 14 )) || { echo 'Agents On requires macOS 14 or newer.' >&2; exit 1; }
[[ "$(id -u)" != 0 ]] || { echo 'Run this installer as yourself, without sudo.' >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if [[ -n "$archive_dir" ]]; then
  cp "$archive_dir/Agents-On-macOS.zip" "$archive_dir/SHA256SUMS" "$work/"
else
  /usr/bin/curl --fail --location --silent --show-error "$base/Agents-On-macOS.zip" -o "$work/Agents-On-macOS.zip"
  /usr/bin/curl --fail --location --silent --show-error "$base/SHA256SUMS" -o "$work/SHA256SUMS"
fi
(cd "$work" && /usr/bin/shasum -a 256 --check SHA256SUMS)
/usr/bin/ditto -x -k "$work/Agents-On-macOS.zip" "$work/unpacked"
package="$work/unpacked/Agents-On"
app="$package/Agents On.app"
/usr/bin/codesign --verify --deep --strict "$app"
"$app/Contents/MacOS/AgentsOn" --status
for file in agents shell.sh uninstall.sh start.sh doctor.sh; do
  [[ -f "$package/$file" ]] || { echo "Missing package file: $file" >&2; exit 1; }
done
if (( check_only )); then
  echo 'Package verified. No installation or sleep settings changed.'
  exit 0
fi
user_name=$(id -un)
[[ "$user_name" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*$ ]] || { echo 'Unsupported account name.' >&2; exit 1; }
user_id=$(id -u)
support="$HOME/Library/Application Support/Agents On"
label=io.github.brandon-cor.agents-on
plist="$HOME/Library/LaunchAgents/$label.plist"
new_plist="$work/agents-on.plist"
target="$HOME/Applications/Agents On.app"
# ask once; privilege is limited to writing the exact two-command rule.
echo 'One-time setup: enter your Mac password to allow just the two sleep toggles.'
/usr/bin/sudo /bin/sh -s -- "$user_name" "$user_id" <<'ROOT'
set -eu
account=$1
account_id=$2
mkdir -p /private/etc/sudoers.d
rule_tmp=$(/usr/bin/mktemp /private/etc/sudoers.d/agents-on-XXXXXX)
trap 'rm -f "$rule_tmp"' EXIT
/usr/bin/printf '%s ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0\n' "$account" > "$rule_tmp"
/usr/sbin/chown root:wheel "$rule_tmp"
/bin/chmod 0440 "$rule_tmp"
/usr/sbin/visudo -cf "$rule_tmp"
/bin/mv "$rule_tmp" "/private/etc/sudoers.d/agents-on-$account_id"
/usr/sbin/visudo -c
ROOT
mkdir -p "$HOME/Applications" "$support" "$HOME/Library/LaunchAgents" "$HOME/.local/bin"
/bin/launchctl bootout "gui/$user_id/$label" 2>/dev/null || true
# replace only our own app; preserve the previous copy until the new one is copied.
if [[ -d "$target" ]]; then
  rm -rf "$support/previous.app"
  mv "$target" "$support/previous.app"
fi
/usr/bin/ditto "$app" "$target"
install -m 755 "$package/agents" "$HOME/.local/bin/agents"
install -m 644 "$package/shell.sh" "$support/shell.sh"
install -m 755 "$package/uninstall.sh" "$support/uninstall.sh"
install -m 755 "$package/start.sh" "$support/start.sh"
install -m 755 "$package/doctor.sh" "$support/doctor.sh"
/usr/bin/plutil -create xml1 "$new_plist"
/usr/bin/plutil -insert Label -string "$label" "$new_plist"
/usr/bin/plutil -insert ProgramArguments -json '[]' "$new_plist"
/usr/bin/plutil -insert ProgramArguments.0 -string "$target/Contents/MacOS/AgentsOn" "$new_plist"
/usr/bin/plutil -insert ProcessType -string Interactive "$new_plist"
/usr/bin/plutil -insert RunAtLoad -bool true "$new_plist"
/usr/bin/plutil -insert KeepAlive -json '{"SuccessfulExit":false}' "$new_plist"
/usr/bin/plutil -insert ThrottleInterval -integer 10 "$new_plist"
/usr/bin/plutil -insert LimitLoadToSessionType -string Aqua "$new_plist"
/usr/bin/plutil -insert StandardErrorPath -string "$support/stderr.log" "$new_plist"
/usr/bin/plutil -insert StandardOutPath -string "$support/stdout.log" "$new_plist"
mv "$new_plist" "$plist"
line='[ -f "$HOME/Library/Application Support/Agents On/shell.sh" ] && source "$HOME/Library/Application Support/Agents On/shell.sh" # agents-on'
touch "$HOME/.zshrc"
if ! /usr/bin/grep -Fqx "$line" "$HOME/.zshrc"; then
  cp "$HOME/.zshrc" "$support/zshrc-before-install"
  printf '\n%s\n' "$line" >> "$HOME/.zshrc"
fi
if ! /bin/bash "$support/start.sh"; then
  echo 'Files installed, but menu bar startup could not be verified. This is not a completed setup.' >&2
  /bin/bash "$support/doctor.sh" >&2 || true
  exit 1
fi
# listing permissions verifies setup without changing the user's sleep state.
/usr/bin/sudo -n -l /usr/bin/pmset -a disablesleep 1 >/dev/null
/usr/bin/sudo -n -l /usr/bin/pmset -a disablesleep 0 >/dev/null
"$target/Contents/MacOS/AgentsOn" --show >/dev/null
echo 'Installed: the app responded and created its menu bar item. Open a new terminal for sleep on/off.'
echo 'If the light is hidden, run agents show and try the compact indicator.'
echo 'Your existing sleep setting was preserved.'
