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
# cover fresh macOS accounts, explicit on/off, and unexpected command output.
printf 'import Cocoa\n' > "$work/state-check.swift"
sed -n '/^func parseSleepDisabled/,/^}/p' Sources/main.swift >> "$work/state-check.swift"
cat >> "$work/state-check.swift" <<'SWIFT'
precondition(parseSleepDisabled("System-wide power settings:\nCurrently in use:\n sleep 1") == false)
precondition(parseSleepDisabled("SleepDisabled 1\nCurrently in use:") == true)
precondition(parseSleepDisabled("SleepDisabled 0\nCurrently in use:") == false)
precondition(parseSleepDisabled("unrecognized output") == nil)
print("Fresh-account and explicit sleep states verified.")
SWIFT
/usr/bin/swiftc -target "$(uname -m)-apple-macos14.0" "$work/state-check.swift" -o "$work/state-check" -framework Cocoa
"$work/state-check"
printf 'import Cocoa\n' > "$work/duration-check.swift"
sed -n '/^func durationSeconds/,/^}/p' Sources/main.swift >> "$work/duration-check.swift"
cat >> "$work/duration-check.swift" <<'SWIFT'
precondition(durationSeconds("30") == 1800)
precondition(durationSeconds("60") == 3600)
precondition(durationSeconds("180") == 10800)
precondition(durationSeconds(" 90 ") == 5400)
precondition(durationSeconds("0.1") == 6)
for invalid in ["", "0", "-1", "nan", "inf", "abc", "525601"] {
    precondition(durationSeconds(invalid) == nil)
}
print("Preset/custom durations and invalid input verified.")
SWIFT
/usr/bin/swiftc -target "$(uname -m)-apple-macos14.0" "$work/duration-check.swift" -o "$work/duration-check" -framework Cocoa
"$work/duration-check"
bash scripts/build.sh
bash install.sh --check-only --archive-dir "$PWD/dist"
