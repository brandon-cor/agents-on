#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
for file in install.sh scripts/*.sh scripts/agents; do bash -n "$file"; done
zsh -n scripts/shell.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/.local/bin"
printf '#!/bin/bash\nprintf "stub:%%s\\n" "$*"\n' > "$work/.local/bin/agents"
chmod +x "$work/.local/bin/agents"
actual=$(HOME="$work" zsh -f -c 'source "$1"; sleep on; sleep off; sleep status; sleep 0' _ "$PWD/scripts/shell.sh")
[[ "$actual" == $'stub:on\nstub:off\nstub:status' ]]
echo 'Shell forwarding and numeric sleep verified.'
bash scripts/build.sh
bash install.sh --check-only --archive-dir "$PWD/dist"
