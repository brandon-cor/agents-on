#!/bin/bash
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted && "$(uname -s)" == Darwin ]] || {
  echo 'This full-install fixture requires a disposable GitHub-hosted Mac.' >&2
  exit 1
}
cd "$(dirname "$0")/.."
app="$HOME/Applications/Agents On.app"
support="$HOME/Library/Application Support/Agents On"
[[ ! -e "$app" && ! -e "$support" ]] || { echo 'A fresh test profile is required.' >&2; exit 1; }
work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/agents-on npm.XXXXXX")
cleanup() {
  result=$?
  trap - EXIT
  if [[ -f "$support/uninstall.sh" ]]; then
    /bin/bash "$support/uninstall.sh" || result=1
  fi
  rm -rf "$work"
  exit "$result"
}
trap cleanup EXIT
export npm_config_cache="$work/npm cache"
export npm_config_audit=false
export npm_config_fund=false
npm pack ./packaging/npm --ignore-scripts --json --pack-destination "$work" > "$work/pack.json"
package=$(node -e 'const fs=require("fs"),path=require("path");console.log(path.join(process.argv[1],JSON.parse(fs.readFileSync(process.argv[2],"utf8"))[0].filename))' "$work" "$work/pack.json")
npm exec --yes --package "$package" -- agents-on --check
npm exec --yes --package "$package" -- agents-on install
"$app/Contents/MacOS/AgentsOn" --check-ui
npm exec --yes --package "$package" -- agents-on install
"$app/Contents/MacOS/AgentsOn" --check-ui
/bin/bash "$support/uninstall.sh"
[[ ! -e "$app" && ! -e "$HOME/Library/LaunchAgents/io.github.brandon-cor.agents-on.plist" ]] || {
  echo 'Uninstall did not remove the app and login item.' >&2; exit 1
}
mkdir -p dist/npm-package
cp "$package" dist/npm-package/
(
  cd dist/npm-package
  /usr/bin/shasum -a 256 agents-on-0.7.1.tgz > SHA256SUMS
)
echo 'Packed npm installer: Mac verification, setup, menu bar startup, update, and uninstall passed.'
